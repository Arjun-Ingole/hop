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
| Lubuntu 26.04.1 | No | Yes | No | Its installer offered **Erase disk**, but the test stopped there, because it has one more screen than Debian's |
| Ubuntu Unity 26.04 | No | Yes | No | The test had nothing to drive: it doesn't run the installer service Ubuntu's does |
| Linux Mint 22.3, other flavours, CachyOS, Ultramarine, Pop!_OS, elementary OS | No | Not shown | No | Not finished, or not run, in the time allowed |
| Fedora 44 | No | Only after `umount /run/initramfs/live`: `rd.live.ram=1` copies but stays mounted | No | Anaconda stopped at "Installation Destination" with a kickstart that clears the disk |

Ubuntu's ISO in a virtual PC with 7 GB of memory copied itself to memory and then hadn't reached a login after seven
minutes, which is why hop refuses it.

The installer's choices weren't clicked by a person. Unattended settings stand in for them, except on Debian, and
the words in the steps come from the installer's own strings. The installers were also shown fewer disks or
choices than a PC would give them. **No real PC has done this,** the screens in hop have never been opened, and
neither Secure Boot nor BitLocker was part of these runs.

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

On a GitHub Actions runner, in QEMU with OVMF, on an 80 GB NVMe disk: a 100 MB EFI partition, an NTFS "C:", 1 GB FAT32 `HOPINSTALL`, 8 GB `HOPLIVE`, then
free space. The menu went through the engine's `Update-BootConfig`, and started through `Boot0042` and `BootNext` as hop writes them. It's the
real 4.0.6 ISO, by its checksum, and its real wizard on `tty1`: a script pressed keys and read `/dev/vcs1` back over the serial port. It chose the disk,
**Free space install** and the rest, as the steps say.

| Second partition | Letting go of the disk | Encrypted | Memory | Installed in | First start |
| --- | --- | --- | --- | --- | --- |
| exFAT | `umount -l` | No | 8 GB | About 2 minutes | Login screen, `Reached target Graphical Interface` |
| exFAT | `copytoram` | Yes, with the password typed at its prompt | 12 GB | About 2 minutes | Omarchy's desktop, which logs in by itself after that password |
| NTFS | `copytoram` | No | 12 GB | About 2 minutes | Login screen, `Reached target Graphical Interface` |
| exFAT, 7 GB, with a 4 GB `HOPINSTALL`, using the catalog's real entry | `umount -l` | Yes, with the password typed at its prompt | 8 GB | About 2.5 minutes | Omarchy's desktop, `Reached target Graphical Interface` |

In all four, the NTFS, `HOPINSTALL` and `HOPLIVE` partitions came through byte for byte, after the install and after the restart, and
Windows' EFI files were unchanged. Each check is from the disk image or the installed system's journal, not the job's result.

**What this doesn't show:** `HOPLIVE` was made by `mkfs.exfat`, not Windows. `tests/Probe-VirtualDisks.ps1` shows that Windows makes it and copies to it, but
no Linux has mounted one made by Windows. There's no real Windows, so `limine-scan` wasn't run, and neither was Windows started afterwards. BitLocker's refusal is
only tested by unit tests, and Secure Boot wasn't turned on. hop's own screens and Undo after this install haven't been run either.

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
- [ ] Make room on a second drive with its own paging file, and unplug that drive during the restart: hop opens, with the settings back
- [ ] Turn the VM off during the copy, then reopen: "didn't finish", and Clean up restores everything
- [ ] Fill C: until there isn't room: the window says how much to free
- [ ] Pick an ISO that isn't Ubuntu-based, and one with a file over 4 GB: both refused before the disk changes
- [ ] Open a second copy of hop: refused
- [ ] Click **Later**, then restart Windows yourself: Windows starts, not the installer
- [ ] Turn on Controlled Folder Access: making partitions still works, or the error explains why
- [ ] Linux Mint's installer works when run from the installer partition
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
- [ ] Debian, CachyOS, Arch, Fedora or Ultramarine with a second disk chosen: refused before anything changes, with the reason
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
