# Testing

## What CI covers

Every pull request builds the exe, checks the scripts parse, lints them and runs the unit tests in
`tests/`. Those cover decisions: the space plan, status detection, what counts as Linux, the download
parsers, the startup entry's bytes. They mock the disk and firmware, so **they can't tell you hop
really boots**. A weekly job also checks every download in the catalog still resolves.

## Real partitions, without a real PC

`tests/Probe-VirtualDisks.ps1` runs the real engine on real partitions on virtual disks: shrinking, making
partitions, formatting, copying, undo, disk numbers changing, recovering with no state file, Make room. It
checks offsets and that files survive. It changes disks, so run it only on a disposable Windows machine, such
as a GitHub Actions runner, as administrator. It stands in for the firmware and the EFI partition, so **it
can't tell you anything about booting either.**

hop refuses virtual disks. The script checks that it does, then defines its own `Get-Disk` that reports its
disks as NVMe. The app has no way to do this.

`.github/workflows/probe.yml`, started by hand, runs that probe on a GitHub runner. Last run, November 2026: 143 passed, 0 failed, in 7 minutes.

`tests/Probe-SystemFiles.ps1` runs in CI. It puts `$Mft::$BITMAP` at the end of a real NTFS volume on a virtual disk, checks that stops a shrink, has hop move it, then shrinks the volume, runs Windows' disk check and reads every file back.

## Replacing Windows, in a virtual PC

What's offered depends on what really ran, so this is the record. On a GitHub Actions runner, in QEMU with OVMF,
on an 80 GB NVMe disk laid out as hop leaves one: EFI partition, an NTFS "C:", and FAT32 `HOPINSTALL` holding the
ISO's files, adapted by the engine's real `Update-BootConfig` and started through `Boot0042` and `BootNext` as hop
writes them. A second disk with random data was attached, and its checksum compared afterwards. The ISOs are the
October 2026 ones.

Each check is from the serial log or the disk image, not the job's result:

- **The disk is free:** nothing from the disk in `/proc/mounts` or `losetup`, and `blockdev --rereadpt` succeeds.
  Without the word, on Ubuntu, it fails with "Device or resource busy" and `/cdrom` is the installer partition.
- **It can be repartitioned:** a new table, `mkfs.ext4` on it, a 100 MB file read back, and the old table restored.
- **Erased and started again:** the installer run with its own unattended settings, a disk with only its new
  partitions afterwards, and the firmware then starting it with a line from inside the installed system.

| System | Offered | Disk free | Repartitioned | Erased and started again |
| --- | --- | --- | --- | --- |
| Ubuntu 26.04.1 | Yes | Yes | Yes | Yes, with its autoinstall, at 12 GB of memory and at 10 GB, which is its ISO plus hop's 4 GB. The second starts to a login, without the probe's message |
| Zorin OS 18.1 | Yes | Yes | By its installer | Yes, with Ubiquity's `noninteractive` mode and a preseed that erases the disk, so its screens weren't seen |
| Debian 13.7 | Yes | Yes | Yes | Yes, in its real installer's screens under a small X server, with keys pressed, its **Erase disk** preset and its users screen left out |
| Arch 2026.10.01 | Yes | Yes | Yes | Yes, with `archinstall --silent`, a config file that wipes the disk and the internet |
| elementary OS 8.1 | Yes | Yes | By its installer | Yes, by asking its installer's own service for `InstallWithDefaultDiskLayout`, which is what its erase choice calls, at 7.1 GB of memory, with Secure Boot on and BitLocker's signature on "C:". Its screens weren't seen. The firmware started `\EFI\ubuntu\shimx64.efi`, which said `elementary OS 8`, root on the new `data-root` volume, `secureboot=1`, and `dm=active` |
| Ultramarine 44 | Yes | Yes | By its installer | Yes, as Fedora, at 7.4 GB of memory and with Secure Boot on. The firmware started `\EFI\fedora\shimx64.efi`, and the system then stopped at its own first-start **Language** screen, `taidan-initial-setup.service`, so the probe's message didn't run |
| Omarchy 4.0.6 | Yes | Yes, as it starts, with `copytoram` added to hop's `umount -l` | By its installer | Yes, in its real wizard on `tty1` with keys pressed: **Full disk install**, at 10 GB of memory, with BitLocker's signature on "C:", which that mode doesn't check for. Once encrypted, with the password typed at its prompt, to its desktop, and once not, to its login screen, with `Reached target Graphical Interface`. Secure Boot off, as it needs. Run again with hop's menu as it is now, at 12 GB, in [41455950194](https://github.com/Arjun-Ingole/hop/actions/runs/41455950194) and 41457041976: `copytoram` let go of the disk, hop's first `mount` then found nothing and stopped the rest, as it should, and **Full disk install** erased the disk. The firmware then started `Limine`, and its journal has `Reached target Graphical Interface` and `VERSION_ID="4.0.6"` |
| Omarchy 4.5.0-rc3 | No | Not run | Not run | Not run. hop refuses it once the ISO is open: its menu has `copytoram=n` after hop's `copytoram`, which wins, and its installer reads its root image from the partition it would erase |
| Xubuntu, Ubuntu Budgie, Ubuntu Cinnamon, Edubuntu, Ubuntu Studio 26.04.1 | Yes | Yes | By its installer | Yes, as Ubuntu, with its autoinstall, each at its ISO plus 4 GB, with Secure Boot on and BitLocker's signature on "C:". Their screens weren't seen. The firmware started `\EFI\ubuntu\shimx64.efi`, each said root on the new partition, `secureboot=1` and `dm=active`, and a screenshot shows each one's login screen |
| Linux Mint 22.3, all three | No | Yes, and `blockdev --rereadpt` succeeded, with Secure Boot on | No | Not shown. Its `noninteractive` mode stopped at a question it can't ask, with `does not implement question_dialog`, and its graphical installer under a small X server waited at **Welcome** because the test pressed no keys. The disk was untouched |
| Pop!_OS 24.04 | No | Yes, once hop's edit found its `/casper_pop-os_...` folder | By `distinst` | Erased it with `distinst` and a table given by hand, but without `--modify-boot`, so the firmware found nothing to start: `No bootable option or device was found`. Not shown starting |
| Lubuntu 26.04.1, CachyOS | No | Yes | No | Not shown. They use Calamares, and the test stopped at its **Location** screen, so the disk was untouched |
| Ubuntu Unity 26.04 | No | Yes, with Secure Boot on | No | Not run. It uses Calamares, not the installer service Ubuntu's does |
| Fedora 44 | Yes | Yes, as it starts: `rd.live.ram=1` stays mounted, and hop's `umount -l` takes that away | By its installer | Yes, with Anaconda's `--cmdline` and a kickstart that clears the disk, at 6.7 GB of memory and with Secure Boot on. Its screens weren't seen. The firmware started `\EFI\fedora\shimx64.efi`, which said `Fedora Linux 44`, root on the new partition, `secureboot=1`. The kickstart left it at `multi-user.target`, so its desktop wasn't seen |

Ubuntu's ISO in a virtual PC with 7 GB of memory copied itself to memory and then hadn't reached a login after seven
minutes, which is why hop refuses it.

The installer's choices weren't clicked by a person. Unattended settings stand in for them, except on Debian and Omarchy,
and the words in the steps come from the installer's own strings or source. The installers were also shown fewer disks or
choices than a PC would give them. **No real PC has done this.** hop's screens for it have been seen on a real Windows, as below, but only up to the ERASE screen.

**Secure Boot and BitLocker:** Fedora, Ultramarine, elementary OS and the Ubuntu flavours above erased the disk and then
started with Secure Boot on, through their own `shimx64.efi`. Omarchy needs it off. The other runs before these left it off.
"C:" had BitLocker's signature in the runs that say so, and on Fedora and Ultramarine only the bytes hop and Omarchy read,
which `blkid` didn't call BitLocker. It's a signature and its metadata block, not a real encrypted volume, so nothing here
shows what an installer does with one that's really encrypted, or with a real Windows on the disk.

## Casper's partition, in a virtual PC

On a GitHub Actions runner, in QEMU with OVMF, on the same 80 GB NVMe disk: EFI partition, an NTFS "C:", FAT32
`HOPINSTALL`, then free space. `tests/Probe-VirtualDisks.ps1` covers telling it apart on real partitions, on Windows.

Before means the menu as it was, and after means with the engine's real `Update-BootConfig`. The results are from the
serial log and the disk image. `casper-helpers` is the same file in every ISO below, read from the ISO's initrd, and
each is casper 1.498, plus `+zorin2` on Zorin OS, where the manifest says.

| System | Before | After |
| --- | --- | --- |
| Ubuntu 26.04.1 | 71.9 GB ext4 `writable`, mounted on `/var/log` and `/var/crash` | Nothing new |
| Xubuntu, Edubuntu, Ubuntu Budgie, Cinnamon and Studio 26.04.1, Lubuntu 26.04.1, Ubuntu Unity 26.04 | The same, 70.9 to 73.9 GB | Nothing new |
| Zorin OS 18.1, Pop!_OS 24.04 | The same, 73.9 and 74.9 GB | Nothing new |
| Linux Mint 22.3 | The same, 74.9 GB, with Enter pressed at its menu | Nothing new |
| elementary OS 8.1 | A 74.9 GB partition with nothing on it: `mkfs.ext4` said its node did not exist yet | Nothing new |
| Debian 13.7 | Nothing. `live-boot` has no `mkfs` or `sfdisk` in its initrd | Not changed |
| Ubuntu 26.04.1, with a recovery partition ending the disk | Nothing | Not run |
| Ubuntu 26.04.1, with a recovery partition then 2 GB free | 2 GB `writable` in that | Nothing new |

**The installer really can't use the space.** On Ubuntu with `writable` there, an autoinstall with `layout: {name: direct, mode:
use_gap}` chose the 1 MiB left and failed with `No space left on device`.

**With the fix, the same autoinstall finished, with Secure Boot on.** It made a 71.9 GB ext4 partition straight after
`HOPINSTALL`, reused the EFI partition, and the NTFS and `HOPINSTALL` partitions came through byte for byte, after the
install and after the restart. The kernel's line had `nopersistent` in the live system, and not in the installed one.

**It starts.** With Secure Boot on and the 100 MB EFI partition, the installer finished its unattended upgrades and late
commands and restarted itself. The firmware then started Ubuntu's `shimx64.efi`. A marker the installed system wrote to its
own disk says `SecureBoot enabled`, root on the new partition, `/boot/efi` on Windows' EFI partition, and `gdm active` with
the greeter's session open. A screenshot shows the login screen. Nobody logged in, so the desktop itself wasn't seen.

Four installs cut short during their unattended upgrades by the test's limit also got as far as `gdm`: free space with
Secure Boot on, with it off, on with a 1 GB EFI partition, and an erase with it on.

**One earlier run stalled and hasn't been explained.** It also finished the whole install, with Secure Boot on, and then both
consoles stopped at `Starting initrd-switch-root.service`, with no `Welcome to Ubuntu`, until its limit of 360 seconds. It
didn't happen again. That run started the installed system with `console=ttyS0,115200 console=tty0 splash`, and the run
above without them, so that exact setup hasn't been repeated.

## Omarchy, in a virtual PC

### 4.5.0-rc3, and 4.0.6 again

`.github/workflows/omarchy-vm.yml` runs `tools/vm/omarchy/omarchyvm.py` on a GitHub Actions runner when a `probe/omarchy` branch is pushed.
In QEMU with OVMF and KVM, on an 80 GB NVMe disk: a 100 MB EFI partition with stand-ins for Windows' files, a 28 GB NTFS "C:", then
`HOPINSTALL` and `HOPLIVE` sized by the engine's own `Get-InstallerGB` and `Get-LiveGB` and filled as `Copy-Installer` and `Copy-LiveFiles`
fill them, then 40.9 GB free. The engine's real `Update-BootConfig` and `Copy-EspLoader` ran under pwsh. The firmware started `Boot0042`
through `BootNext`, written as hop writes them, with a stand-in "Windows Boot Manager" first in `BootOrder`. The test then adds
`systemd.debug_shell=ttyS0` to the live system's menu, after hop's edits, for a root shell on the serial port. Through it, a script read
the real wizard on `tty1` from `/dev/vcsu1` and pressed keys in QEMU, choosing the disk, **Free space install** and the rest as the steps
say. It's each ISO by its checksum. **Green proves nothing by itself: read `report.txt` and look at the screens.**

| ISO | Partitions | Encrypted | Memory | Installed in, by its own count | First start |
| --- | --- | --- | --- | --- | --- |
| 4.5.0-rc3 | 4 GB `HOPINSTALL`, 7 GB `HOPLIVE` with the 2.3 GB live image and the 3.9 GB root image | No | 8 GB | 29, 24 and 33 seconds | Login screen, `Reached target Graphical Interface` |
| 4.5.0-rc3 | The same | Yes, with the password typed at its prompt | 8 GB | 32, 26 and 25 seconds | Omarchy's desktop, which logs in by itself after that password, `session opened for user hop` |
| 4.5.0-rc3 | The same | No | 4 GB | 27, 21 and 22 seconds | Login screen, `Reached target Graphical Interface` |
| 4.0.6 | 4 GB `HOPINSTALL`, 7 GB `HOPLIVE` | No | 8 GB | 2 minutes 5 seconds, 2 minutes 3 and 1 minute 43 | Login screen, `Reached target Graphical Interface` |

Each ran three times, with the same results. In all twelve, with hop's menu as it is now:

- **The disk was offered.** The service hop's arguments make ran its five commands and finished. `findmnt` found nothing at
  `/run/archiso/bootmnt`, and `HOPLIVE` was at `/run/archiso/bootmnt/arch`. The disk list said
  `/dev/nvme0n1 (  80G) - QEMU NVMe Ctrl [vfat, ntfs, vfat, exfat(/run/archiso/bootmnt/arch)]`, and its screen said
  `Install Omarchy in the 40.9GB of free space.`
- **4.5 found its image there.** Its log said `writing root image (3743 MiB from /run/archiso/bootmnt/arch/x86_64/omarchy-root.img.zst)`,
  and its two checks of the medium were `active` before the install.
- **It started from the disk.** After **Reboot Now**, the firmware said `BdsDxe: loading Boot0008 "Limine"`, from Omarchy's own new 2 GB EFI
  partition, which `BootOrder` had first. The installed system's journal shows the rest, with `VERSION_ID="4.5.0rc3"` or `"4.0.6"`, and its
  kernel's line had none of hop's or the test's words.
- **Nothing else changed.** The NTFS, `HOPINSTALL` and `HOPLIVE` partitions were byte for byte the same after the restart. Windows' EFI files
  and `\EFI\hop` were unchanged, and nothing new was on that partition.

Each check is from the serial log, the disk image or the installed system's journal, not the job's result. The runs are
[41448482545](https://github.com/Arjun-Ingole/hop/actions/runs/41448482545),
[41450898216](https://github.com/Arjun-Ingole/hop/actions/runs/41450898216) and, on the final code with replacing Windows too,
[41457041976](https://github.com/Arjun-Ingole/hop/actions/runs/41457041976). An earlier one,
[41446241418](https://github.com/Arjun-Ingole/hop/actions/runs/41446241418), installed 4.5.0-rc3 unencrypted and 4.0.6 the same way.

**What hop's first try showed:** with `systemd.run=/bin/sh -c '...'`, GRUB passed the quotes on as `\'`, the shell stopped at
`unexpected EOF`, the disk stayed behind `/run/archiso/bootmnt`, and the disk list was empty: `no options provided`. So each command has its
own `systemd.run=`.

**What these runs missed at first:** `Read-Iso` needs Windows, so the test didn't run it, and it would have refused 4.5.0-rc3. Its menu
names the kernel as `vmlinuz-${live_kernel}`, which `Get-IsoKernelPath` took for a file that isn't there. It now fills in what the menu
sets first, and the test runs that check with the engine's own code: in
[41453842850](https://github.com/Arjun-Ingole/hop/actions/runs/41453842850) and 41457041976 it found `arch/boot/x86_64/vmlinuz-linux-omarchy`. The rest of `Read-Iso` is covered by unit tests with a menu like the real one.

**What this doesn't show:** 4.5.0-rc3 is a release candidate, and the final 4.5 hasn't been tried, so hop refuses it until it has. Replacing
Windows and a second disk weren't tried with 4.5, and hop refuses both for it. The test's root shell is the one thing in the live system hop
doesn't put there. The power button didn't turn the installed system off, so the test stopped it after seven minutes. A screenshot of the
encrypted run's desktop six minutes later was black, and what turned the screen off wasn't checked. Otherwise the same as below:
`HOPLIVE` made by `mkfs.exfat`, no real Windows, no `limine-scan`, Secure Boot off, and hop's own screens and Undo not run.

### 4.0.6, October 2026

The harness for these runs was lost. On a GitHub Actions runner, in QEMU with OVMF, on an 80 GB NVMe disk: a 100 MB EFI partition, an NTFS "C:", 1 GB FAT32 `HOPINSTALL`, 8 GB `HOPLIVE`, then
free space. The menu went through the engine's `Update-BootConfig`, and started through `Boot0042` and `BootNext` as hop writes them. It's the
real 4.0.6 ISO, by its checksum, and its real wizard on `tty1`: a script pressed keys and read `/dev/vcs1` back over the serial port. It chose the disk,
**Free space install** and the rest, as the steps say. hop's menu then only had `umount -l`.

| Second partition | Letting go of the disk | Encrypted | Memory | Installed in | First start |
| --- | --- | --- | --- | --- | --- |
| exFAT | `umount -l` | No | 8 GB | About 2 minutes | Login screen, `Reached target Graphical Interface` |
| exFAT | `copytoram` | Yes, with the password typed at its prompt | 12 GB | About 2 minutes | Omarchy's desktop, which logs in by itself after that password |
| NTFS | `copytoram` | No | 12 GB | About 2 minutes | Login screen, `Reached target Graphical Interface` |
| exFAT, 7 GB, with a 4 GB `HOPINSTALL`, using the catalog's real entry | `umount -l` | Yes, with the password typed at its prompt | 8 GB | About 2.5 minutes | Omarchy's desktop, `Reached target Graphical Interface` |

In all four, the NTFS, `HOPINSTALL` and `HOPLIVE` partitions came through byte for byte, after the install and after the restart, and
Windows' EFI files were unchanged. Each check is from the disk image or the installed system's journal, not the job's result.

**What this doesn't show:** `HOPLIVE` was made by `mkfs.exfat`, not Windows. `tests/Probe-VirtualDisks.ps1` shows that Windows makes it and copies to it, but
no Linux has mounted one made by Windows. There's no real Windows here, so `limine-scan` wasn't run, and neither was Windows started afterwards. BitLocker's refusal is
only tested by unit tests, and Secure Boot wasn't turned on. hop's own screens and Undo after this install haven't been run either.

## A second disk, in a virtual PC

On a GitHub Actions runner, in QEMU with OVMF. The first NVMe disk is Windows': 40 GB, with an EFI partition of 100 MB, a reserved partition, an NTFS "C:" and a recovery
partition. The second is an empty 200 GB GPT disk, which hop's real `Get-Plan` laid out with 60 GB for Linux, as it does: free space, `HOPINSTALL`, `HOPLIVE` if there is one, then the 60 GB.
That leaves more free before the installer than after it, which matters below. The menu went through the engine's `Update-BootConfig` and `Copy-EspLoader`, and started through `Boot0042` and `BootNext` as hop writes them, on Windows' EFI partition, with a fake
"Windows Boot Manager" first in `BootOrder`. Each result is from the serial log, the installer's screens or the disk images, not the job's result.

| System | Driven by | Went where | EFI partition | Started from disk | Windows' EFI files, and the partitions |
| --- | --- | --- | --- | --- | --- |
| Omarchy 4.0.6 | Its real wizard on `tty1`, with keys pressed, as the steps say, without encryption | **The 129 GB before the installer**, the largest free space, not hop's 60 GB. Its screen said `Install Omarchy in the 129.0GB of free space` | Its own new 2 GB one, on the second disk | Yes: `Boot0009 "Limine"` from the second disk first in `BootOrder`, then the login screen in its journal and a screenshot | Unchanged. MSR, C:, recovery, `HOPINSTALL` and `HOPLIVE` byte for byte, after the install and the restart |
| Fedora 44 | Anaconda's `--cmdline` mode with a kickstart: `ignoredisk --only-use=nvme1n1`, `clearpart --none`, `autopart`. Its graphical screens weren't seen | The 133 GB before the installer, not hop's 60 GB | Its own new 600 MB one, on the second disk, with a 2 GB `/boot` | Yes: `Boot000A "Fedora Linux"` from the second disk first in `BootOrder`, root on the second disk, and `Windows Boot Manager (on /dev/nvme0n1p1)` in its menu. The kickstart left it at `multi-user.target`, so it stopped at a text login and its desktop wasn't seen | Unchanged. MSR, C:, recovery and `HOPINSTALL` byte for byte, after both |
| Ultramarine 44 | The same | The same, 133 GB | The same | Yes: `Boot000A "Ultramarine Linux"`, and a screenshot of its own setup at **Language**, which waits there, so the test's marker never ran. Its menu wasn't read | The same |
| Arch 2026.10.01 | `archinstall --silent` with a `manual_partitioning` config that says what its screens would. Its real screens were read as far as **Select disks for the installation**, where Space marked both disks | hop's 60 GB, as ext4 | **Windows'**, unformatted, at `/boot/efi`. GRUB's files add about 18 MB there | Yes: `Boot000A "GRUB"` from Windows' EFI partition first in `BootOrder`, root on the second disk, `Windows Boot Manager` next | Unchanged. MSR, C: and recovery byte for byte. `HOPINSTALL` isn't: see below |
| Debian 13.7, CachyOS | Not finished. A script read their real Calamares screens and clicked, but it chose the wrong disk or field, and nothing was installed | | | No | Still refused on a second disk |

**`HOPINSTALL` changes when Arch starts.** Its copied `systemd-boot` adds a 32-byte `loader/random-seed`. In three runs, on either disk, that was the only file that differed, and 86 bytes in six sectors of the partition. Nothing else writes to it, and nothing reads it after the install.

**What this doesn't show:** no real PC, so nothing about how a real firmware treats a second disk, or Fast Boot. Windows was never started: its files are stand-ins that only show whether they changed.
Nobody clicked anything, and hop's own screens and Undo weren't run.

## Next to Windows, in free space, in a virtual PC

The same, with one 130 GB disk: EFI partition, reserved partition, C:, `HOPINSTALL`, 60 GB free, recovery partition, as `Get-Plan` lays them out.

| System | Driven by | Went where | Started from disk | Windows' EFI files, and the partitions |
| --- | --- | --- | --- | --- |
| Arch 2026.10.01 | The same config, as `archinstall --silent` | hop's 60 GB, as ext4, with `/boot/efi` on the existing EFI partition | Yes: `Boot0009 "GRUB"` first in `BootOrder`, root on the new partition, `Windows Boot Manager` next | Unchanged. MSR, C: and recovery byte for byte, and `HOPINSTALL` apart from `loader/random-seed` |
| Zorin OS 18.1, Linux Mint 22.3 | Ubiquity's real screens under a small X server, and on Zorin OS its `noninteractive` mode | **Nothing installed.** See below | No | Unchanged, but nothing tried to change them |
| Debian 13.7, CachyOS | Their real Calamares screens, clicked as the steps say. See [Debian and CachyOS next to Windows](#debian-and-cachyos-next-to-windows-in-a-virtual-pc) | hop's 40 GB, as ext4, with `/boot/efi` on the existing EFI partition | Yes | Windows' own files unchanged. MSR, C:, recovery and `HOPINSTALL` byte for byte |

**So hop's own partition is how these go next to Windows: see the next section. They're refused on a second disk.** Started from the disk it's installing to, Ubiquity's `Installation type` goes straight to its manual screen, with no option to install alongside Windows, and says: `Your installation medium is on /dev/nvme0n1p5. You will not be able to create, delete, or resize partitions on this disk, but you may be able to install to existing partitions there.` hop's steps asked for that option, then **+**, which is greyed out on Linux Mint. `noninteractive` mode stopped at `No root file system is defined`. Replacing Windows with Zorin OS isn't affected: that run copies it to memory first.

Two routes got further, and neither was run to the end. The test's script stopped each run, on a **Continue** it clicked wrongly or couldn't find:

| Route | System | Seen | Not seen |
| --- | --- | --- | --- |
| Copying to memory (`toram`) | Zorin OS, Linux Mint Cinnamon | `/cdrom` on `/dev/shm`, the first screen back with `Install Zorin OS alongside Windows Boot Manager` and `Install Linux Mint alongside Windows Boot Manager`, the question before writing naming `partition #6 of /dev/nvme0n1 as ext4`, then `Who are you?`. An ext4 partition was on the disk afterwards, with the NTFS, reserved, recovery and `HOPINSTALL` partitions byte for byte | The install finishing. The script couldn't find **Continue** on `Who are you?`, so it was stopped while copying, with no boot loader. The restart went to `Boot0042`, the installer, again |
| hop's own partition (`prepared`) | Linux Mint Cinnamon | **Change...** on that partition, **Use as** `Ext4 journaling file system`, `Format the partition`, **Mount point** `/`, **Install Now**, the question before writing naming `partition #7 of /dev/nvme0n1 as ext4`, then `Who are you?`. That partition was ext4 afterwards, with the same four byte for byte | The same |
| The same | Zorin OS, Linux Mint Xfce and MATE | As far as `Who are you?`, with an ext4 partition afterwards and the same four byte for byte | The same |
| `prepared`, a later run | Zorin OS, Linux Mint Cinnamon, Xfce and MATE | The install finished on all four, with the installer's startup entry first in `BootOrder`. `Installation Complete` was seen on Linux Mint Cinnamon and Zorin OS. It replaced `\EFI\Boot\bootx64.efi` and added `fbx64.efi` and `mmx64.efi` there, and `\EFI\Microsoft` was unchanged | **Starting from the disk.** The script couldn't read **Restart Now**, so nothing was restarted, and these stay refused |
| `toram` | Linux Mint Xfce and MATE, and Zorin OS and Linux Mint Cinnamon on a second disk | Nothing useful: they waited for the others, and were cancelled | Everything |
| The same, on a second disk | Linux Mint Cinnamon | The usual first screen, because Windows' disk is free, so its alongside option would use that disk. **Something else**, then as above. After the question before writing, it said `/cdrom` `could not be unmounted`, and **Continue** there went on to `Who are you?`, filled in, where the script couldn't find **Continue** | The install, or a restart. `HOPINSTALL` and the rest unchanged, and no ext4 on the disk |
| The same, on a second disk | Zorin OS | The same, except that **Continue** kept returning to `The installer needs to commit changes to partition tables, but cannot do so because` `/cdrom` `could not be unmounted`. It never got past that | The install, or a restart. Nothing was written |

**So `prepared` may not be enough:** the partition table can't be written while `/cdrom` is on that disk, at least on Zorin OS. That's a finding from these screens, not from a finished install.

The other results above are from runs whose partition checksums were read. Runs on a second kind of runner weren't counted: its loop devices didn't give hop's partitions, so they checked nothing.

## Debian and CachyOS next to Windows, in a virtual PC

`.github/workflows/calamares-vm.yml` runs `tools/vm/calamares/calamaresvm.py` on a GitHub Actions runner when a `probe/calamares` branch is pushed.
In QEMU with OVMF and KVM, on an 80 GB NVMe disk numbered as Windows numbers it: EFI partition with stand-ins for Windows' files as 1,
reserved partition as 2, an NTFS "C:" as 3, the recovery partition ending the disk as 4, and `HOPINSTALL` straight after C: as 5, with
40 GB free between them. The ISOs are the ones `Resolve-Download` finds, by their checksums: `debian-live-13.7.0-amd64-gnome.iso` and
`cachyos-desktop-linux-260809.iso`. The engine's real `Update-BootConfig` and `Copy-EspLoader` ran under pwsh, and the firmware started
`Boot0042` through `BootNext`, with a stand-in "Windows Boot Manager" first in `BootOrder`. Secure Boot was off.

The test adds `systemd.debug_shell=ttyS0` to the live menu, after hop's edits, for a root shell it only reads logs with. Calamares itself
was driven through its screens, as the steps that `Get-Steps` renders say: QEMU took screenshots, tesseract read them, and the mouse and keys
went in through QEMU. Nothing was preconfigured. After the install it put a marker service in the installed system, which writes where it
started from. Nobody logged in. **Green proves nothing by itself: read `report.txt` and look at the screens.**

| System | EFI partition | Runs | Installed | First start | After removing `HOPINSTALL` |
| --- | --- | --- | --- | --- | --- |
| Debian 13.7 | 200 MB | 2 | Yes, root on `/dev/nvme0n1p6` | `Boot0008 "Debian"`, shim, then GDM's login screen | Starts, root now on `/dev/nvme0n1p5` |
| Debian 13.7 | 100 MB | 1 | The same | The same | The same |
| CachyOS 260809 | 200 MB | 3 | Yes, root on `/dev/nvme0n1p6`, with Plasma | `Boot0008 "cachyos"`, then its login screen, `Reached target Graphical Interface` | **`grub rescue>`** |
| CachyOS 260809 | 100 MB | 1 | The same | The same | **`grub rescue>`** |

What the screens showed, in both:

- **The EFI partition is named after Windows.** The manual screen's legend calls it `Windows Boot Manager`, and its list `/dev/nvme0n1p1`,
  `FAT32`. `HOPINSTALL` is `/dev/nvme0n1p5`. Neither said **EFI System Partition**.
- **They offer Install alongside, Replace a partition and Manual partitioning.** CachyOS also offers Erase disk.
- **Create starts on ext4 in Debian, and on btrfs in CachyOS**, so the steps say to set it. CachyOS's legend then calls it `Root`.
- **Both say the EFI partition is too small, and both carry on.** At Next: `EFI system partition configured incorrectly`, `The filesystem must
  be at least 300 MiB in size` from Debian and `512 MiB` from CachyOS, then `You can continue without setting up an EFI system partition but
  your system may fail to start.` OK went on, and the summary said `Set up fat32 partition /dev/nvme0n1p1 with mount point /boot/efi`.
- **Their boot loaders need little room there.** Debian put `shimx64.efi`, `grubx64.efi`, `mmx64.efi`, `fbx64.efi` and a `grub.cfg` in
  `\EFI\Debian`, about 5 MB. CachyOS ran `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=cachyos --force` and put
  one 168 KB `grubx64.efi` in `\EFI\cachyos`. Both also replaced `\EFI\Boot\bootx64.efi`, the fallback loader. `\EFI\Microsoft` and
  `\EFI\hop` were unchanged.
- **Both menus list Windows**, as `Windows Boot Manager (on /dev/nvme0n1p1)`. It's a stand-in, so it wasn't started.
- CachyOS's desktop list starts on **No Desktop**. The test chose Plasma Desktop. Its install downloads packages, so it needs the internet.
- Debian starts installing straight from **Install**. CachyOS asks first, with **Install Now**.

**Why the user's GRUB said "no such partition".** The test then removed `HOPINSTALL` and moved every later GPT entry down one, as
`tests/Probe-GptNumbers.ps1` saw Windows do, so Linux's root went from 6 to 5. CachyOS's `grubx64.efi` carries `(,gpt6)/boot/grub` as its
prefix, so it looked for partition 6 and stopped at `error: kern/disk.c:grub_disk_open:368:no such partition.`, `Entering rescue mode...`,
`grub rescue>`, every time. Debian's `\EFI\Debian\grub.cfg` finds its files with `search.fs_uuid`, so it started again, with root on
`/dev/nvme0n1p5`. hop's **Remove the installer** now keeps `HOPINSTALL` when Linux comes after it. The CachyOS steps also say not to delete it by hand.

**What this doesn't show:** no real PC and no real Windows, so Windows was never started from GRUB's menu. Secure Boot was off, including for
Debian, whose shim could have started with it on. The test pressed Return for the warning's OK, and restarted with `systemctl reboot`,
because it couldn't read **Done**'s effect. hop's own screens and Undo weren't run. Nobody logged in, so the desktops weren't seen. A second
disk wasn't tried, and both are still refused there. The runs are
[41532656003](https://github.com/Arjun-Ingole/hop/actions/runs/41532656003) (CachyOS),
[41534597768](https://github.com/Arjun-Ingole/hop/actions/runs/41534597768) and
[41551488195](https://github.com/Arjun-Ingole/hop/actions/runs/41551488195).

## On a real Windows, in a virtual PC

`.github/workflows/windows-vm.yml`, started by hand, runs the real `hop.exe` on a real Windows: the Windows 11 Enterprise 24H2 evaluation, installed
unattended by `tools/vm/` into QEMU with OVMF, with Microsoft's Secure Boot keys and a software TPM. It's signed in as an ordinary administrator with
UAC on. The disk is 128 GB NVMe, laid out as Setup lays out a PC: EFI, MSR, C:, then the recovery partition at the end. Each scenario starts from a thin copy of
the same disk image. Keys and the mouse go in through QEMU, so they reach the elevation prompt too, and each step saves a screen.

**Green proves nothing here. Look at the screens and read the log.** The image is about 7 GB in `actions/cache`, which a repository shares up to 10 GB, so other big caches can evict it. Installing it again takes about 15 minutes.
QEMU's NVMe disks need nothing special: Windows reports the bus as NVMe, with removal policy 1, so hop accepts them, including as a second disk.

| Scenario | What it does | What was seen, November 2026 |
| --- | --- | --- |
| `screens` | Every screen that doesn't change the disk | Start, both pickers, a second disk, Install's confirmation, Replace Windows and ERASE. Replace Windows lists C: as going and the second disk as staying. Its button stays off for an empty box and for `ERAS`, and comes on for `ERASE` |
| `scales` | Those with most text at 100% and 125% | No clipping or overlap. Word gaps were wrong at 100% until text stopped using grid fitting |
| `stuck` | Forces the paging file to the end of C:, then Make room, then closes hop | 105 GB free and 1.4 GB releasable, with Windows naming `\pagefile.sys`. No "preventing restart" screen. hop came back by itself with no prompt, from the protected copy. 111 GB releasable afterwards. On closing hop, hibernation, the paging setting and a new change journal of the same size were back, and the tasks and copy had gone |
| `stuckinstall` | The same, then a real Ubuntu install in place of closing hop | The settings came back as the disk finished changing, not when hop closed. The copy had gone after the next restart. `defrag` gave up with 1223, and worked when tried again |
| `stuckmft` | Moves `$Mft::$BITMAP` to the end of C:, then Make room | 104 GB free and 5 GB releasable, with Windows naming `\$Mft::$BITMAP`. The restart and `defrag` left it there, with code 0. hop moved 5 clusters of it, and 111.8 GB was releasable. Windows' disk check found nothing wrong |
| `firstorder` | A real Ubuntu install, then **Try another way**, reached by leaving `BootNext` set in Windows, because real firmware can't be made to ignore it | The screen offered it. `BootOrder` became `0007,0003,...`, and the firmware started `Boot0007`, hop's entry, with Secure Boot on. Back in Windows through `BootNext`, opening hop put `BootOrder` back to `0003,...,0007`. `BootNextSticks` said True and left `BootNext` as it was. Undo took C: back to 127 GB, and Windows started again |
| `cancel` | A double click on Start, then Cancel during the first step | The second click did nothing and the install carried on. Cancel went back to choosing, with no state file and C: at its full size |
| `abandon` | Make room, hop killed once it's back, then a restart with nobody opening hop | Nothing changed for 18 minutes after that restart. By 21 minutes the settings were back, and the tasks, copy and state file had gone. Run again on `main` after the hardening work (`400e5ba`), on a GitHub runner: still off at 18 minutes, back at the next check, and the same after one more restart |
| `abandonfast` | The same, with the task started by hand | The same result in under a minute |
| `install` | A real Ubuntu 26.04.1 from its real download, with Secure Boot on, then back to Windows and Undo | See below |

**Install, with the recovery partition ending the disk.** C: went from 127 GB to 60 GB, with a 7 GB `HOPINSTALL` and 60 GB free after it, and the recovery partition where it was. On **Restart now**, Linux's own `efibootmgr` said `BootCurrent: 0007`, hop's
`Ubuntu installer (hop)` at `\EFI\hop\BOOTX64.EFI`, with `BootOrder` still starting with Windows. `mokutil` said `SecureBoot enabled`, and the kernel said it was locked down by Secure Boot. `/cdrom` was the installer partition and the kernel's line had
`nopersistent`. Ubuntu's installer opened.

**Undo.** Restarting from the live system started Windows, because `BootNext` had been used. hop's Undo took C: back to 127 GB, removed the entry, `\EFI\hop` and the partition, turned Fast Startup back on, and said "Drive C: is 67 GB bigger." Windows started again afterwards.

**What this doesn't show:** no Linux was installed next to this Windows, so booting Windows from GRUB wasn't seen. The partitions after a real install, Undo with Linux installed, and restarting into the installer after Make room weren't run.
Omarchy's `HOPLIVE` made by Windows wasn't started. It's one virtual PC with one evaluation Windows, so firmwares, drivers and security software elsewhere may differ. A standard user who typed an administrator's password wasn't tried, and neither was a task failing to register on a real Windows, which only the unit tests cover.

## Linux Mint and Zorin OS through hop's own partition, in a virtual PC

The same 130 GB disk, plus hop's real `prepared` partitions: 1 GB FAT32 `LINUXBOOT` and 59 GB exFAT `LINUXROOT`, the latter made by `mkfs.exfat`. Ubiquity's real screens, under a small X server, with a script reading and clicking them, with updates and third-party software unticked. The test put a marker in the installed system before restarting. It didn't press **Restart Now**, which it couldn't read: it waited for Ubiquity's startup entry and `Reverting lockdown` in its log, then forced a restart.

| System | Result | Started from disk | Windows' EFI files, and the partitions |
| --- | --- | --- | --- |
| Linux Mint Xfce 22.3 | **Pass.** `partition #7` as ext4, with `/boot/efi` on the existing EFI partition, and `LINUXBOOT` left alone | `Boot0009 "Ubuntu"` first in `BootOrder`, then `Windows Boot Manager`. The marker says root on `/dev/nvme0n1p7`, efi on `/dev/nvme0n1p1`, `graphical.target` active and a `lightdm` session on seat0. Its menu has `Windows Boot Manager (on /dev/nvme0n1p1)` | `\EFI\Microsoft` unchanged. **`\EFI\Boot\bootx64.efi` replaced**, and `fbx64.efi` and `mmx64.efi` added. MSR, C:, recovery and `HOPINSTALL` byte for byte, after the install and the restart |
| Linux Mint Cinnamon 22.3 | **Pass.** The same | `Boot0009 "Ubuntu"`, then `Windows Boot Manager`. The marker says root on `/dev/nvme0n1p7`, efi on `/dev/nvme0n1p1`, a `lightdm` session on seat0. Its menu has `Windows Boot Manager (on /dev/nvme0n1p1)` | The same |
| Linux Mint MATE 22.3 | **Pass**, on its second try, with the runner's disk cleared first: the first filled it up after 15 minutes. The same | `Boot0009 "Ubuntu"`, then `Windows Boot Manager`. The marker says root on `/dev/nvme0n1p7`, efi on `/dev/nvme0n1p1`, a `lightdm` session on seat0. Its menu has `Windows Boot Manager (on /dev/nvme0n1p1)` | The same |
| Zorin OS 18.1 | **Pass.** The same, `partition #7` | `Boot0009 "Zorin OS"` first in `BootOrder`, then `Windows Boot Manager`. The marker says root on `/dev/nvme0n1p7`, efi on `/dev/nvme0n1p1`, `gdm active` with a session on seat0. Its menu has `Windows Boot Manager (on /dev/nvme0n1p1)` | The same |

**What this doesn't show:** no real PC, so no real Windows was started afterwards, and nobody logged in. `\EFI\Boot\bootx64.efi` is what a firmware starts when it has no entries, so on such a PC that's Linux now. hop's Undo doesn't put it back.

## Testing for real

Use a virtual machine, not a PC you care about. It has to use UEFI:

- **Hyper-V:** a Generation 2 VM. Secure Boot defaults to a template Linux won't pass, so set it to
  "Microsoft UEFI Certificate Authority", or turn it off.
- **VirtualBox:** turn on "Enable EFI".
- **VMware:** set the firmware type to UEFI.

Give it 100 GB or more, and take a snapshot before each run.

## What to check

Note which of these you ran in your pull request. Anything touching disks or boot needs the first three.

**Install**

- [ ] Fresh Windows: install a `prepared` system (elementary OS) through to a working Linux
- [ ] Fresh Windows: install a `freespace` system (Ubuntu) through to a working Linux
- [ ] Windows with no partition after C:: Ubuntu's live system makes no `writable` partition
- [ ] Fresh Windows: install a system whose boot menu hop changes (Fedora, CachyOS or Arch) through to a working Linux
- [ ] Fedora or Ultramarine: click through **Share disk with other operating systems**, which automated tests don't reach
- [ ] Debian or CachyOS next to a real Windows: follow the steps, then start Windows from GRUB's menu. Then **Remove the installer**: `HOPINSTALL` stays, and CachyOS still starts
- [ ] Omarchy with BitLocker on, then paused: refused before the download. Then fully off: installs, and Windows starts from the firmware's boot menu and after `limine-scan`
- [ ] Omarchy: the live system starts from a `HOPLIVE` that Windows formatted
- [ ] Windows still starts afterwards, from the firmware's boot menu

**When it goes wrong**

- [ ] Secure Boot on: the installer starts, or the "didn't start" screen appears on reopening
- [ ] Secure Boot on, Pop!_OS, CachyOS or Arch: refused before the download, with what to do
- [ ] Secure Boot on, third-party certificate off: refused before the disk changes
- [ ] Windows on a second drive, EFI partition on the first: the startup entry is added to the first
- [ ] Cancel during the download, then install again: it resumes
- [ ] Disconnect the network during the download: the error says what to do
- [ ] Close the window during the download, then reopen
- [ ] After Make room, close the window during the download: hibernation and the paging file are back on straight away
- [ ] Make room on C:, with another app blocking the restart: hop isn't listed as blocking it, Cancel leaves a "didn't restart" screen after a minute, and both of its buttons work
- [ ] Make room on C: with a standard user who typed an administrator's password: hop comes back for that administrator, or the settings come back by themselves
- [ ] Make room on a second drive with its own paging file, and unplug that drive during the restart: hop opens, with the settings back
- [ ] Turn the VM off during the copy, then reopen: "didn't finish", and Clean up restores everything
- [ ] Fill C: until there isn't room: the window says how much to free
- [ ] Pick an ISO that isn't Ubuntu-based, and one with a file over 4 GB: both refused before the disk changes
- [ ] Open a second copy of hop: refused
- [ ] Click **Later**, then restart Windows yourself: Windows starts, not the installer
- [ ] Turn on Controlled Folder Access: making partitions still works, or the error explains why
- [ ] Zorin OS or any Linux Mint next to Windows: click through the steps yourself, press **Restart Now**, and check Windows still starts
- [ ] Those on a second disk: refused before anything changes, with the reason
- [ ] Plug in a USB stick with an Ubuntu ISO written to it: warned before starting, refused at restart
- [ ] Click Cancel as "Making room" begins: either it cancels with the disk untouched, or the install carries on

**Other drives**

- [ ] D: on the Windows disk, with C: too full: hop suggests D:, and a `freespace` system installs through to a working Linux
- [ ] Second disk with free space: `freespace` and `prepared` systems through to a working Linux, with Windows still starting
- [ ] Second disk with Fast Boot on: the installer starts, or the grub> prompt appears and a restart goes back to Windows
- [ ] Second disk with the Ubuntu boot loader on it: does the firmware start it? Mint's goes on Windows' EFI partition: does that start?
- [ ] Swap the disks' SATA ports after preparing: the setup is still recognised
- [ ] A locked BitLocker data drive: refused, with how to unlock it
- [ ] A Thunderbolt or USB4 NVMe enclosure: refused as something that can be unplugged. Nothing has checked this on real hardware
- [ ] A second NVMe drive inside the PC: still offered
- [ ] Undo with each: the space goes back to the right drive
- [ ] Debian or CachyOS with a second disk chosen: refused before anything changes, with the reason
- [ ] Arch on a second disk: click through archinstall's partition screens with both disks chosen, which automated tests only saw as far as choosing them
- [ ] Fedora or Ultramarine on a second disk: click through **Share disk with other operating systems**, which automated tests don't reach, with Windows' disk unselected
- [ ] Omarchy on a second disk: installs, starts, and Windows starts from the firmware's boot menu. Then remove it from hop: its `Limine` entry and EFI partition go too
- [ ] Make room on C:, then on D:: C:'s hibernation and paging file are back on before D: starts
- [ ] Two Windows Boot Manager entries, each with its own EFI partition: `\EFI\hop` and the startup entry are on the same one, the one this Windows started from

**Replacing Windows** (a VM you can lose, with a snapshot)

- [ ] Ubuntu with Secure Boot on, 16 GB of memory: the erase option is there, the disk erases, and it starts afterwards
- [ ] With too little memory for the ISO: refused with the reason, before the download
- [ ] The warning names the disk, its size and every drive on it, and Back and Cancel leave nothing changed
- [ ] The button stays off until ERASE is typed exactly, and Enter doesn't start it
- [ ] Click **Undo changes** on the ready screen: everything is back
- [ ] Restart, then turn the VM off in the installer without erasing: Windows starts, hop says it didn't start, and Undo works
- [ ] A locked BitLocker data drive on the same disk is listed as going too
- [ ] Two identical disks: refused, in plain words
- [ ] Linux Mint on a second disk, with its loader on Windows' EFI partition: named as stopping on the warning and on the ERASE screen. The same for a second Windows

**Undo**

- [ ] Undo before installing Linux: C: gets all its space back, and no startup entry or `\EFI\hop` remains
- [ ] Fast Startup is back on after undo, if it was on before
- [ ] Undo straight after installing, without reopening hop: the result names the drive and how much it grew
- [ ] Undo with the drive that gave up the space unplugged: it finishes, and says the space stays free
- [ ] A drive of your own named HOPINSTALL or LINUXBOOT with files on it, and no setup: hop doesn't offer to clean it up
- [ ] After installing Linux: reopen hop, it says installed, and removing the installer leaves Linux working and grows C:

**Another Linux**

- [ ] Another Linux on the drive is offered for removal, and goes
- [ ] A locked BitLocker data partition with no letter is **not** offered for removal
- [ ] Pond on the Windows disk and Mint on a second disk, sharing Windows' EFI partition: removing Pond leaves Mint starting, and the screen names Pond, or says what it left

**Upgrades**

- [ ] Prepare with an old build, open with the new one: the setup is still recognised
