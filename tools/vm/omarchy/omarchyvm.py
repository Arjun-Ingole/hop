#!/usr/bin/env python3
"""Installs Omarchy next to a stand-in Windows, on a disk laid out as hop leaves one, in QEMU with OVMF.

The disk gets a 100 MB EFI partition, an NTFS "C:", FAT32 HOPINSTALL and exFAT HOPLIVE, sized and filled as hop
does it, then free space. prepare.ps1 runs the engine's own Update-BootConfig and Copy-EspLoader on it. The firmware
then starts hop's loader through Boot0042 and BootNext, as hop writes them. Keys go in through QEMU, and the screen
comes back from /dev/vcsu1 over a root shell on the serial port, which this test adds to the live system's menu.

    omarchyvm.py prepare --iso omarchy.iso       lay out and fill the disk, and write the startup entries
    omarchyvm.py install [--memory 8]            start it, install into the free space, restart and wait
    omarchyvm.py check                           what changed on the disk, and what the installed system logged

Needs root, qemu-system-x86, ovmf, gdisk, dosfstools, exfatprogs, ntfs-3g, pwsh and virt-firmware.
"""
import argparse
import hashlib
import json
import os
import random
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get('OMARCHYVM_WORK', '/mnt/ovm')
OUT = os.path.join(WORK, 'out')
DISK = os.path.join(WORK, 'disk.raw')
VARS = os.path.join(WORK, 'vars.fd')
STATE = os.path.join(WORK, 'state.json')
OVMF_CODE = '/usr/share/OVMF/OVMF_CODE_4M.fd'
OVMF_VARS = '/usr/share/OVMF/OVMF_VARS_4M.fd'
DISK_GB = 80
FREE_GB = 40
USER = 'hop'
PASSWORD = 'hopvm-test-1'
# Added after hop's own edits, for this test only: a root shell on the serial port, to read the screen with.
TEST_ARGS = 'systemd.debug_shell=ttyS0'

SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': 'minus', '+': 'equal', ':': 'semicolon', '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash'}
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '.': 'dot', '/': 'slash', ',': 'comma', ';': 'semicolon'}


def log(text):
    print(f'[{time.strftime("%H:%M:%S")}] {text}', flush=True)


def note(text):
    """A line for the report, which is what docs/TESTING.md is written from."""
    log('REPORT ' + text)
    with open(os.path.join(OUT, 'report.txt'), 'a') as f:
        f.write(text + '\n')


def run(*argv, check=True, capture=False):
    log('$ ' + ' '.join(str(a) for a in argv))
    result = subprocess.run([str(a) for a in argv], check=check, text=True,
                            stdout=subprocess.PIPE if capture else None, stderr=subprocess.STDOUT if capture else None)
    return result.stdout if capture else result.returncode


def sha256_of(path, limit=None):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        left = limit
        while True:
            chunk = f.read(4 << 20 if left is None else min(4 << 20, left))
            if not chunk:
                break
            h.update(chunk)
            if left is not None:
                left -= len(chunk)
                if left <= 0:
                    break
    return h.hexdigest()


def attach(read_only=False):
    loop = run('losetup', '-P', '--show', '-f', *(['-r'] if read_only else []), DISK, capture=True).strip()
    run('udevadm', 'settle')
    for _ in range(50):
        if os.path.exists(loop + 'p1'):
            break
        time.sleep(0.2)
    return loop


def mount(device, folder, *options):
    os.makedirs(folder, exist_ok=True)
    run('mount', *options, device, folder)
    return folder


# --- Laying out the disk -------------------------------------------------------------

def tree_hashes(root):
    found = {}
    for folder, _, files in os.walk(root):
        for name in files:
            path = os.path.join(folder, name)
            found[os.path.relpath(path, root)] = sha256_of(path)
    return found


def partition_hashes(loop):
    # Replacing Windows leaves fewer partitions than there were.
    return {name: sha256_of(f'{loop}p{number}') if os.path.exists(f'{loop}p{number}') else None
            for number, name in ((2, 'C:'), (3, 'HOPINSTALL'), (4, 'HOPLIVE'))}


def gpt_entry(number):
    """First sector, size in sectors and unique GUID of a partition, from sgdisk."""
    text = run('sgdisk', '-i', number, DISK, capture=True)
    first = int(re.search(r'First sector: (\d+)', text).group(1))
    last = int(re.search(r'Last sector: (\d+)', text).group(1))
    guid = re.search(r'Partition unique GUID: ([0-9A-F-]+)', text).group(1)
    return first, last - first + 1, guid


def load_option_path(number, first, size, guid, path):
    """The device path hop's Firmware.LoadOption writes: hard drive node, file path node, end."""
    hd = struct.pack('<BBHIQQ', 0x04, 0x01, 42, number, first, size) + uuid.UUID(guid).bytes_le + bytes([0x02, 0x02])
    name = (path + '\0').encode('utf-16-le')
    return hd + struct.pack('<BBH', 0x04, 0x04, 4 + len(name)) + name + bytes([0x7F, 0xFF, 0x04, 0x00])


def write_vars(first, size, guid):
    from virt.firmware.varstore import autodetect
    from virt.firmware.efi import devpath
    shutil.copyfile(OVMF_VARS, VARS)
    store = autodetect.open_varstore(VARS)
    variables = store.get_varlist()
    # A stand-in for Windows first, which the firmware can't start, then hop's entry, as Register-Installer adds it.
    variables.set_boot_entry(0x0000, 'Windows Boot Manager', devpath.DevicePath(load_option_path(1, first, size, guid, r'\EFI\Microsoft\Boot\bootmgfw.efi')))
    variables.append_boot_order(0x0000)
    variables.set_boot_entry(0x0042, 'Omarchy installer (hop)', devpath.DevicePath(load_option_path(1, first, size, guid, r'\EFI\hop\BOOTX64.EFI')))
    variables.append_boot_order(0x0042)
    variables.set_boot_next(0x0042)
    store.write_varstore(VARS, variables)
    note('Startup entries: Boot0000 "Windows Boot Manager" (a stand-in), Boot0042 "Omarchy installer (hop)" at \\EFI\\hop\\BOOTX64.EFI, BootNext 0042')


def print_vars(name):
    text = run('virt-fw-vars', '--input', VARS, '--print', check=False, capture=True)
    with open(os.path.join(OUT, f'vars-{name}.txt'), 'w') as f:
        f.write(text)
    return text


def prepare(args):
    os.makedirs(OUT, exist_ok=True)
    iso = mount(args.iso, os.path.join(WORK, 'iso'), '-o', 'loop,ro')
    sizes = json.loads(run('pwsh', '-NoProfile', '-File', os.path.join(HERE, 'prepare.ps1'), 'sizes', iso, capture=True))
    log(json.dumps(sizes, indent=1))
    note(f'ISO {os.path.basename(args.iso)}: HOPINSTALL {sizes["InstallerGB"]} GB for {sizes["Bytes"]} bytes, '
         f'HOPLIVE {sizes["LiveGB"]} GB for {sizes["LiveBytes"]} bytes: {", ".join(sizes["LiveFiles"])}')
    note(f'The kernel its menu starts, as Read-Iso finds it: {sizes["Kernel"]}, there: {sizes["KernelFound"]}')
    # No kernel at all means pwsh couldn't read the menu here, which says nothing about Windows.
    if sizes['TooBig'] or sizes['Untried'] or not sizes['BootKnown'] or (sizes['Kernel'] and not sizes['KernelFound']):
        note(f'hop would refuse this ISO: too big {sizes["TooBig"]}, untried {sizes["Untried"]}, boot known {sizes["BootKnown"]}, kernel found {sizes["KernelFound"]}')
        sys.exit(1)
    note(f'Replacing Windows with this ISO would be refused as untried: {sizes["FullDiskUntried"]}')
    if args.full_disk and sizes['FullDiskUntried']:
        sys.exit(1)
    live = set(sizes['LiveFiles'])

    windows_gb = DISK_GB - FREE_GB - sizes['InstallerGB'] - sizes['LiveGB'] - 1
    if os.path.exists(DISK):
        os.unlink(DISK)
    with open(DISK, 'wb') as f:
        f.truncate(DISK_GB << 30)
    run('sgdisk', '-o',
        '-n', '1:2048:+100M', '-t', '1:ef00', '-c', '1:EFI system partition',
        '-n', f'2:0:+{windows_gb}G', '-t', '2:0700', '-c', '2:Basic data partition',
        '-n', f'3:0:+{sizes["InstallerGB"]}G', '-t', '3:0700', '-c', '3:Basic data partition',
        '-n', f'4:0:+{sizes["LiveGB"]}G', '-t', '4:0700', '-c', '4:Basic data partition', DISK)
    layout = run('sgdisk', '-p', DISK, capture=True)
    with open(os.path.join(OUT, 'layout-before.txt'), 'w') as f:
        f.write(layout)
    log(layout)

    loop = attach()
    try:
        run('mkfs.fat', '-F', '32', '-n', 'SYSTEM', f'{loop}p1')
        run('mkntfs', '-Q', '-L', 'Windows', f'{loop}p2')
        run('mkfs.fat', '-F', '32', '-n', 'HOPINSTALL', f'{loop}p3')
        run('mkfs.exfat', '-L', 'HOPLIVE', f'{loop}p4')

        # Windows' files are stand-ins, there to show whether anything changes them.
        esp = mount(f'{loop}p1', os.path.join(WORK, 'esp'))
        os.makedirs(os.path.join(esp, 'EFI/Microsoft/Boot'))
        os.makedirs(os.path.join(esp, 'EFI/Boot'))
        rng = random.Random(42)
        loader = bytes(rng.getrandbits(8) for _ in range(1 << 20))
        for path in ('EFI/Microsoft/Boot/bootmgfw.efi', 'EFI/Boot/bootx64.efi'):
            with open(os.path.join(esp, path), 'wb') as f:
                f.write(loader)
        with open(os.path.join(esp, 'EFI/Microsoft/Boot/BCD'), 'wb') as f:
            f.write(bytes(rng.getrandbits(8) for _ in range(32768)))
        windows = mount(f'{loop}p2', os.path.join(WORK, 'windows'), '-t', 'ntfs3')
        os.makedirs(os.path.join(windows, 'Windows/System32'))
        with open(os.path.join(windows, 'Windows/System32/stand-in.bin'), 'wb') as f:
            f.write(os.urandom(256 << 20))
        run('umount', windows)

        # What Copy-Installer and Copy-LiveFiles copy: every file Windows can see, the live ones on HOPLIVE.
        installer = mount(f'{loop}p3', os.path.join(WORK, 'installer'))
        second = mount(f'{loop}p4', os.path.join(WORK, 'live'))
        copied = 0
        for folder, _, files in os.walk(iso):
            for name in files:
                source = os.path.join(folder, name)
                if os.path.islink(source):
                    continue
                relative = os.path.relpath(source, iso)
                target = os.path.join(second if relative in live else installer, relative)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copyfile(source, target)
                if sha256_of(source) != sha256_of(target):
                    raise RuntimeError(f'{relative} copied with damage')
                copied += 1
        log(f'Copied and checked {copied} files.')

        # The engine's own edits, as Install-Linux and Register-Installer make them, and its loader on the EFI partition.
        run('pwsh', '-NoProfile', '-File', os.path.join(HERE, 'prepare.ps1'), 'boot', installer, esp, *(['-FullDisk'] if args.full_disk else []))
        menu = os.path.join(installer, 'boot/grub/grub.cfg')
        shutil.copyfile(menu, os.path.join(OUT, 'grub-hop.cfg'))
        with open(menu, encoding='latin-1') as f:
            text = f.read()
        hop_lines = [line.strip() for line in text.splitlines() if re.match(r'\s*linux\s', line)]
        note('hop\'s menu line: ' + hop_lines[0])
        text = re.sub(r'(?m)^(\s*linux\s.*)$', lambda m: m.group(1) + ' ' + TEST_ARGS, text)
        with open(menu, 'w', encoding='latin-1') as f:
            f.write(text)
        with open(os.path.join(esp, 'EFI/hop/grub.cfg')) as f:
            note('hop\'s grub.cfg on the EFI partition: ' + ' | '.join(f.read().splitlines()))
        run('ls', '-la', os.path.join(esp, 'EFI/hop'), os.path.join(second, 'arch/x86_64'))
        run('df', '-h', installer, second, esp)
        for folder in (esp, installer, second):
            run('umount', folder)

        state = {'esp': tree_hashes_mounted(loop), 'partitions': partition_hashes(loop), 'sizes': sizes, 'full_disk': args.full_disk}
    finally:
        run('losetup', '-d', loop, check=False)
        run('umount', iso, check=False)
    first, size, guid = gpt_entry(1)
    state['esp_entry'] = [first, size, guid]
    write_vars(first, size, guid)
    print_vars('before')
    with open(STATE, 'w') as f:
        json.dump(state, f, indent=1)


def tree_hashes_mounted(loop):
    folder = mount(f'{loop}p1', os.path.join(WORK, 'esp-read'), '-o', 'ro')
    try:
        return tree_hashes(folder)
    finally:
        run('umount', folder)


# --- Running it ----------------------------------------------------------------------

class Vm:
    def __init__(self, memory_gb):
        self.qmp_path = os.path.join(WORK, 'qmp.sock')
        self.serial_path = os.path.join(WORK, 'serial.sock')
        for path in (self.qmp_path, self.serial_path):
            if os.path.exists(path):
                os.unlink(path)
        argv = ['qemu-system-x86_64', '-name', 'omarchyvm', '-enable-kvm', '-machine', 'q35,accel=kvm', '-cpu', 'host',
                '-smp', '4', '-m', f'{memory_gb}G',
                '-drive', f'if=pflash,format=raw,readonly=on,file={OVMF_CODE}',
                '-drive', f'if=pflash,format=raw,file={VARS}',
                '-device', 'VGA,vgamem_mb=64,xres=1280,yres=800', '-display', 'none',
                '-netdev', 'user,id=n0', '-device', 'e1000e,netdev=n0',
                '-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0',
                # No bootindex: the firmware goes by BootNext and BootOrder, as a PC does.
                '-drive', f'file={DISK},if=none,id=os,format=raw,cache=unsafe,aio=threads',
                '-device', 'nvme,drive=os,serial=HOP0001',
                '-chardev', f'socket,id=ser0,path={self.serial_path},server=on,wait=off,logfile={OUT}/serial.log,logappend=on',
                '-serial', 'chardev:ser0',
                '-qmp', f'unix:{self.qmp_path},server=on,wait=off']
        log('$ ' + ' '.join(argv))
        self.qemu = subprocess.Popen(argv)
        for _ in range(100):
            if os.path.exists(self.qmp_path) and os.path.exists(self.serial_path):
                break
            time.sleep(0.1)
        self.qmp_sock = socket.socket(socket.AF_UNIX)
        self.qmp_sock.connect(self.qmp_path)
        self.qmp_file = self.qmp_sock.makefile('rw')
        self.qmp_file.readline()
        self.qmp('qmp_capabilities')
        self.serial = socket.socket(socket.AF_UNIX)
        self.serial.connect(self.serial_path)
        self.text = ''
        self.lock = threading.Lock()
        threading.Thread(target=self.read_serial, daemon=True).start()
        self.shots = 0
        self.marker = 0

    def read_serial(self):
        while True:
            try:
                data = self.serial.recv(65536)
            except OSError:
                return
            if not data:
                return
            with self.lock:
                self.text += data.decode('utf-8', 'replace')

    def qmp(self, name, **arguments):
        self.qmp_file.write(json.dumps({'execute': name, 'arguments': arguments}) + '\n')
        self.qmp_file.flush()
        while True:
            line = self.qmp_file.readline()
            if not line:
                raise RuntimeError('QEMU has gone')
            reply = json.loads(line)
            if 'return' in reply:
                return reply['return']
            if 'error' in reply:
                raise RuntimeError(f'{name}: {reply["error"]}')

    def alive(self):
        return self.qemu.poll() is None

    def shot(self, name):
        self.shots += 1
        path = os.path.join(OUT, f'{self.shots:03}-{name}.png')
        try:
            self.qmp('screendump', filename=path, format='png')
        except Exception as e:
            log(f'screendump failed: {e}')
        return path

    def key(self, *combo):
        self.qmp('send-key', keys=[{'type': 'qcode', 'data': k} for k in combo], **{'hold-time': 60})
        time.sleep(0.15)

    def type(self, text):
        for ch in text:
            if ch.isascii() and ch.isalpha():
                combo = ['shift', ch.lower()] if ch.isupper() else [ch]
            elif ch.isdigit():
                combo = [ch]
            elif ch in SHIFTED:
                combo = ['shift', SHIFTED[ch]]
            else:
                combo = [PLAIN[ch]]
            self.key(*combo)

    def serial_since(self, start):
        with self.lock:
            return self.text[start:]

    def wait_serial(self, pattern, timeout, start=0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            found = re.search(pattern, self.serial_since(start))
            if found:
                return found
            if not self.alive():
                return None
            time.sleep(0.5)
        return None

    # The root shell on the serial port. The marker is worked out by the shell, so its own echo doesn't match.
    def sh(self, command, timeout=60, quiet=False):
        self.marker += 1
        start = len(self.text)
        self.serial.sendall(f'{command}; echo "__$(( {self.marker} * 1000 + 7 ))__ $?"\n'.encode())
        found = self.wait_serial(rf'__{self.marker * 1000 + 7}__ (\d+)', timeout, start)
        output = self.serial_since(start)
        if found:
            output = output[:output.rfind(f'__{self.marker * 1000 + 7}__')]
        output = output.replace('\r', '')
        # The echoed command comes first.
        if command in output:
            output = output[output.find(command) + len(command):]
        output = re.sub(r'^.*__\$\(\(.*?\)\)__ \$\?"\n?', '', output, count=1, flags=re.S)
        if not quiet:
            log(f'# {command}\n{output.rstrip()}')
        return output.strip(), (int(found.group(1)) if found else None)

    def screen(self):
        text, _ = self.sh("python3 -c 'import sys;h=open(\"/dev/vcsa1\",\"rb\").read(4);r,c=h[0],h[1];"
                          "t=open(\"/dev/vcsu1\",\"rb\").read().decode(\"utf-32-le\",\"replace\");"
                          "print(chr(10).join(t[i*c:(i+1)*c].rstrip() for i in range(r)))'", quiet=True)
        return text


def screen_lines(screen):
    return [line.strip() for line in screen.splitlines() if line.strip()]


def cursor_line(screen):
    for line in screen.splitlines():
        stripped = line.strip()
        if stripped.startswith('>') or stripped.startswith('❯') or stripped.startswith('→'):
            return stripped
    return ''


def choose(vm, target, what):
    """Moves gum choose's cursor to the line with target, as a person pressing Down would, then Return."""
    presses = 0
    for _ in range(15):
        screen = vm.screen()
        current = cursor_line(screen)
        if target in current:
            note(f'{what}: the cursor started on the {"first" if presses == 0 else "other"} line; Down pressed {presses} times to reach "{current}"')
            vm.key('ret')
            return
        vm.key('down')
        presses += 1
        time.sleep(0.6)
    raise RuntimeError(f'Could not find {target!r} on screen:\n{screen}')


def live_checks(vm, when):
    note(f'--- live system, {when}')
    for command in ('cat /proc/cmdline',
                    'systemctl status kernel-command-line.service --no-pager -l | head -n 20',
                    'findmnt -no SOURCE /run/archiso/bootmnt; echo "findmnt bootmnt exit $?"',
                    'findmnt -R /run/archiso; findmnt /run/hop',
                    'ls -l /run/archiso/bootmnt/arch/x86_64/',
                    'lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS',
                    'free -m',
                    'systemctl is-active omarchy-root-image-verify.service omarchy-mirror-verify.service'):
        output, status = vm.sh(command)
        with open(os.path.join(OUT, 'live.txt'), 'a') as f:
            f.write(f'### {when}: {command} (exit {status})\n{output}\n\n')


def install(args):
    os.makedirs(OUT, exist_ok=True)
    vm = Vm(args.memory)
    started = time.time()
    try:
        found = vm.wait_serial(r'BdsDxe: (loading|starting) Boot\w+ "[^"]*"', 120)
        note('Firmware: ' + (found.group(0) if found else 'no BdsDxe line on the serial port'))
        # The live system takes a while. Typing at GRUB could stop it, so wait before asking for the shell.
        time.sleep(40)
        ready = False
        for _ in range(60):
            vm.serial.sendall(b'\necho "__$((40 + 2))__"\n')
            if vm.wait_serial(r'__42__', 5, max(0, len(vm.text) - 200)):
                ready = True
                break
        if not ready:
            vm.shot('no-shell')
            raise RuntimeError('No root shell on the serial port.')
        vm.sh('stty -echo; export PS1="" PS2=""')
        note(f'Live system up {time.time() - started:.0f} s after starting')
        live_checks(vm, 'at the start')
        drive(vm, args)
        install_checks(vm)
        vm.shot('before-reboot')
        mark = len(vm.text)
        vm.key('ret')
        note('Pressed Return on Reboot Now')
        found = vm.wait_serial(r'BdsDxe: (loading|starting) Boot\w+ "[^"]*"', 180, mark)
        note('Firmware after the install: ' + (found.group(0) if found else 'no BdsDxe line on the serial port'))
        end = time.time() + args.settle
        if args.encrypt:
            # Nothing reads the screen here, so the password goes in once, after the unlock prompt has had time to appear.
            time.sleep(60)
            vm.shot('unlock')
            vm.type(PASSWORD)
            vm.key('ret')
            note('Typed the password at the unlock prompt, 60 s after the firmware line')
        while time.time() < end and vm.alive():
            time.sleep(30)
            vm.shot('installed')
        vm.shot('installed-last')
        note(f'Waited {args.settle} s in the installed system, then asked it to turn off')
        try:
            vm.qmp('system_powerdown')
        except Exception as e:
            log(f'powerdown: {e}')
        for _ in range(90):
            if not vm.alive():
                break
            time.sleep(1)
        note('It turned itself off' if not vm.alive() else 'It did not turn off within 90 s, so QEMU was stopped')
    finally:
        if vm.alive():
            try:
                vm.qmp('quit')
            except Exception:
                vm.qemu.kill()
        vm.qemu.wait(30)
        print_vars('after')


def drive(vm, args):
    """Omarchy's real wizard, as the catalog's steps describe it."""
    with open(STATE) as f:
        full_disk = json.load(f).get('full_disk')
    done = set()
    deadline = time.time() + 1500
    last = ''
    while time.time() < deadline:
        screen = vm.screen()
        if screen != last:
            with open(os.path.join(OUT, 'screens.txt'), 'a') as f:
                f.write(f'===== {time.strftime("%H:%M:%S")}\n{screen}\n')
            last = screen
        lines = screen_lines(screen)
        joined = '\n'.join(lines)

        def act(name):
            if name in done:
                return False
            done.add(name)
            vm.shot(name)
            return True

        if 'installation stopped' in joined or 'Aborted' in joined or 'You can retry later' in joined:
            vm.shot('failed')
            raise RuntimeError('The installer stopped:\n' + joined)
        if 'Confirm overwriting' in joined and not full_disk:
            vm.shot('wrong-mode')
            raise RuntimeError('Reached Full disk install, which would erase the disk. Stopped without confirming.')
        if 'Confirm overwriting' in joined:
            if 'overwrite' not in done:
                done.add('overwrite')
                for line in lines:
                    if 'overwritten' in line or 'Confirm overwriting' in line:
                        note('Full disk screen: ' + line)
                vm.shot('overwrite')
            if not args.encrypt and 'without encryption' not in joined:
                vm.key('ctrl', 'c')
                time.sleep(3)
            elif act('install'):
                note('Chose: ' + ('Yes, install' if args.encrypt else 'Yes, install without encryption'))
                vm.key('ret')
            time.sleep(1.5)
            continue
        if 'Reboot Now' in joined and ('Installed Omarchy' in joined or 'Finished installing' in joined):
            for line in lines:
                if 'Installed Omarchy' in line:
                    note('Finished: ' + line)
            vm.shot('installed-screen')
            return
        if 'Press Return to Start Install' in joined and act('greeter'):
            vm.key('ret')
        elif 'Select keyboard layout' in joined and act('keyboard'):
            vm.key('ret')
        elif re.search(r'(?m)^Language$', joined) and act('language'):
            vm.key('ret')
        elif re.search(r'(?m)^Timezone', joined) and act('timezone'):
            vm.key('ret')
        elif 'Username>' in joined and act('username'):
            vm.type(USER)
            vm.key('ret')
        elif 'Password>' in joined and act('password'):
            vm.type(PASSWORD)
            vm.key('ret')
        elif 'Confirm>' in joined and act('confirm-password'):
            vm.type(PASSWORD)
            vm.key('ret')
        elif 'Full name>' in joined and act('name'):
            vm.key('ret')
        elif 'Email address>' in joined and act('email'):
            vm.key('ret')
        elif 'Hostname>' in joined and act('hostname'):
            vm.key('ret')
        elif 'Does this look right?' in joined and act('summary'):
            vm.key('ret')
        elif 'Select install disk' in joined and act('disk'):
            choose(vm, '/dev/nvme0n1', 'Select install disk')
        elif 'Select installation mode' in joined and act('mode'):
            for line in lines:
                if 'install' in line.lower() or 'disk' in line.lower():
                    note('Mode screen: ' + line)
            choose(vm, 'Full disk install' if full_disk else 'Free space install', 'Select installation mode')
        elif 'Install Omarchy in the' in joined and 'Confirm installing on' in joined:
            if 'free-space' not in done:
                done.add('free-space')
                for line in lines:
                    if 'Install Omarchy in the' in line or 'Confirm installing on' in line:
                        note('Free space screen: ' + line)
                vm.shot('free-space')
            if not args.encrypt and 'without encryption' not in joined:
                vm.key('ctrl', 'c')
                time.sleep(3)
            elif act('install'):
                note('Chose: ' + ('Yes, install' if args.encrypt else 'Yes, install without encryption'))
                vm.key('ret')
        time.sleep(1.5)
    vm.shot('timeout')
    raise RuntimeError('The installer did not finish in time.')


def install_checks(vm):
    note('--- live system, after the install')
    for command in ('grep -E "root image|off the install medium|F1\\.|Installed|limine|Limine" /var/log/omarchy-install.log | tail -n 40',
                    'tail -n 30 /var/log/omarchy-install.log',
                    'parted -ms /dev/nvme0n1 unit MiB print',
                    'lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS',
                    'efibootmgr -v',
                    'findmnt -R /run/archiso; findmnt /run/hop',
                    'free -m'):
        output, status = vm.sh(command, timeout=120)
        with open(os.path.join(OUT, 'live.txt'), 'a') as f:
            f.write(f'### after: {command} (exit {status})\n{output}\n\n')
        if command.startswith('grep') or command.startswith('parted') or command.startswith('efibootmgr'):
            for line in output.splitlines()[-25:]:
                note('  ' + line)


# --- What changed --------------------------------------------------------------------

def check(args):
    with open(STATE) as f:
        state = json.load(f)
    failures = []
    full_disk = state.get('full_disk')
    layout = run('sgdisk', '-p', DISK, capture=True)
    with open(os.path.join(OUT, 'layout-after.txt'), 'w') as f:
        f.write(layout)
    note('--- the disk afterwards\n' + layout)
    loop = attach(read_only=True)
    try:
        after = partition_hashes(loop)
        for name, digest in state['partitions'].items():
            same = after[name] == digest
            note(f'{name}: {"byte for byte the same" if same else ("gone, as replacing Windows means" if full_disk else "CHANGED")}')
            if not same and not full_disk:
                failures.append(name)
        esp_after = tree_hashes_mounted(loop)
        for path, digest in sorted(state['esp'].items()):
            same = esp_after.get(path) == digest
            note(f'EFI partition {path}: {"unchanged" if same else "CHANGED or gone"}')
            if not same and not full_disk:
                failures.append(path)
        for path in sorted(set(esp_after) - set(state['esp'])):
            note(f'EFI partition {path}: new')
        blkid = run('blkid', check=False, capture=True)
        note('blkid:\n' + blkid)
        # 4.5 keeps the root image's own label, so it's found by the partition's name.
        root = next((line.split(':')[0] for line in blkid.splitlines() if loop in line and 'PARTLABEL="OMARCHY_ROOT"' in line and 'TYPE="btrfs"' in line), None)
        crypt = next((line.split(':')[0] for line in blkid.splitlines() if loop in line and 'PARTLABEL="OMARCHY_ROOT"' in line and 'TYPE="crypto_LUKS"' in line), None)
        if crypt and not root:
            subprocess.run(['cryptsetup', 'open', '--readonly', crypt, 'ovmroot', '-'], input=PASSWORD.encode(), check=True)
            root = '/dev/mapper/ovmroot'
        efi = next((line.split(':')[0] for line in blkid.splitlines() if loop in line and 'LABEL="OMARCHY_EFI"' in line), None)
        if not root:
            failures.append('no Omarchy root')
            note('No Omarchy root partition found.')
        else:
            logs = mount(root, os.path.join(WORK, 'chk-log'), '-o', 'ro,subvol=@log')
            system = mount(root, os.path.join(WORK, 'chk-root'), '-o', 'ro,subvol=@')
            try:
                journal = os.path.join(logs, 'journal')
                boots = run('journalctl', '-D', journal, '--list-boots', '--no-pager', check=False, capture=True)
                note('Installed system boots:\n' + boots)
                text = run('journalctl', '-D', journal, '-b', '0', '--no-pager', '-o', 'short-monotonic', check=False, capture=True)
                with open(os.path.join(OUT, 'installed-journal.txt'), 'w') as f:
                    f.write(text)
                picked = [line for line in text.splitlines() if re.search(
                    r'Command line|Reached target|Startup finished|sddm|uwsm|Hyprland|hyprland|session opened|Welcome to|Linux version', line)]
                for line in picked[:60]:
                    note('  ' + line)
                if not re.search(r'Reached target .*[Gg]raphical', text):
                    failures.append('no graphical target in the installed system\'s journal')
                cmdline = re.search(r'Command line: (.*)', text)
                if cmdline and re.search(r'systemd\.run|archisolabel|debug_shell', cmdline.group(1)):
                    failures.append('hop\'s or the test\'s arguments reached the installed system')
                with open(os.path.join(system, 'etc/os-release')) as f:
                    note('os-release: ' + ' '.join(f.read().split()))
            finally:
                run('umount', logs, check=False)
                run('umount', system, check=False)
            if root == '/dev/mapper/ovmroot':
                run('cryptsetup', 'close', 'ovmroot', check=False)
        if efi:
            folder = mount(efi, os.path.join(WORK, 'chk-efi'), '-o', 'ro')
            try:
                note('Omarchy\'s EFI partition: ' + ', '.join(sorted(tree_hashes(folder))))
                for name in ('limine.conf', 'EFI/limine/limine.conf', 'boot/limine.conf'):
                    path = os.path.join(folder, name)
                    if os.path.exists(path):
                        with open(path) as f:
                            for line in f:
                                if 'cmdline' in line.lower():
                                    note(f'{name}: {line.strip()}')
            finally:
                run('umount', folder, check=False)
    finally:
        run('losetup', '-d', loop, check=False)
    entries = print_vars('after')
    for line in entries.splitlines():
        if re.search(r'Boot[0-9A-F]{4}|BootOrder|BootNext', line):
            note('NVRAM ' + line.strip())
    note('RESULT: ' + ('pass' if not failures else 'FAIL ' + '; '.join(failures)))
    sys.exit(1 if failures else 0)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('prepare')
    p.add_argument('--iso', required=True)
    p.add_argument('--full-disk', action='store_true', help='set it up for replacing Windows, and choose Full disk install')
    p = sub.add_parser('install')
    p.add_argument('--memory', type=int, default=8)
    p.add_argument('--encrypt', action='store_true')
    p.add_argument('--settle', type=int, default=420, help='seconds to leave the installed system running')
    sub.add_parser('check')
    args = parser.parse_args()
    os.makedirs(OUT, exist_ok=True)
    {'prepare': prepare, 'install': install, 'check': check}[args.command](args)


if __name__ == '__main__':
    main()
