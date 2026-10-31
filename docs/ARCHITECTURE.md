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

Three things limit what it can install:

- **FAT32 can't hold a file of 4 GB or more,** which rules out the ISOs of Kubuntu and Omarchy, whose
  `airootfs.sfs` is 6.1 GB. Omarchy's installer also hides the disk it started from, so it couldn't
  use free space next to the installer, and it refuses a disk with BitLocker on it, even paused.
- **The firmware has to start it.** Many firmwares only start files from the EFI system partition, so
  the ISO's signed boot loader is copied to `\EFI\hop` there. It then has to find the installer partition,
  and how it does that depends on the system.
- **The live system has to find itself.** Ubuntu's `casper` and Debian's `live-boot` search every
  partition, so they just work. Fedora's `dracut` and Arch's `archiso` look for a specific label or disc
  stamp, so `Update-BootConfig` changes the copy of their boot menu to name `HOPINSTALL`.

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
| `Disk.ps1` | Plans the space, makes partitions, copies files |
| `Boot.ps1` | The copied boot menu, the EFI partition and the startup entry |
| `State.ps1` | What hop left on this PC, and `state.json` |
| `OtherLinux.ps1` | Finds and removes another Linux, such as Pond |
| `Install.ps1` | The main flows: install, restart and undo |
| `MakeRoom.ps1` | Clears what stops C: shrinking, across a restart, and puts it all back |
| `Steps.ps1` | What to click in each Linux installer |
| `Report.ps1` | The bug report |

## The install, step by step

1. Check the PC (`Get-Blockers`).
2. Check the startup menu can be read and changed (`Assert-FirmwareAccess`), because the entry is
   added after the disk has changed. Then download and verify, or take the user's ISO.
3. Mount and check the ISO, check Secure Boot will start it and the EFI partition has room, and plan
   the space. **Nothing on the disk has changed yet.**
4. Save the state, pause BitLocker, turn off Fast Startup.
5. Shrink C: if needed, and make the partitions. Each is recorded before it's formatted.
6. Copy the files and compare them one by one, then mark `Copied`.
7. Add the startup entry. A failure here is kept, not rolled back, and Restart now tries again.
8. On **Restart now**, and not before, set the one-time start. Other restarts still go to Windows.

A failure in steps 4 to 6 runs `Invoke-Cleanup`, which puts everything back.

## What hop leaves on a PC

| What | Where | How it's found |
| --- | --- | --- |
| Installer partition | After C: | Label `HOPINSTALL` |
| Linux partitions (`prepared` systems) | After C: | Labels `LINUXBOOT`, `LINUXROOT` |
| Boot loader copy | `\EFI\hop` on the EFI partition | Fixed path |
| Startup entry | UEFI variables | `(hop)` in its name |
| State and logs | `C:\ProgramData\hop` | Fixed path |

Clean-up works from these, not just the state file, so it works after a crash. Builds named LinuxHop
used `LINUXHOP`, `\EFI\linuxhop` and `(LinuxHop)`, which are still recognised.

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

Other systems differ in steps 2, 3 and 5. The catalog holds what differs (`Live`, `BootConfigs`,
`BootEdits`, `GrubDir`, `EspShell`), so a similar system is one entry. Read from the October 2026 ISOs:

| System | Boot loader, signed by | How it finds the installer partition | How the live system finds itself |
| --- | --- | --- | --- |
| Zorin OS 18.1 | shim and GRUB, Microsoft and Canonical | `/.disk/info` | `casper` searches |
| Debian 13 | shim and GRUB, Microsoft and Debian | `/.disk/info` | `live-boot` searches |
| Fedora 44, Ultramarine 44 | shim and GRUB, Microsoft and Fedora | `grub.cfg` next to GRUB, by label | `root=live:LABEL=HOPINSTALL` |
| CachyOS | GRUB, unsigned | Its own built-in config, by a marker file | `archisolabel=HOPINSTALL` |
| Arch Linux | systemd-boot, unsigned | See below | `archisolabel=HOPINSTALL` |

Fedora's and Ultramarine's installer, Anaconda, protects the whole disk behind `/run/initramfs/live`,
and so refuses the disk holding the installer partition. Its log says so, and after
`umount -l /run/initramfs/live` it no longer does, which is why their steps have that command.

The edits only touch the copy on the installer partition. Shim checks the signatures of programs, not of
GRUB's config, so a changed menu still starts with Secure Boot on.

Arch is the odd one. systemd-boot only reads its menu and kernels from its own partition, and they
need 270 MB, which Windows' EFI partition doesn't have. So `\EFI\hop\BOOTX64.EFI` is the EFI Shell from
Arch's ISO, whose `startup.nsh` finds the installer partition and starts systemd-boot there.

A problem from step 3 onwards stops at GRUB or the Linux console. **Coming straight back to Windows
means step 1 or 2 failed, or the firmware never tried:** firmware moves on to the next startup entry
when a loader is refused or exits. Firmware clears `BootNext` as it starts, so one still set after
coming back means it never tried, which is what `Test-BootNextIgnored` looks for.

## Why the startup entry is written directly

`bcdedit` can only make Windows Boot Manager objects, and the firmware's one-time boot can't use those.
`Firmware.cs` writes `Boot####` and `BootNext` itself, as `efibootmgr` does on Linux.

## Why partitions are identified by signature

To Windows, an ext4 partition and a locked BitLocker drive look the same: unreadable, with no letter.
`DiskProbe.cs` reads the first bytes of the partition, so hop only offers to remove what it can
positively identify as Linux.
