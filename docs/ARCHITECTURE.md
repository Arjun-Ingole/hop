# How hop works

## The idea

A USB installer is a FAT32 drive with the ISO's files on it, which the PC's firmware starts. hop makes
the same thing on the internal disk: a small FAT32 partition, plus a one-time startup entry.

```
Before   [EFI][MSR][ C: Windows                         ][Recovery]
After    [EFI][MSR][ C: Windows       ][ Linux ][ Installer ][Recovery]
```

Linux and the installer sit straight after C:, so Undo can hand the space back by extending C:.

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
| `Disk.ps1` | Plans the space, makes partitions, copies files |
| `Boot.ps1` | The EFI partition and the startup entry |
| `State.ps1` | What hop left on this PC, and `state.json` |
| `OtherLinux.ps1` | Finds and removes another Linux, such as Pond |
| `Install.ps1` | The main flows: install, restart and undo |
| `Steps.ps1` | What to click in each Linux installer |
| `Report.ps1` | The bug report |

## The install, step by step

1. Check the PC (`Get-Blockers`).
2. Download and verify, or take the user's ISO.
3. Mount and check the ISO, and plan the space. **Nothing on the disk has changed yet.**
4. Save the state, pause BitLocker, turn off Fast Startup.
5. Shrink C: if needed, and make the partitions. Each is recorded before it's formatted.
6. Copy the files and compare them one by one, then mark `Copied`.
7. Add the startup entry. A failure here is kept, not rolled back, and Restart now tries again.

A failure in steps 4 to 6 runs `Invoke-Cleanup`, which puts everything back.

## What hop leaves on a PC

| What | Where | How it's found |
| --- | --- | --- |
| Installer partition | After Linux | Label `HOPINSTALL` |
| Linux partitions (`prepared` systems) | After C: | Labels `LINUXBOOT`, `LINUXROOT` |
| Boot loader copy | `\EFI\hop` on the EFI partition | Fixed path |
| Startup entry | UEFI variables | `(hop)` in its name |
| State and logs | `C:\ProgramData\hop` | Fixed path |

Clean-up works from these, not just the state file, so it works after a crash. Builds named LinuxHop
used `LINUXHOP`, `\EFI\linuxhop` and `(LinuxHop)`, which are still recognised.

## Why the startup entry is written directly

`bcdedit` can only make Windows Boot Manager objects, and the firmware's one-time boot can't use those.
`Firmware.cs` writes `Boot####` and `BootNext` itself, as `efibootmgr` does on Linux.

## Why partitions are identified by signature

To Windows, an ext4 partition and a locked BitLocker drive look the same: unreadable, with no letter.
`DiskProbe.cs` reads the first bytes of the partition, so hop only offers to remove what it can
positively identify as Linux.
