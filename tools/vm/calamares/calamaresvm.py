#!/usr/bin/env python3
"""Installs Debian or CachyOS next to a stand-in Windows with their real Calamares, on a disk laid out as hop leaves one.

The disk gets a 200 MB EFI partition with stand-ins for Windows' files, a reserved partition, an NTFS "C:", FAT32
HOPINSTALL filled as Copy-Installer fills it, free space for Linux, and a recovery partition at the end. The numbers are
the ones Windows gives them: Setup's four first, then hop's HOPINSTALL as 5. prepare.ps1 runs the engine's own
Update-BootConfig and Copy-EspLoader. The firmware then starts hop's loader through Boot0042 and BootNext, as hop
writes them. The test adds a root shell on the serial port to the live system's menu, which it only uses to read
logs and to know when the desktop is up. Calamares itself is driven through its screens: QEMU takes a screenshot,
tesseract reads it, and the mouse and keys go in through QEMU, following the steps Get-Steps renders.

    calamaresvm.py prepare --distro debian --iso debian.iso   lay out and fill the disk, write the startup entries
    calamaresvm.py install --distro debian                    start it, install with Calamares, restart and wait
    calamaresvm.py check --stage installed                    what changed on the disk, what the installed system logged
    calamaresvm.py renumber                                   remove HOPINSTALL and close up the GPT, as Windows does
    calamaresvm.py boot --stage renumbered                    start from the disk again and see what GRUB does

Needs root, qemu-system-x86, ovmf, gdisk, dosfstools, ntfs-3g, pwsh, tesseract, python3-pil and virt-firmware.
"""
import argparse
import difflib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault('OMARCHYVM_WORK', '/mnt/cvm')
sys.path.insert(0, os.path.join(HERE, '..', 'omarchy'))
import omarchyvm as ovm  # noqa: E402
from omarchyvm import log, note, run, sha256_of, attach, mount, tree_hashes, gpt_entry, load_option_path, print_vars  # noqa: E402

WORK, OUT, DISK, VARS, STATE = ovm.WORK, ovm.OUT, ovm.DISK, ovm.VARS, ovm.STATE
DISK_GB = 80
LINUX_GB = 40
ESP_MB = 200
MSR_MB = 16
RECOVERY_MB = 750
SECTOR = 512
USER = 'hop'
FULL_NAME = 'hop'
PASSWORD = 'Hopvm-Test-2026'
# Added after hop's own edits, for this test only: a root shell on the serial port, to read logs with.
TEST_ARGS = 'systemd.debug_shell=ttyS0'
NAMES = {'debian': 'Debian', 'cachyos': 'CachyOS'}
# Windows' numbers: Setup makes the first four, and hop's installer partition takes the next free one.
NUMBERS = {'MSR': 2, 'C:': 3, 'Recovery': 4, 'HOPINSTALL': 5}


def pwsh(*argv):
    return run('pwsh', '-NoProfile', '-File', os.path.join(HERE, 'prepare.ps1'), *argv, capture=True)


def from_json(text):
    """pwsh can print a warning before the JSON."""
    return json.loads(text[text.index('{'):])


# --- Laying out the disk -------------------------------------------------------------

def mib(n):
    return n * (1 << 20) // SECTOR


def partition_hashes(loop, names):
    return {name: sha256_of(f'{loop}p{NUMBERS[name]}') if os.path.exists(f'{loop}p{NUMBERS[name]}') else None for name in names}


def esp_hashes(loop):
    folder = mount(f'{loop}p1', os.path.join(WORK, 'esp-read'), '-o', 'ro')
    try:
        return tree_hashes(folder)
    finally:
        run('umount', folder)


def write_vars(name, first, size, guid):
    from virt.firmware.varstore import autodetect
    from virt.firmware.efi import devpath
    shutil.copyfile(ovm.OVMF_VARS, VARS)
    store = autodetect.open_varstore(VARS)
    variables = store.get_varlist()
    # A stand-in for Windows first, which the firmware can't start, then hop's entry, as Register-Installer adds it.
    variables.set_boot_entry(0x0000, 'Windows Boot Manager', devpath.DevicePath(load_option_path(1, first, size, guid, r'\EFI\Microsoft\Boot\bootmgfw.efi')))
    variables.append_boot_order(0x0000)
    variables.set_boot_entry(0x0042, f'{name} installer (hop)', devpath.DevicePath(load_option_path(1, first, size, guid, r'\EFI\hop\BOOTX64.EFI')))
    variables.append_boot_order(0x0042)
    variables.set_boot_next(0x0042)
    store.write_varstore(VARS, variables)
    note(f'Startup entries: Boot0000 "Windows Boot Manager" (a stand-in), Boot0042 "{name} installer (hop)" at \\EFI\\hop\\BOOTX64.EFI, BootNext 0042')


def prepare(args):
    os.makedirs(OUT, exist_ok=True)
    iso = mount(args.iso, os.path.join(WORK, 'iso'), '-o', 'loop,ro')
    sizes = from_json(pwsh('sizes', args.distro, iso))
    log(json.dumps(sizes, indent=1))
    note(f'ISO {os.path.basename(args.iso)}: HOPINSTALL {sizes["InstallerGB"]} GB for {sizes["Bytes"]} bytes. '
         f'Kernel {sizes["Kernel"]}, there: {sizes["KernelFound"]}. Live image there: {sizes["LiveFound"]}. Menu known: {sizes["BootKnown"]}')
    note(f'hop refuses it next to Windows today: {sizes["Refused"]}')
    if sizes['TooBig'] or not sizes['BootKnown'] or not sizes['LiveFound'] or (sizes['Kernel'] and not sizes['KernelFound']):
        note('Read-Iso would refuse this ISO.')
        sys.exit(1)
    steps = from_json(pwsh('steps', args.distro, '-More', f'{LINUX_GB},{sizes["InstallerGB"]},{ESP_MB}'))
    note('--- the steps hop shows, from Get-Steps')
    for i, step in enumerate(steps['Steps'], 1):
        note(f'  {i}. {step}')
    for line in steps['Notes']:
        note(f'  Note: {line}')

    total = DISK_GB << 30 >> 9
    last = total - 34
    rec_start = (last - mib(RECOVERY_MB)) // 2048 * 2048
    inst = sizes['InstallerGB'] << 30 >> 9
    free_start = rec_start - (LINUX_GB << 30 >> 9)
    inst_start = free_start - inst
    esp_start, msr_start = 2048, 2048 + mib(ESP_MB)
    c_start = msr_start + mib(MSR_MB)
    if os.path.exists(DISK):
        os.unlink(DISK)
    with open(DISK, 'wb') as f:
        f.truncate(DISK_GB << 30)
    run('sgdisk', '-o',
        '-n', f'1:{esp_start}:{msr_start - 1}', '-t', '1:ef00', '-c', '1:EFI system partition',
        '-n', f'2:{msr_start}:{c_start - 1}', '-t', '2:0c01', '-c', '2:Microsoft reserved partition',
        '-n', f'3:{c_start}:{inst_start - 1}', '-t', '3:0700', '-c', '3:Basic data partition',
        '-n', f'4:{rec_start}:{last}', '-t', '4:2700', '-c', '4:Basic data partition',
        '-n', f'5:{inst_start}:{free_start - 1}', '-t', '5:0700', '-c', '5:Basic data partition', DISK)
    layout = run('sgdisk', '-p', DISK, capture=True)
    with open(os.path.join(OUT, 'layout-before.txt'), 'w') as f:
        f.write(layout)
    note('--- the disk before\n' + layout)

    loop = attach()
    try:
        run('mkfs.fat', '-F', '32', f'{loop}p1')
        run('mkntfs', '-Q', '-L', 'Windows', f'{loop}p3')
        run('mkntfs', '-Q', f'{loop}p4')
        run('mkfs.fat', '-F', '32', '-n', 'HOPINSTALL', f'{loop}p5')
        rng = random.Random(42)
        with open(f'{loop}p2', 'r+b') as f:
            f.write(bytes(rng.getrandbits(8) for _ in range(1 << 16)))

        # Windows' files are stand-ins, there to show whether anything changes them.
        esp = mount(f'{loop}p1', os.path.join(WORK, 'esp'))
        os.makedirs(os.path.join(esp, 'EFI/Microsoft/Boot'))
        os.makedirs(os.path.join(esp, 'EFI/Boot'))
        loader = bytes(rng.getrandbits(8) for _ in range(1 << 20))
        for path in ('EFI/Microsoft/Boot/bootmgfw.efi', 'EFI/Boot/bootx64.efi'):
            with open(os.path.join(esp, path), 'wb') as f:
                f.write(loader)
        with open(os.path.join(esp, 'EFI/Microsoft/Boot/BCD'), 'wb') as f:
            f.write(bytes(rng.getrandbits(8) for _ in range(32768)))
        for number, folder, name in ((3, 'Windows/System32', 'stand-in.bin'), (4, 'Recovery/WindowsRE', 'Winre.wim')):
            target = mount(f'{loop}p{number}', os.path.join(WORK, f'ntfs{number}'), '-t', 'ntfs3')
            os.makedirs(os.path.join(target, folder))
            with open(os.path.join(target, folder, name), 'wb') as f:
                f.write(os.urandom((256 if number == 3 else 64) << 20))
            run('umount', target)

        # What Copy-Installer copies: every file Windows can see.
        installer = mount(f'{loop}p5', os.path.join(WORK, 'installer'))
        copied = 0
        for folder, _, files in os.walk(iso):
            for name in files:
                source = os.path.join(folder, name)
                if os.path.islink(source):
                    continue
                target = os.path.join(installer, os.path.relpath(source, iso))
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copyfile(source, target)
                if sha256_of(source) != sha256_of(target):
                    raise RuntimeError(f'{source} copied with damage')
                copied += 1
        log(f'Copied and checked {copied} files.')

        # The engine's own edits, as Install-Linux and Register-Installer make them, and its loader on the EFI partition.
        run('pwsh', '-NoProfile', '-File', os.path.join(HERE, 'prepare.ps1'), 'boot', args.distro, installer, esp)
        menu = os.path.join(installer, 'boot/grub/grub.cfg')
        shutil.copyfile(menu, os.path.join(OUT, 'grub-hop.cfg'))
        for folder, _, files in os.walk(os.path.join(installer, 'boot/grub')):
            for name in files:
                if not name.endswith('.cfg'):
                    continue
                path = os.path.join(folder, name)
                with open(path, encoding='latin-1') as f:
                    text = f.read()
                lines = [line.strip() for line in text.splitlines() if re.match(r'\s*linux\s', line)]
                if not lines:
                    continue
                note(f'hop\'s menu, {os.path.relpath(path, installer)}: {lines[0]}')
                text = re.sub(r'(?m)^(\s*linux\s.*)$', lambda m: m.group(1) + ' ' + TEST_ARGS, text)
                with open(path, 'w', encoding='latin-1') as f:
                    f.write(text)
        with open(os.path.join(esp, 'EFI/hop/grub.cfg')) as f:
            note('hop\'s grub.cfg on the EFI partition: ' + ' | '.join(f.read().splitlines()))
        note('\\EFI\\hop: ' + ', '.join(sorted(os.listdir(os.path.join(esp, 'EFI/hop')))))
        run('df', '-h', installer, esp)
        for folder in (esp, installer):
            run('umount', folder)
        state = {'distro': args.distro, 'esp': esp_hashes(loop), 'partitions': partition_hashes(loop, NUMBERS),
                 'sizes': sizes, 'steps': steps}
    finally:
        run('losetup', '-d', loop, check=False)
        run('umount', iso, check=False)
    first, size, guid = gpt_entry(1)
    write_vars(NAMES[args.distro], first, size, guid)
    print_vars('before')
    with open(STATE, 'w') as f:
        json.dump(state, f, indent=1)


# --- Reading the screen --------------------------------------------------------------

def canon(text):
    text = re.sub(r'[^a-z0-9/]', '', text.lower())
    return text.translate(str.maketrans({'o': '0', 'l': '1', 'i': '1'}))


class Word:
    def __init__(self, text, left, top, width, height):
        self.text, self.left, self.top, self.width, self.height = text, left, top, width, height
        self.key = canon(text)

    @property
    def cx(self):
        return self.left + self.width / 2

    @property
    def cy(self):
        return self.top + self.height / 2

    @property
    def right(self):
        return self.left + self.width

    @property
    def bottom(self):
        return self.top + self.height


class Match:
    def __init__(self, words, line):
        self.words, self.line = words, line
        self.left = min(w.left for w in words)
        self.top = min(w.top for w in words)
        self.right = max(w.right for w in words)
        self.bottom = max(w.bottom for w in words)
        self.x = (self.left + self.right) / 2
        self.y = (self.top + self.bottom) / 2
        self.line_text = ' '.join(w.text for w in line)


class Screen:
    def __init__(self, path, words, size):
        self.path, self.size = path, size
        self.lines = []
        for word in sorted(words, key=lambda w: w.cy):
            for line in self.lines:
                if abs(line[0].cy - word.cy) < max(6, min(line[0].height, word.height) * 0.6):
                    line.append(word)
                    break
            else:
                self.lines.append([word])
        for line in self.lines:
            line.sort(key=lambda w: w.left)

    def text(self):
        return '\n'.join(' '.join(w.text for w in line) for line in self.lines)

    def find_all(self, phrase, region=None, exact=False, line_has=None, colon=False):
        target = canon(phrase)
        width, height = self.size
        found = []
        for line in self.lines:
            for start in range(len(line)):
                acc = ''
                for end in range(start, min(len(line), start + 8)):
                    # Words of one phrase are close together.
                    if end > start and line[end].left - line[end - 1].right > 3 * line[end].height:
                        break
                    acc += line[end].key
                    if exact:
                        ok = acc == target
                    else:
                        ok = target in acc or (len(acc) >= len(target) - 1 and len(target) > 4 and difflib.SequenceMatcher(None, acc, target).ratio() >= 0.85)
                    if ok:
                        match = Match(line[start:end + 1], line)
                        inside = not region or (region[0] * width <= match.x <= region[2] * width and region[1] * height <= match.y <= region[3] * height)
                        labelled = not colon or line[end].text.endswith(':')
                        if inside and labelled and (not line_has or any(canon(line_has) in w.key for w in line)):
                            found.append(match)
                        break
                    if len(acc) > len(target) + 3:
                        break
        return found

    def find(self, phrase, pick='top', **kw):
        found = self.find_all(phrase, **kw)
        if not found:
            return None
        key = {'top': lambda m: m.y, 'bottom': lambda m: -m.y, 'right': lambda m: (-m.y, -m.x), 'left': lambda m: m.x}[pick]
        return sorted(found, key=key)[0]

    def has(self, *phrases, **kw):
        return any(self.find(p, **kw) for p in phrases)

    def lines_with(self, *phrases):
        keys = [canon(p) for p in phrases]
        return [' '.join(w.text for w in line) for line in self.lines if any(k in ''.join(w.key for w in line) for k in keys)]


def read_words(path):
    from PIL import Image, ImageOps
    image = Image.open(path).convert('L')
    width, height = image.size
    words = []
    # Twice the size reads small text better, and the inverted copy reads light text on dark.
    for variant in (image, ImageOps.invert(image)):
        big = variant.resize((width * 2, height * 2), Image.LANCZOS)
        tmp = os.path.join(WORK, 'ocr.png')
        big.save(tmp)
        out = subprocess.run(['tesseract', tmp, '-', '--psm', '11', 'tsv'], capture_output=True, text=True).stdout
        for row in out.splitlines()[1:]:
            cols = row.split('\t')
            if len(cols) < 12 or not cols[11].strip() or float(cols[10]) < 20:
                continue
            left, top, w, h = (int(c) / 2 for c in cols[6:10])
            word = Word(cols[11].strip(), left, top, w, h)
            if not word.key:
                continue
            if any(o.key == word.key and abs(o.cx - word.cx) < 8 and abs(o.cy - word.cy) < 8 for o in words):
                continue
            words.append(word)
    return words, (width, height)


class Vm(ovm.Vm):
    def __init__(self, memory_gb):
        super().__init__(memory_gb, extra=['-device', 'usb-tablet,bus=xhci.0'])
        self.size = (1280, 800)
        self.screen = None

    def look(self, name, quiet=False):
        path = self.shot(name)
        try:
            words, self.size = read_words(path)
        except Exception as e:
            log(f'could not read {path}: {e}')
            words = []
        self.screen = Screen(path, words, self.size)
        with open(path[:-4] + '.txt', 'w') as f:
            f.write(self.screen.text())
        if not quiet:
            log(f'--- {os.path.basename(path)}\n{self.screen.text()}')
        return self.screen

    def move(self, x, y):
        width, height = self.size
        self.qmp('input-send-event', events=[
            {'type': 'abs', 'data': {'axis': 'x', 'value': int(x * 32767 / (width - 1))}},
            {'type': 'abs', 'data': {'axis': 'y', 'value': int(y * 32767 / (height - 1))}}])
        time.sleep(0.2)

    def click(self, x, y, what=''):
        self.move(x, y)
        for down in (True, False):
            self.qmp('input-send-event', events=[{'type': 'btn', 'data': {'down': down, 'button': 'left'}}])
            time.sleep(0.1)
        log(f'clicked ({x:.0f}, {y:.0f}) {what}')
        time.sleep(1.2)

    def click_on(self, match, what, dx=0, dy=0):
        self.click(match.x + dx, match.y + dy, f'on "{match.line_text}" for {what}')


def wait_for(vm, phrases, timeout, name, **kw):
    deadline = time.time() + timeout
    while time.time() < deadline and vm.alive():
        screen = vm.look(name, quiet=True)
        for phrase in phrases:
            if screen.find(phrase, **kw):
                log(f'--- {name}: found "{phrase}"\n{screen.text()}')
                return screen
        time.sleep(3)
    vm.look(f'{name}-timeout')
    raise RuntimeError(f'None of {phrases} appeared in {timeout} s.')


# --- Running it ----------------------------------------------------------------------

def shell(vm, timeout=420):
    deadline = time.time() + timeout
    while time.time() < deadline:
        vm.serial.sendall(b'\necho "__$((40 + 2))__"\n')
        if vm.wait_serial(r'__42__', 5, max(0, len(vm.text) - 200)):
            vm.sh('stty -echo; export PS1="" PS2=""; export TERM=dumb SYSTEMD_PAGER= PAGER=cat')
            return
    vm.look('no-shell')
    raise RuntimeError('No root shell on the serial port.')


def record(vm, when, commands, report=()):
    for command in commands:
        output, status = vm.sh(command, timeout=120)
        with open(os.path.join(OUT, 'live.txt'), 'a') as f:
            f.write(f'### {when}: {command} (exit {status})\n{output}\n\n')
        if command in report:
            note(f'$ {command}')
            for line in output.splitlines()[-40:]:
                note('  ' + line)


def install(args):
    with open(STATE) as f:
        state = json.load(f)
    distro = state['distro']
    vm = Vm(args.memory)
    started = time.time()
    try:
        found = vm.wait_serial(r'BdsDxe: (loading|starting) Boot\w+ "[^"]*"', 120)
        note('Firmware: ' + (found.group(0) if found else 'no BdsDxe line on the serial port'))
        if distro == 'debian':
            # Step 1: its menu waits for Enter.
            screen = wait_for(vm, ['Live system'], 180, 'live-menu')
            note('Live menu: ' + ' | '.join(screen.lines_with('Live', 'Graphical', 'install')))
            vm.key('ret')
            note('Pressed Enter on Live system')
        else:
            # Its menu starts the first entry by itself.
            time.sleep(8)
            screen = vm.look('live-menu')
            note('Live menu: ' + ' | '.join(screen.lines_with('CachyOS', 'boot')))
        shell(vm)
        note(f'Root shell up {time.time() - started:.0f} s after starting')
        record(vm, 'live system', ('cat /proc/cmdline', 'findmnt -R /run/live /run/archiso', 'lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS',
                                   'free -m'), report=('cat /proc/cmdline', 'findmnt -R /run/live /run/archiso'))
        wait_desktop(vm, distro)
        open_installer(vm, distro)
        drive(vm, distro, state)
        after_install(vm, distro)
        restart(vm)
        settle(vm, args.settle, 'installed')
    finally:
        stop(vm)
        print_vars('after-install')


def wait_desktop(vm, distro):
    shell_name = 'gnome-shell' if distro == 'debian' else 'plasmashell'
    deadline = time.time() + 420
    while time.time() < deadline:
        output, _ = vm.sh(f'pgrep -x {shell_name} >/dev/null && echo up-yes', quiet=True)
        if 'up-yes' in output:
            break
        time.sleep(5)
    else:
        vm.look('no-desktop')
        raise RuntimeError(f'{shell_name} never started.')
    time.sleep(30)
    screen = vm.look('desktop')
    note(f'Desktop up: {shell_name} running')


def calamares_running(vm):
    output, _ = vm.sh('pgrep -x calamares >/dev/null && echo cal-yes', quiet=True)
    return 'cal-yes' in output


def open_installer(vm, distro):
    if distro == 'debian':
        # Step 2: "On the desktop, open Install Debian". GNOME's search is how a person finds it without the dock.
        for attempt in range(3):
            vm.key('meta_l')
            time.sleep(3)
            vm.type('install debian')
            time.sleep(3)
            screen = vm.look('search')
            note(f'Searched for "install debian": ' + ' | '.join(screen.lines_with('Install', 'Debian')))
            vm.key('ret')
            if wait_calamares(vm, 90):
                break
            vm.key('esc')
        else:
            raise RuntimeError('Calamares did not start.')
    else:
        # Step 1: "In the CachyOS Hello window, click Launch installer".
        screen = wait_for(vm, ['Launch installer'], 240, 'hello')
        note('Hello: ' + ' | '.join(screen.lines_with('Launch', 'installer', 'Welcome')))
        vm.click_on(screen.find('Launch installer'), 'Launch installer')
        if not wait_calamares(vm, 300):
            raise RuntimeError('Calamares did not start.')
    note('Calamares started')


def wait_calamares(vm, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if calamares_running(vm):
            time.sleep(10)
            return True
        screen = vm.look('waiting-for-calamares', quiet=True)
        # A password prompt for the installer, which the live user answers with its own password.
        if screen.has('Authentication Required', 'Authenticate', 'requires authentication'):
            note('Password prompt: ' + ' | '.join(screen.lines_with('Authentication', 'password', 'requires')))
            vm.type('live')
            vm.key('ret')
        time.sleep(4)
    return False


BOTTOM_RIGHT = (0.35, 0.6, 1.0, 1.0)


def click_next(vm, screen, label='Next'):
    button = screen.find(label, exact=True, pick='right', region=BOTTOM_RIGHT)
    if button:
        vm.click_on(button, label)
        return True
    # Tesseract doesn't always read it, with its underlined letter, but it's always between Back and Cancel.
    back = screen.find('Back', exact=True, pick='right', region=BOTTOM_RIGHT)
    cancel = screen.find('Cancel', exact=True, pick='right', region=BOTTOM_RIGHT)
    if back and cancel and abs(back.y - cancel.y) < 10 and cancel.x - back.x > 100:
        vm.click((back.x + cancel.x) / 2, cancel.y, f'between Back and Cancel, for {label}')
        return True
    return False


def drive(vm, distro, state):
    """Calamares's real screens, as hop's steps say."""
    done = {}
    deadline = time.time() + 2400
    last = None
    same = 0
    installing = None
    acted = time.time()
    while time.time() < deadline and vm.alive():
        screen = vm.look('calamares', quiet=True)
        text = screen.text()
        # Without the clock, which changes by itself.
        signature = re.sub(r'\d', '', text)
        if signature == last:
            same += 1
        else:
            same = 0
            with open(os.path.join(OUT, 'screens.txt'), 'a') as f:
                f.write(f'===== {time.strftime("%H:%M:%S")} {os.path.basename(screen.path)}\n{text}\n')
        last = signature
        if not installing and time.time() - acted > 300:
            vm.look('stuck')
            raise RuntimeError('Nothing the steps say to do for five minutes:\n' + text)

        def once(name):
            if done.get(name):
                return False
            done[name] = True
            note(f'Screen "{name}": ' + ' | '.join(line for line in text.splitlines() if len(line) > 3)[:1500])
            return True

        if screen.has('Installation Failed', 'Setup Failed', 'Error installing', 'Boost.Python error', 'Bad main script'):
            note('Calamares failed: ' + ' | '.join(text.splitlines()))
            raise RuntimeError('Calamares failed.')
        if screen.has('All done') or (installing and screen.find('Done', exact=True, region=BOTTOM_RIGHT)):
            once('finished')
            return
        if installing:
            if screen.has('Continue with installation', 'overview of what will happen') and time.time() - started_install > 90:
                raise RuntimeError('The install never started:\n' + text)
            if time.time() - installing > 60 and same == 0:
                note('Installing: ' + ' | '.join(screen.lines_with('%', 'Install', 'Running', 'Unpack', 'job', 'package')[:4]))
                installing = time.time()
            time.sleep(10)
            continue
        if screen.has('Install now', 'Continue with installation', 'about to make changes') and not done.get('confirm'):
            once('confirm')
            button = screen.find('Install now') or screen.find('now', exact=True, pick='right')
            if button:
                vm.click_on(button, 'Install now')
            else:
                back = screen.find('Go back', pick='right')
                if not back:
                    raise RuntimeError('No Install now:\n' + text)
                vm.click(back.left - 70, back.y, 'left of Go back, for Install now')
            installing = started_install = time.time()
            continue
        if screen.has('smaller than recommended', 'may fail to start', 'configured incorrectly', 'must be at least') and done.get('manual') and not done.get('summary'):
            # Step: "If the installer then says this partition is small, click OK".
            done['esp-warning'] = done.get('esp-warning', 0) + 1
            note('Warning: ' + ' | '.join(screen.lines_with('EFI', 'partition', 'size', 'must', 'continue', 'fail', 'recommended')))
            if done['esp-warning'] > 3:
                raise RuntimeError('The warning keeps coming back.')
            ok = screen.find('OK', exact=True, pick='right')
            if ok:
                vm.click_on(ok, 'OK on the warning')
            else:
                # Its OK is the default button, which tesseract doesn't always read.
                vm.key('ret')
                log('pressed Return for OK on the warning')
            acted = time.time()
            time.sleep(3)
            continue
        if screen.has('overview of what will happen') and done.get('users') and not done.get('summary'):
            once('summary')
            vm.look('summary')
            click_next(vm, screen, 'Install')
            acted = time.time()
            continue
        if screen.has('What is your name', 'Your Full Name', 'log in automatically') and not done.get('users'):
            once('users')
            users(vm, screen)
            acted = time.time()
            continue
        if screen.has('New Partition Table') and not done.get('manual'):
            once('manual')
            manual(vm, screen, state)
            acted = time.time()
            continue
        if screen.has('Manual partitioning') and not done.get('choice'):
            once('choice')
            choice = screen.find('Manual partitioning')
            vm.click_on(choice, 'Manual partitioning')
            vm.look('manual-chosen')
            click_next(vm, vm.screen)
            acted = time.time()
            continue
        if distro == 'cachyos' and screen.has('GRUB', exact=True) and screen.has('systemd-boot', 'Limine', 'rEFInd') and not done.get('bootloader'):
            # Step 2: "On the Bootloader screen, choose GRUB".
            once('bootloader')
            vm.click_on(screen.find('GRUB', exact=True), 'GRUB')
            vm.look('grub-chosen')
            click_next(vm, vm.screen)
            acted = time.time()
            continue
        if distro == 'cachyos' and screen.has('Plasma Desktop') and screen.has('No Desktop') and not done.get('desktop'):
            # It starts on No Desktop. Plasma is what its live system shows.
            once('desktop')
            vm.click_on(screen.find('Plasma Desktop'), 'Plasma Desktop')
            vm.look('desktop-chosen')
            click_next(vm, vm.screen)
            acted = time.time()
            continue
        if same >= 15:
            raise RuntimeError('Stuck on a screen:\n' + text)
        # Language, location, keyboard and anything else hop's steps leave as they are.
        if click_next(vm, screen):
            page = next((line for line in text.splitlines() if len(line) > 8), '')
            note(f'Next on a screen the steps leave alone: {page[:200]}')
            time.sleep(3)
            continue
        time.sleep(4)
    vm.look('timeout')
    raise RuntimeError('Calamares did not finish in time.')


def field_right_of(vm, screen, label, what):
    """Clicks the box to the right of a label in a dialog: on the text in it, if there is any."""
    match = screen.find(label, colon=True) or screen.find(label, pick='bottom')
    if not match:
        raise RuntimeError(f'No "{label}" on screen:\n{screen.text()}')
    inside = [w for w in match.line if w.left > match.right and w.left - match.right < 200]
    if inside:
        vm.click(inside[0].cx, match.y, f'on "{inside[0].text}" right of "{label}" for {what}')
    else:
        vm.click(match.right + 60, match.y, f'the box right of "{label}" for {what}')
    return match


def manual(vm, screen, state):
    note('Partition list: ' + ' | '.join(screen.lines_with('nvme', 'Free Space', 'Windows', 'Boot Manager', 'EFI', 'Storage')))
    # Step: "Click the {GB} GB of Free Space, click Create and make an ext4 partition mounted at /".
    free = screen.find('Free Space', line_has=str(LINUX_GB), pick='bottom') or screen.find('Free Space', pick='bottom')
    if not free:
        raise RuntimeError('No Free Space row.')
    vm.click_on(free, 'the free space')
    screen = vm.look('free-chosen')
    vm.click_on(screen.find('Create', exact=True, pick='bottom'), 'Create')
    screen = wait_for(vm, ['Create a Partition', 'Flags'], 30, 'create-dialog')
    note('Create dialog: ' + ' | '.join(screen.lines_with('Size', 'File System', 'Mount', 'Flags', 'Label')))
    fs = screen.find('File System', colon=True)
    if fs and not any(w.key == canon('ext4') for w in fs.line):
        field_right_of(vm, screen, 'File System', 'the file system')
        screen = vm.look('fs-list')
        ext4 = [m for m in screen.find_all('ext4', exact=True) if abs(m.y - fs.y) > 5] or screen.find_all('ext4', exact=True)
        if not ext4:
            raise RuntimeError('No ext4 in the list.')
        vm.click_on(ext4[0], 'ext4')
        screen = vm.look('fs-chosen')
        fs = screen.find('File System', colon=True)
        if fs and not any(w.key == canon('ext4') for w in fs.line):
            # Its list also finds an entry by the first letter typed.
            field_right_of(vm, screen, 'File System', 'the file system')
            vm.type('e')
            vm.key('ret')
            screen = vm.look('fs-chosen-by-key')
    note('File system now: ' + ' | '.join(screen.lines_with('File System')))
    field_right_of(vm, screen, 'Mount Point', 'the mount point')
    vm.key('ctrl', 'a')
    vm.type('/')
    screen = vm.look('root-typed')
    note('Mount point now: ' + ' | '.join(screen.lines_with('Mount Point')))
    vm.key('ret')
    screen = vm.look('root-made')
    if screen.has('Create a Partition'):
        vm.click_on(screen.find('OK', exact=True, pick='right'), 'OK')
        screen = vm.look('root-made-2')
    note('After Create: ' + ' | '.join(screen.lines_with('nvme', 'Free Space', 'New partition', 'ext4')))

    # Step: "Click {ESP}. Click Edit, choose Keep so it isn't formatted, and set the mount point to /boot/efi".
    esp = screen.find('nvme0n1p1', pick='bottom') or screen.find('/dev/nvme0n1p1', pick='bottom')
    if not esp:
        raise RuntimeError('No nvme0n1p1 row:\n' + screen.text())
    vm.click_on(esp, 'the EFI partition')
    screen = vm.look('esp-chosen')
    vm.click_on(screen.find('Edit', exact=True, pick='bottom'), 'Edit')
    screen = wait_for(vm, ['Edit Existing Partition', 'Keep'], 30, 'edit-dialog')
    note('Edit dialog: ' + ' | '.join(screen.lines_with('Content', 'Keep', 'Format', 'Mount', 'File', 'Size', 'Flags')))
    vm.click_on(screen.find('Keep', exact=True), 'Keep')
    screen = vm.look('keep-chosen')
    field_right_of(vm, screen, 'Mount Point', 'the mount point')
    vm.key('ctrl', 'a')
    vm.type('/boot/efi')
    screen = vm.look('efi-typed')
    note('Mount point now: ' + ' | '.join(screen.lines_with('Mount Point')))
    vm.key('ret')
    screen = vm.look('esp-edited')
    if screen.has('Edit Existing Partition'):
        vm.click_on(screen.find('OK', exact=True, pick='right'), 'OK')
        screen = vm.look('esp-edited-2')
    note('Partition list now: ' + ' | '.join(screen.lines_with('nvme', 'Free Space', 'New partition', 'ext4', 'fat32', '/boot/efi')))
    click_next(vm, screen)


def users(vm, screen):
    box = screen.find('Your Full Name')
    if box:
        vm.click_on(box, 'the name box')
    else:
        label = screen.find('What is your name')
        vm.click(label.left + 60, label.bottom + 22, 'below "What is your name"')
    vm.type(FULL_NAME)
    time.sleep(1)
    screen = vm.look('name-typed')
    box = screen.find('Repeat Password') or screen.find('Password', exact=True, pick='left')
    password = [m for m in screen.find_all('Password', exact=True) if (not box or m.x < box.x - 20) and not re.search(r'(?i)choose|keep|account|same', m.line_text)]
    if password:
        vm.click_on(password[0], 'the password box')
    elif box:
        vm.click(box.left - 150, box.y, 'left of "Repeat Password"')
    else:
        label = screen.find('Choose a password')
        vm.click(label.left + 60, label.bottom + 22, 'below "Choose a password"')
    vm.type(PASSWORD)
    vm.key('tab')
    vm.type(PASSWORD)
    time.sleep(1)
    screen = vm.look('users-filled')
    note('Users screen: ' + ' | '.join(line for line in screen.text().splitlines() if len(line) > 3)[:1200])
    click_next(vm, screen)


def after_install(vm, distro):
    note('--- live system, after the install')
    record(vm, 'after', (
        'f=$(find / -xdev -path "*alamares*" -name session.log 2>/dev/null | head -n 1); echo "$f"; grep -n -i -E "error|fail|warn" "$f" | grep -v -i "nofail" | tail -n 30',
        'f=$(find / -xdev -path "*alamares*" -name session.log 2>/dev/null | head -n 1); grep -n -E "grub-install|efibootmgr|bootloader|mkfs|sfdisk|partition" "$f" | tail -n 40',
        'parted -s /dev/nvme0n1 unit MiB print',
        'lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS',
        'efibootmgr -v'),
        report=('parted -s /dev/nvme0n1 unit MiB print', 'efibootmgr -v'))
    # A marker the installed system writes as it starts, to show where it started from. It changes nothing else.
    output, _ = vm.sh('for d in $(lsblk -nrpo NAME,FSTYPE /dev/nvme0n1 | awk \'$2=="ext4"{print $1}\'); do echo "root=$d"; done')
    roots = re.findall(r'root=(\S+)', output)
    if not roots:
        note('No ext4 partition on the disk after the install.')
        return
    root = roots[0]
    note(f'The new root partition: {root}')
    lines = ['#!/bin/sh', 'sleep 60', 'mkdir -p /var/lib/hop-marker', 'n=$(ls /var/lib/hop-marker | wc -l)',
             'f=/var/lib/hop-marker/boot-$((n+1)).txt',
             '{ date; cat /proc/cmdline; echo "root $(findmnt -no SOURCE /)"; echo "efi $(findmnt -no SOURCE /boot/efi)";'
             ' echo "display-manager $(systemctl is-active display-manager)"; echo "graphical $(systemctl is-active graphical.target)";'
             ' loginctl list-sessions --no-legend; lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINTS; } > $f 2>&1', 'sync']
    unit = ['[Unit]', 'Description=hop test marker', '[Service]', 'Type=simple', 'ExecStart=/usr/local/sbin/hop-marker', '[Install]', 'WantedBy=multi-user.target']
    quoted = ' '.join("'" + line.replace("'", "'\\''") + "'" for line in lines)
    vm.sh(f'mkdir -p /run/hoproot && mount {root} /run/hoproot && mkdir -p /run/hoproot/usr/local/sbin && printf "%s\\n" {quoted} > /run/hoproot/usr/local/sbin/hop-marker && chmod 755 /run/hoproot/usr/local/sbin/hop-marker')
    vm.sh('printf "%s\\n" ' + ' '.join(f"'{line}'" for line in unit) + ' > /run/hoproot/etc/systemd/system/hop-marker.service && '
          'mkdir -p /run/hoproot/etc/systemd/system/multi-user.target.wants && ln -sf /etc/systemd/system/hop-marker.service /run/hoproot/etc/systemd/system/multi-user.target.wants/hop-marker.service')
    record(vm, 'target', ('cat /run/hoproot/etc/fstab', 'grep -n -E "search|linux\\s|set root|insmod part" /run/hoproot/boot/grub/grub.cfg | head -n 20',
                          'cat /run/hoproot/usr/local/sbin/hop-marker', 'umount /run/hoproot'),
           report=('cat /run/hoproot/etc/fstab', 'grep -n -E "search|linux\\s|set root|insmod part" /run/hoproot/boot/grub/grub.cfg | head -n 20'))


def restart(vm):
    screen = vm.look('finished')
    mark = len(vm.text)
    done = screen.find('Done', exact=True, pick='right', region=BOTTOM_RIGHT)
    if done:
        vm.click_on(done, 'Done')
    found = vm.wait_serial(r'BdsDxe: (loading|starting) Boot\w+ "[^"]*"', 60, mark)
    if not found:
        note('Done did not restart it, so the test ran systemctl reboot in the live system')
        vm.serial.sendall(b'systemctl reboot\n')
        found = vm.wait_serial(r'BdsDxe: (loading|starting) Boot\w+ "[^"]*"', 180, mark)
    else:
        note('Clicked Done, and it restarted')
    note('Firmware after the install: ' + (found.group(0) if found else 'no BdsDxe line on the serial port'))


def settle(vm, seconds, stage):
    end = time.time() + seconds
    while time.time() < end and vm.alive():
        time.sleep(30)
        vm.look(stage, quiet=True)
    screen = vm.look(f'{stage}-last')
    note(f'Screen after {seconds} s: ' + ' | '.join(line for line in screen.text().splitlines() if len(line) > 2)[:600])
    if screen.has('no such partition', 'grub rescue', 'rescue>', 'Minimal BASH-like', 'grub>'):
        note('GRUB STOPPED: ' + ' | '.join(screen.text().splitlines()))


def stop(vm):
    if vm.alive():
        try:
            vm.qmp('system_powerdown')
        except Exception as e:
            log(f'powerdown: {e}')
        for _ in range(60):
            if not vm.alive():
                break
            time.sleep(1)
        note('It turned itself off' if not vm.alive() else 'It did not turn off within 60 s, so QEMU was stopped')
    if vm.alive():
        try:
            vm.qmp('quit')
        except Exception:
            vm.qemu.kill()
    vm.qemu.wait(30)


def boot(args):
    """Starts from the disk again, with nothing changed in the firmware."""
    vm = Vm(args.memory)
    try:
        found = vm.wait_serial(r'BdsDxe: (loading|starting) Boot\w+ "[^"]*"', 120)
        note(f'Firmware, {args.stage}: ' + (found.group(0) if found else 'no BdsDxe line on the serial port'))
        time.sleep(20)
        vm.look(f'{args.stage}-early')
        settle(vm, args.settle, args.stage)
    finally:
        stop(vm)
        print_vars(f'after-{args.stage}')


# --- Windows removing hop's installer partition ---------------------------------------

def numbers():
    table = run('sgdisk', '-p', DISK, capture=True)
    return [int(m.group(1)) for m in re.finditer(r'(?m)^\s+(\d+)\s+\d+\s+\d+', table)], table


def renumber(args):
    """Deletes HOPINSTALL and moves every later GPT entry down one, as tests/Probe-GptNumbers.ps1 saw Windows do."""
    present, table = numbers()
    note('--- before removing HOPINSTALL\n' + table)
    gone = NUMBERS['HOPINSTALL']
    run('sgdisk', '-d', str(gone), DISK)
    for number in sorted(n for n in present if n > gone):
        run('sgdisk', '-r', f'{number - 1}:{number}', DISK)
        note(f'Partition {number} is now {number - 1}')
    present, table = numbers()
    note('--- after\n' + table)
    run('sgdisk', '-v', DISK, check=False)


# --- What changed --------------------------------------------------------------------

def check(args):
    with open(STATE) as f:
        state = json.load(f)
    failures = []
    layout = run('sgdisk', '-p', DISK, capture=True)
    with open(os.path.join(OUT, f'layout-{args.stage}.txt'), 'w') as f:
        f.write(layout)
    note(f'--- the disk, {args.stage}\n' + layout)
    names = [n for n in NUMBERS if not (args.stage == 'renumbered' and n == 'HOPINSTALL')]
    loop = attach(read_only=True)
    try:
        after = partition_hashes(loop, names)
        for name in names:
            same = after[name] == state['partitions'][name]
            note(f'{name}: {"byte for byte the same" if same else "CHANGED"}')
            if not same:
                failures.append(name)
        esp_after = esp_hashes(loop)
        for path, digest in sorted(state['esp'].items()):
            same = esp_after.get(path) == digest
            note(f'EFI partition {path}: {"unchanged" if same else "CHANGED or gone"}')
            if not same:
                failures.append(path)
        for path in sorted(set(esp_after) - set(state['esp'])):
            note(f'EFI partition {path}: new')
        blkid = run('blkid', check=False, capture=True)
        note('blkid:\n' + '\n'.join(line for line in blkid.splitlines() if loop in line))
        root = next((line.split(':')[0] for line in blkid.splitlines() if loop in line and 'TYPE="ext4"' in line), None)
        if not root:
            failures.append('no ext4 root')
        else:
            system = mount(root, os.path.join(WORK, 'chk-root'), '-o', 'ro,noload')
            try:
                inspect_root(system, failures, args.stage)
            finally:
                run('umount', system, check=False)
        esp = mount(f'{loop}p1', os.path.join(WORK, 'chk-esp'), '-o', 'ro')
        try:
            for folder, _, files in os.walk(os.path.join(esp, 'EFI')):
                for name in files:
                    path = os.path.join(folder, name)
                    rel = os.path.relpath(path, esp)
                    if rel.lower().startswith(('efi/microsoft', 'efi/hop', 'efi/boot/bootx64')):
                        continue
                    if name.endswith('.cfg'):
                        with open(path, errors='replace') as f:
                            note(f'{rel}: ' + ' | '.join(f.read().splitlines()))
                    elif name.lower().endswith('.efi'):
                        # The config GRUB carries inside itself, which is how it finds its own files.
                        strings = run('strings', '-a', '-n', '6', path, capture=True)
                        embedded = [s for s in strings.splitlines() if re.search(r'search|prefix|\(hd\d|gpt\d|/boot/grub|fs_uuid|configfile', s)]
                        note(f'{rel}, {os.path.getsize(path)} bytes, its own text: ' + ' | '.join(embedded[:15]))
        finally:
            run('umount', esp, check=False)
    finally:
        run('losetup', '-d', loop, check=False)
    entries = print_vars(f'check-{args.stage}')
    for line in entries.splitlines():
        if re.search(r'Boot[0-9A-F]{4}|BootOrder|BootNext', line):
            note('NVRAM ' + line.strip())
    note(f'RESULT {args.stage}: ' + ('pass' if not failures else 'FAIL ' + '; '.join(failures)))
    sys.exit(1 if failures else 0)


def inspect_root(system, failures, stage):
    def show(path, pattern=None, limit=30):
        full = os.path.join(system, path)
        if not os.path.exists(full):
            note(f'{path}: not there')
            return ''
        with open(full, errors='replace') as f:
            text = f.read()
        lines = [line for line in text.splitlines() if not pattern or re.search(pattern, line)]
        note(f'{path}: ' + ' | '.join(lines[:limit]))
        return text

    show('etc/os-release', r'^(PRETTY_NAME|VERSION_ID|ID)=')
    show('etc/fstab', r'^[^#]')
    show('boot/grub/grub.cfg', r'search|set root|insmod part_|linux\s', 25)
    journal = os.path.join(system, 'var/log/journal')
    if os.path.isdir(journal):
        boots = run('journalctl', '-D', journal, '--list-boots', '--no-pager', check=False, capture=True)
        note('Installed system boots:\n' + boots)
        text = run('journalctl', '-D', journal, '-b', '0', '--no-pager', '-o', 'short-monotonic', check=False, capture=True)
        with open(os.path.join(OUT, f'journal-{stage}.txt'), 'w') as f:
            f.write(text)
        picked = [line for line in text.splitlines() if re.search(
            r'Linux version|Command line|Reached target|Startup finished|gdm|sddm|session opened|Welcome to|EXT4-fs \(nvme', line)]
        for line in picked[:40]:
            note('  ' + line)
        if not re.search(r'Reached target .*[Gg]raphical', text):
            failures.append('no graphical target in the installed system\'s journal')
    else:
        note('No persistent journal')
    markers = os.path.join(system, 'var/lib/hop-marker')
    if os.path.isdir(markers):
        for name in sorted(os.listdir(markers)):
            with open(os.path.join(markers, name), errors='replace') as f:
                note(f'Marker {name}: ' + ' | '.join(f.read().splitlines()))
    else:
        note('No marker: the installed system never ran it')
        failures.append('no marker')
    for name in ('var/log/Calamares.log', 'var/log/installer/Calamares.log', 'var/log/calamares.log'):
        if os.path.exists(os.path.join(system, name)):
            shutil.copyfile(os.path.join(system, name), os.path.join(OUT, f'Calamares-{stage}.log'))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('prepare')
    p.add_argument('--distro', required=True, choices=sorted(NAMES))
    p.add_argument('--iso', required=True)
    p = sub.add_parser('install')
    p.add_argument('--memory', type=int, default=8)
    p.add_argument('--settle', type=int, default=240, help='seconds to leave the installed system running')
    p = sub.add_parser('boot')
    p.add_argument('--memory', type=int, default=8)
    p.add_argument('--settle', type=int, default=180)
    p.add_argument('--stage', required=True)
    sub.add_parser('renumber')
    p = sub.add_parser('check')
    p.add_argument('--stage', required=True)
    args = parser.parse_args()
    os.makedirs(OUT, exist_ok=True)
    {'prepare': prepare, 'install': install, 'boot': boot, 'renumber': renumber, 'check': check}[args.command](args)


if __name__ == '__main__':
    main()
