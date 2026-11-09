#!/usr/bin/env python3
"""Starts hop's shrink image in QEMU with OVMF, Secure Boot on with Microsoft's keys, as a PC would: through a startup
entry for \\EFI\\hop-shrink\\shimx64.efi and BootNext, with the engine's own grub.cfg. The disk is laid out as Windows
lays one out, on NVMe, with files near the end of C: that only a move gets out of the way. Then checks what changed.

    boot.py IMAGE_FOLDER [--secure-boot/--no-secure-boot]

Needs root, qemu-system-x86, ovmf, gdisk, dosfstools, ntfs-3g, pwsh and virt-firmware.
"""
import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get('SHRINK_WORK', '/mnt/shrink')
OUT = os.path.join(WORK, 'out')
DISK = os.path.join(WORK, 'disk.img')
VARS = os.path.join(WORK, 'vars.fd')
DISK_GB = 12
NEW_GB = 6   # what C: shrinks to
SECTOR = 512
FAILS = []


def log(text):
    print(text, flush=True)
    with open(os.path.join(OUT, 'report.txt'), 'a') as f:
        f.write(text + '\n')


def check(name, ok, detail=''):
    log(f'{"PASS" if ok else "FAIL"} {name}{(" " + detail) if detail and not ok else ""}')
    if not ok:
        FAILS.append(name)


def run(*argv, check_=True, capture=False):
    result = subprocess.run([str(a) for a in argv], check=check_, text=True,
                            stdout=subprocess.PIPE if capture else None, stderr=subprocess.STDOUT if capture else None)
    return result.stdout if capture else result.returncode


def attach():
    loop = run('losetup', '-P', '--show', '-f', DISK, capture=True).strip()
    run('udevadm', 'settle')
    for _ in range(50):
        if os.path.exists(loop + 'p3'):
            break
        time.sleep(0.2)
    return loop


def mount(device, folder, *options):
    os.makedirs(folder, exist_ok=True)
    run('mount', *options, device, folder)
    return folder


def tree(root):
    found = {}
    for folder, _, files in os.walk(root):
        for name in files:
            path = os.path.join(folder, name)
            h = hashlib.sha256()
            with open(path, 'rb') as f:
                for chunk in iter(lambda: f.read(1 << 20), b''):
                    h.update(chunk)
            found[os.path.relpath(path, root)] = h.hexdigest()
    return found


def gpt(number):
    text = run('sgdisk', '-i', number, DISK, capture=True)
    get = lambda key: next(line.split(':', 1)[1].strip() for line in text.splitlines() if line.startswith(key))
    first, last = int(get('First sector').split()[0]), int(get('Last sector').split()[0])
    return {'first': first, 'size': last - first + 1, 'guid': get('Partition unique GUID'), 'text': text}


def load_option_path(number, first, size, guid, path):
    """The device path hop's Firmware.CreateBootEntry writes: hard drive node, file path node, end."""
    hd = struct.pack('<BBHIQQ', 0x04, 0x01, 42, number, first, size) + uuid.UUID(guid).bytes_le + bytes([0x02, 0x02])
    name = (path + '\0').encode('utf-16-le')
    return hd + struct.pack('<BBH', 0x04, 0x04, 4 + len(name)) + name + bytes([0x7F, 0xFF, 0x04, 0x00])


def write_vars(source, esp):
    from virt.firmware.varstore import autodetect
    from virt.firmware.efi import devpath
    shutil.copyfile(source, VARS)
    store = autodetect.open_varstore(VARS)
    variables = store.get_varlist()
    # Windows first, as on a PC, which this firmware can't start; hop's entry only through BootNext.
    variables.set_boot_entry(0x0000, 'Windows Boot Manager', devpath.DevicePath(load_option_path(1, esp['first'], esp['size'], esp['guid'], r'\EFI\Microsoft\Boot\bootmgfw.efi')))
    variables.append_boot_order(0x0000)
    variables.set_boot_entry(0x0043, 'hop: make room (hop)', devpath.DevicePath(load_option_path(1, esp['first'], esp['size'], esp['guid'], r'\EFI\hop-shrink\shimx64.efi')))
    variables.set_boot_next(0x0043)
    store.write_varstore(VARS, variables)


def make_disk(image):
    if os.path.exists(DISK):
        os.unlink(DISK)
    with open(DISK, 'wb') as f:
        f.truncate(DISK_GB << 30)
    run('sgdisk', '-o', '-n', '1:2048:+260M', '-t', '1:ef00', '-c', '1:EFI system partition',
        '-n', '2:0:+16M', '-t', '2:0c01', '-c', '2:Microsoft reserved partition',
        '-n', '3:0:-700M', '-t', '3:0700', '-c', '3:Basic data partition',
        '-n', '4:0:0', '-t', '4:2700', '-c', '4:Basic data partition', '-A', '4:set:0', DISK)
    loop = attach()
    try:
        run('mkfs.fat', '-F', '32', f'{loop}p1')
        run('mkntfs', '-Q', '-L', 'Windows', f'{loop}p3')
        run('mkntfs', '-Q', '-L', 'Recovery', f'{loop}p4')
        # ntfs-3g, which fills a drive in order: the kernel's ntfs3 can put the files meant for the end anywhere.
        c = os.path.join(WORK, 'c')
        os.makedirs(c, exist_ok=True)
        run('ntfs-3g', f'{loop}p3', c)
        os.makedirs(os.path.join(c, 'Windows/System32'))
        os.makedirs(os.path.join(c, 'Users/hop/Documents'))
        with open(os.path.join(c, 'Windows/System32/stand-in.bin'), 'wb') as f:
            f.write(os.urandom(300 << 20))
        stat = os.statvfs(c)
        placeholder = os.path.join(c, 'placeholder.bin')
        # Written out, since ntfs3 can leave a fallocated file's clusters unallocated. And it leaves free more than NTFS's
        # reserved zone near the start, 12.5% of the drive, which a nearly full drive's new files would go into instead.
        keep = stat.f_blocks * stat.f_frsize * 15 // 100 + (900 << 20)
        run('dd', 'if=/dev/zero', f'of={placeholder}', 'bs=16M', f'count={(stat.f_bavail * stat.f_frsize - keep) >> 24}', 'status=none')
        for i in range(6):
            with open(os.path.join(c, f'Users/hop/Documents/late-{i}.bin'), 'wb') as f:
                f.write(os.urandom(100 << 20))
        os.unlink(placeholder)
        for i in range(3000):
            with open(os.path.join(c, f'Users/hop/Documents/small-{i}.txt'), 'w') as f:
                f.write(f'contents {i}\n')
        files = tree(c)
        run('umount', c)
        info = run('ntfsresize', '--info', '--force', '--no-action', f'{loop}p3', capture=True)
        log('Before: ' + ' | '.join(line for line in info.splitlines() if 'resize at' in line or 'volume size' in line))
        esp = mount(f'{loop}p1', os.path.join(WORK, 'esp'))
        folder = os.path.join(esp, 'EFI/hop-shrink')
        os.makedirs(folder)
        for name in ('shimx64.efi', 'grubx64.efi', 'vmlinuz', 'initrd.img'):
            shutil.copyfile(os.path.join(image, name), os.path.join(folder, name))
        os.makedirs(os.path.join(esp, 'EFI/Microsoft/Boot'))
        with open(os.path.join(esp, 'EFI/Microsoft/Boot/bootmgfw.efi'), 'wb') as f:
            f.write(os.urandom(1 << 20))
        sizes = {'C:': int(run('blockdev', '--getsize64', f'{loop}p3', capture=True))}
        run('umount', esp)
        hashes = {n: run('sha256sum', f'{loop}p{n}', capture=True).split()[0] for n in (2, 4)}
    finally:
        run('losetup', '-d', loop, check_=False)
    return files, sizes['C:'], hashes


def grub_cfg(c, esp, was, new):
    """The engine's own menu, with the serial console added for this test."""
    script = (f". '{HERE}/../../engine/Common.ps1'; . '{HERE}/../../engine/Shrink.ps1'; "
              f"(Get-ShrinkGrubConfig '{c['guid']}' {was} {new} '{esp['guid']}' 'test-1' 'console=ttyS0,115200') -join \"`n\"")
    env = dict(os.environ, HOP_TEST='1')
    return subprocess.run(['pwsh', '-NoProfile', '-Command', '$Sync = @{ Log = [Collections.ArrayList]@() }; ' + script],
                          check=True, text=True, capture_output=True, env=env).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image')
    parser.add_argument('--no-secure-boot', action='store_true')
    args = parser.parse_args()
    os.makedirs(OUT, exist_ok=True)
    secure = not args.no_secure_boot
    files, was, hashes = make_disk(args.image)
    new = NEW_GB << 30
    before = {n: gpt(n) for n in (1, 3)}
    menu = grub_cfg(before[3], before[1], was, new)
    log('grub.cfg:\n' + menu)
    loop = attach()
    try:
        esp = mount(f'{loop}p1', os.path.join(WORK, 'esp'))
        with open(os.path.join(esp, 'EFI/hop-shrink/grub.cfg'), 'w') as f:
            f.write(menu + '\n')
        run('umount', esp)
    finally:
        run('losetup', '-d', loop, check_=False)
    code = '/usr/share/OVMF/OVMF_CODE_4M.secboot.fd' if secure else '/usr/share/OVMF/OVMF_CODE_4M.fd'
    write_vars('/usr/share/OVMF/OVMF_VARS_4M.ms.fd' if secure else '/usr/share/OVMF/OVMF_VARS_4M.fd', before[1])
    serial = os.path.join(OUT, 'serial.txt')
    started = time.time()
    # Secure Boot's firmware needs SMM. The other one keeps its variables only without it.
    machine = ['-machine', 'q35,smm=on', '-global', 'driver=cfi.pflash01,property=secure,value=on'] if secure else ['-machine', 'q35']
    qemu = subprocess.Popen([
        'qemu-system-x86_64', '-enable-kvm', '-m', '2048', '-smp', '2', '-no-reboot', *machine,
        '-drive', f'if=pflash,format=raw,readonly=on,file={code}', '-drive', f'if=pflash,format=raw,file={VARS}',
        '-drive', f'file={DISK},if=none,id=os,format=raw,cache=unsafe', '-device', 'nvme,drive=os,serial=hop',
        '-display', 'none', '-serial', f'file:{serial}'])
    try:
        qemu.wait(timeout=900)
    except subprocess.TimeoutExpired:
        qemu.kill()
        check('restarts by itself within 15 minutes', False)
    log(f'QEMU ran {time.time() - started:.0f} s')
    with open(serial, errors='replace') as f:
        text = f.read()
    log('--- serial, hop lines\n' + '\n'.join(line for line in text.splitlines() if 'hop' in line or 'Secure' in line or 'ntfsresize' in line.lower())[-6000:])

    loop = attach()
    try:
        esp = mount(f'{loop}p1', os.path.join(WORK, 'esp'), '-o', 'ro')
        result_path = os.path.join(esp, 'EFI/hop-shrink/result.txt')
        result = open(result_path).read() if os.path.exists(result_path) else ''
        run('umount', esp)
        log('--- result.txt\n' + result)
        lines = result.splitlines()
        check('wrote its result for this attempt', len(lines) > 1 and lines[0] == 'id test-1')
        check('says it shrank C:', len(lines) > 1 and lines[1].startswith('ok '), lines[1] if len(lines) > 1 else '')
        moved = [line for line in lines if line.startswith('Needed relocations')]
        check('had to move files out of the way to do it', bool(moved) and not moved[-1].startswith('Needed relocations : 0 '), ' | '.join(moved))
        check(f'started with Secure Boot {"on" if secure else "off"}', f'Secure Boot {1 if secure else 0}' in result)
        size = int(run('blockdev', '--getsize64', f'{loop}p3', capture=True))
        check(f'C: is {NEW_GB} GiB now', size == new, str(size))
        after = gpt(3)
        same = lambda t: [line for line in t.splitlines() if not line.startswith(('Last sector', 'Partition size'))]
        check('C: keeps its start, type, ID, name and attributes', same(after['text']) == same(before[3]['text']))
        check('the GPT checks out', 'No problems found' in run('sgdisk', '-v', DISK, capture=True))
        for n in (2, 4):
            check(f'partition {n} is untouched', run('sha256sum', f'{loop}p{n}', capture=True).split()[0] == hashes[n])
        check('ntfsfix finds nothing to fix', run('ntfsfix', '--no-action', f'{loop}p3', check_=False) == 0)
        # ntfsresize refuses a drive marked for a check, so its dry run says whether the mark went.
        check("isn't left marked for a disk check", run('ntfsresize', '--no-action', '--no-progress-bar', '--size', str(new - (1 << 30)), f'{loop}p3', check_=False) == 0)
        c = mount(f'{loop}p3', os.path.join(WORK, 'c'), '-t', 'ntfs3', '-o', 'ro')
        now = tree(c)
        run('umount', c)
        changed = [p for p, h in files.items() if now.get(p) != h]
        check(f'every file on C: is the same ({len(files)} files)', not changed, ', '.join(changed[:10]))
    finally:
        run('losetup', '-d', loop, check_=False)
    log(f'{len(FAILS)} failed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
