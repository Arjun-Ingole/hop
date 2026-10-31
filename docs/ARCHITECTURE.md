# How hop works

## The idea

A USB installer is a FAT32 drive with the ISO's files on it, which the PC's firmware starts. hop makes
the same thing on the internal disk: a small FAT32 partition, plus a one-time startup entry.

```
Before   [EFI][MSR][ C: Windows                         ][Recovery]
After    [EFI][MSR][ C: Windows       ][ Installer ][ Linux ][Recovery]
```

The installer sits straight after C:, so once Linux is installed, removing it hands its space to C:.
Undo extends C: over all of it. Older builds put the installer after Linux, where Windows can't reach it.

The same layout works next to any drive, or at the end of free space. See [Where Linux can go](#where-linux-can-go).

Three things limit what it can install:

- **FAT32 can't hold a file of 4 GB or more,** which rules out Kubuntu's ISO.
- **The firmware has to start it.** Many firmwares only start files from the EFI system partition, so
  the ISO's signed boot loader is copied to `\EFI\hop` there. It then finds the installer partition
  by looking for `/.disk/info`.
- **The live system has to find itself.** Ubuntu's `casper` searches every partition for its files,
  which is why this works. Fedora and Arch look for a specific USB label or device, so they don't.

## Two languages, one exe

| | |
| --- | --- |
| `src/` (C#, WinForms on .NET Framework 4.8) | The window, plus what PowerShell can't do well: UEFI variables (`Firmware.cs`) and raw disk reads (`DiskProbe.cs`) |
| `engine/` (Windows PowerShell 5.1) | Everything that happens to the PC. Embedded in the exe and run in-process, because the Storage cmdlets are the supported way to resize partitions |

Both ship with Windows 10 and 11, so `hop.exe` needs nothing installed. `Engine.cs` hosts the scripts
in a runspace and calls their functions one at a time. Progress comes back through a shared hashtable,
`$Sync`, which the window polls.

## The engine

| File | What it does |
| --- | --- |
| `Common.ps1` | Names and labels, logging and progress. Loaded first |
| `System.ps1` | Blockers and warnings, BitLocker and Fast Startup |
| `Catalog.ps1` | The list of systems |
| `Download.ps1` | Finds the official ISO, downloads and verifies it |
| `Iso.ps1` | Mounts an ISO and checks hop can use it |
| `SecureBoot.ps1` | Works out whether Secure Boot will let the ISO start |
| `Drives.ps1` | Which drives Linux can go on, and why not, and where the ISO can go |
| `Disk.ps1` | Plans the space, makes partitions, copies files |
| `Boot.ps1` | The EFI partition and the startup entry |
| `State.ps1` | What hop left on this PC, and `state.json` |
| `OtherLinux.ps1` | Finds and removes another Linux, such as Pond |
| `Install.ps1` | The main flows: install, restart and undo |
| `MakeRoom.ps1` | Clears what stops a drive shrinking, across a restart if it must, and puts it all back |
| `Steps.ps1` | What to click in each Linux installer |
| `Report.ps1` | The bug report |

## The install, step by step

1. Check the PC (`Get-Blockers`).
2. Check the startup menu can be read and changed (`Assert-FirmwareAccess`), because the entry is
   added after the disk has changed. Then download and verify, or take the user's ISO.
3. Mount and check the ISO, check Secure Boot will start it and the EFI partition has room, and plan
   the space. **Nothing on the disk has changed yet.**
4. Save the state, pause BitLocker, turn off Fast Startup.
5. Shrink the chosen drive if needed, and make the partitions. Each is recorded before it's formatted.
6. Copy the files and compare them one by one, then mark `Copied`.
7. Add the startup entry. A failure here is kept, not rolled back, and Restart now tries again.
8. On **Restart now**, and not before, set the one-time start. Other restarts still go to Windows.

A failure in steps 4 to 6 runs `Invoke-Cleanup`, which puts everything back.

## What hop leaves on a PC

| What | Where | How it's found |
| --- | --- | --- |
| Installer partition | After the chosen drive | Label `HOPINSTALL` |
| Linux partitions (`prepared` systems) | After the installer | Labels `LINUXBOOT`, `LINUXROOT` |
| Boot loader copy | `\EFI\hop` on Windows' EFI partition | Fixed path |
| Startup entry | UEFI variables | `(hop)` in its name |
| ISO | Downloads, or `\hop` on another drive | Named in the log |
| State and logs | `C:\ProgramData\hop` | Fixed path |
| Which disks hold Linux hop put there | `C:\ProgramData\hop\linux-disks.json` | Fixed path |

Clean-up works from these, not just the state file, so it works after a crash. It looks for labels on
the Windows disk and every internal disk. USB drives are skipped, because they could be from another PC,
and off the Windows disk the format has to match as well as the label. Builds named LinuxHop used
`LINUXHOP`, `\EFI\linuxhop` and `(LinuxHop)`, which are still recognised.

`state.json` names the disk by its GUID and the volume by where it starts, because disk and partition
numbers change, especially with a second disk. A file with neither is from an older build, which only
ever used C:. Its `WindowsShrunk` and `InstallerNextToWindows` now mean the chosen drive, and keep their
names so that older files still read correctly.

## How the installer starts

Read from the boot files of the ISOs in the catalog (October 2026):

1. The firmware starts `\EFI\hop\BOOTX64.EFI`, which is shim. Its signature must chain to a
   certificate in the PC's Secure Boot list. All of them are signed by Microsoft's UEFI CA 2011 only.
2. Shim starts `grubx64.efi` from the same folder, signed by Canonical.
3. GRUB's built-in config looks for `/boot/grub` on the EFI partition. It isn't there, so GRUB searches
   every partition for `/.disk/info`, finds the installer partition and loads its `/boot/grub/grub.cfg`.
   The modules for FAT and GPT are built in.
4. GRUB starts `/casper/vmlinuz` from there. With Secure Boot on, the kernel must be signed. Pop!_OS's isn't.
5. Casper searches the partitions of every disk, NVMe included, for its files. It accepts FAT and
   matches the ID in `.disk/casper-uuid-*` where the ISO has one. (Read in Ubuntu 26.04.1, Mint 22.3
   and elementary OS 8.1.)

A problem from step 3 onwards stops at GRUB or the Linux console. **Coming straight back to Windows
means step 1 or 2 failed, or the firmware never tried:** firmware moves on to the next startup entry
when a loader is refused or exits. Firmware clears `BootNext` as it starts, so one still set after
coming back means it never tried, which is what `Test-BootNextIgnored` looks for.

## Where Linux can go

`Get-DriveBlocker` in `Drives.ps1` is the one place that decides, and it gives the reason.

| | Viable |
| --- | --- |
| A disk | NVMe, SATA, SAS, ATA or SCSI. GPT and basic, online, writable and healthy. Not RAID, and with no other Windows or Linux on it |
| A volume to shrink | All of that, plus: an ordinary data partition with a letter, NTFS, healthy, unlocked, not part way through encrypting, and not holding Windows' recovery files |
| Free space | Any free space on such a disk, unless it's right after a volume that can use it |

The Windows disk keeps the checks it has always had, so C: is still judged by them and nothing else.
RST mode there only gets a warning. A volume on that disk gets the volume checks too.

Paging files and restore points don't refuse a drive, because they only limit how far it shrinks. That's
what Make room is for. Working that limit out can take minutes on a big drive, so the list estimates from
free space and hop asks Windows once a drive is chosen, with a limit of five minutes.

Make room needs less on another drive. It has no hibernation file, and usually no paging file. So hop clears
the change journal and moves files, with the same 15 minute limit, and restarts only if that drive has a
paging file of its own. A paging file left to "Windows chooses" isn't touched, because hop can't tell where
it will go next.

## A second disk

The installer and Linux go on the target disk, next to each other. A full C: couldn't hold the
installer, and it keeps everything hop made in one place.

**The boot loader stays on Windows' EFI partition.** That's the one partition this firmware is known to
start. The alternative was a new EFI partition on the target disk, which adds a partition to someone's data
disk, relies on the firmware starting from it, and gives the Linux installers another one to find.
GRUB then finds `/.disk/info` by searching every disk the firmware has started, and it [asks the firmware
for them](https://github.com/rhboot/grub2/blob/fedora-40/grub-core/disk/efi/efidisk.c). Casper loops over
`/sys/block/*`, so it searches every disk regardless of what the firmware did.

**The risk is Fast Boot.** A firmware set to start quickly may not start the second disk before GRUB runs.
GRUB then can't find the installer and stops at a prompt. Since the entry is one-time only, turning the PC
off and on goes back to Windows. hop warns about this, and it's in Troubleshooting.

**What each Linux installer does with GRUB:**

| | Which EFI partition | What hop tells people |
| --- | --- | --- |
| Ubuntu and flavours ([subiquity](https://github.com/canonical/subiquity/blob/main/subiquity/common/storage/boot.py)) | The one on the disk named under **Device for boot loader installation**, made in that disk's first big enough free space if it has none. So this is chosen before making the Linux partition | Choose the target disk, which keeps GRUB off Windows' partition. If Fast Boot hides the disk, the PC goes back to Windows instead of stopping at a prompt |
| Linux Mint ([partman-efi](https://github.com/linuxmint/ubiquity/blob/master/d-i/source/partman-efi/fstab.d/efi), [bug](https://bugs.launchpad.net/bugs/1396379)) | The first one it finds, whatever the list says. Usually Windows' | Leave the list alone |
| Lubuntu (Calamares) | The existing one it's told to use | Its existing step, which is Windows' |
| elementary OS, Pop!_OS ([distinst](https://github.com/pop-os/distinst/blob/master/src/installer/steps/bootloader.rs)) | Whichever is mounted at `/boot/efi`, which is hop's `LINUXBOOT` on the target disk. The startup entry points at it | The same steps as ever |

**The easy option isn't used for a second disk.** Ubuntu's [picks the largest free space on any
disk](https://github.com/canonical/ubuntu-desktop-provision/blob/main/apps/ubuntu_bootstrap/lib/pages/storage/guided_resize/guided_resize_model.dart),
and [skips a disk](https://github.com/canonical/subiquity/blob/main/subiquity/server/controllers/storage.py)
whose only partition is the running installer. Mint's takes the biggest free space it finds. On the Windows
disk hop still suggests it, unless other free space is as big as Linux's, which `Test-AlongsideFindsLinux`
checks once the partitions exist.

None of this has been started on real hardware. It comes from reading those installers' source. See
[Testing](TESTING.md).

## Why the startup entry is written directly

`bcdedit` can only make Windows Boot Manager objects, and the firmware's one-time boot can't use those.
`Firmware.cs` writes `Boot####` and `BootNext` itself, as `efibootmgr` does on Linux.

## Why partitions are identified by signature

To Windows, an ext4 partition and a locked BitLocker drive look the same: unreadable, with no letter.
`DiskProbe.cs` reads the first bytes of the partition, so hop only offers to remove what it can
positively identify as Linux.
