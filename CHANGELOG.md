# Changelog

## Unreleased

### Added

- **Replace Windows, where hop has seen it work.** For Ubuntu, Zorin OS, Debian and Arch, hop can set up an installer
  that erases the whole disk Windows is on. It's the last row of the drive list, is never chosen for you, and shows the disk,
  its size and every drive on it that would go, then asks you to type ERASE. hop itself still only makes the
  installer: the Linux installer does the erasing, when you tell it to. Undo works until then.
  It needs enough memory to hold the ISO with 4 GB left over, and says so if there isn't.
- Zorin OS, Debian, Fedora Workstation, Ultramarine, CachyOS and Arch Linux. CachyOS and Arch need Secure
  Boot off, as they say when picked, and Arch installs from a text prompt.
- Fedora and Ultramarine no longer need a command typed in Terminal. Their installer can now use the drive
  by itself, with Secure Boot on. Automated installs into free space finished and started again in a virtual
  PC, though the installer's graphical screens haven't been clicked through yet.
- hop checks the EFI partition has about 25 MB more room for Fedora and Ultramarine before changing the disk.
  Without it, their installer says it finished but the PC can't start the new system.
- hop now changes the copy of the boot menu for systems that look for their USB stick by name. It checks
  it can do that before the disk changes.
- **Choose where Linux goes.** hop can shrink another drive such as D:, use free space on any disk inside
  the PC, or use a second disk. C: is still the default when it has room, and when it hasn't, hop suggests
  a drive that has.
- **hop says why it can't use a drive.** USB drives, virtual disks, Storage Spaces, RAID, MBR and dynamic
  disks, locked BitLocker drives, drives that aren't NTFS, and disks holding another system are each
  refused with the reason. A problem with C: only stops hop if no other drive will do.
- **The download goes where there's room.** A full C: no longer blocks it, and you can choose the drive.

### Fixed

- A Thunderbolt or USB4 NVMe enclosure counted as a drive inside the PC, because it reports the same bus. hop now asks
  Windows whether it expects a drive to be unplugged, and refuses it if so, or if Windows won't say. Windows' own disk
  isn't affected. This hasn't been tried on real Thunderbolt hardware.

### Changed

- Make room works on the chosen drive. Other drives usually need no restart.
- The steps for the Linux installer now depend on where Linux is going. They use the manual option if the
  easy one would pick different free space.
- Undo gives space back to the drive it came from, and clean-up finds hop's partitions on any internal disk.

## 0.2.0 - 2026-10-31

### Fixed

- hop said C: needed more free space when it had plenty, but Windows couldn't shrink it. **Make room**
  now clears what's in the way in one click: hibernation, the paging file and the change journal, then a
  restart and moving what's left. It turns them back on afterwards. Bug reports name the file in the way.

## 0.1.1 - 2026-10-31

### Fixed

- The Secure Boot check turned off the permission hop needs for the startup menu, and hop assumed it
  still had it. Adding the startup entry could then fail after the disk had changed, on any PC. hop now
  asks for the permission before every firmware read and write.
- A PC whose startup menu can't be changed was only caught after the disk had changed. hop now checks
  before the download and stops with nothing changed.
- Firmware errors now include the Windows error code.
- The reason hop stopped wasn't in the log, so bug reports didn't show it.

### Changed

- Pop!_OS says it needs Secure Boot off as soon as it's picked, instead of after clicking Install.

## 0.1.0 - 2026-10-31

### Added

- Checks before anything changes: Legacy BIOS, MBR, ARM, virtual disks, non-NTFS and damaged drives
  stop with an explanation. Running on battery, RAID mode, a pending Windows update, BitLocker and low
  memory get a "before you start" screen.
- A screen for when the PC comes back to Windows instead of the installer, with the likely cause, the
  boot menu key for that PC's maker, and a button that restarts straight into the BIOS.
- A screen for when Linux has been installed, offering to remove the installer.
- Logs in `C:\ProgramData\hop\logs`, and "Copy a bug report" on failure screens.
- Only one copy of hop can run at a time. Crashes are written to the log.
- Before the disk changes, hop checks Secure Boot will start the system: that the PC trusts the
  certificate behind its boot loader, and that its kernel is signed. Pop!_OS, whose kernel isn't, is
  stopped before the download.
- The "didn't start" screen can tell when the firmware ignored the request to start the installer.
  Bug reports include the boot order and trusted certificates.

### Fixed

- Undo could remove the wrong partition, even Windows' recovery partition, if partition numbers
  shifted while it worked. It now finds each by where it starts.
- Undo could remove the partition Linux starts from if the firmware had dropped its startup entry.
  hop now also notices Linux by its partitions.
- Windows on a second drive, starting from the first drive's EFI partition, failed after the disk had changed.
- A full EFI partition is now caught before the disk changes.
- A problem that stops new installs, such as damage reported on C:, also hid Undo.
- BitLocker's pause could run out before the BIOS trip to turn off Secure Boot. Each restart now renews it.
- A server error while resuming deleted the partly downloaded file.
- Undo grew C: over free space it had never taken from it.
- The check for Legacy BIOS now asks Windows directly.
- Removing another Linux could select a locked BitLocker drive, because it looked for partitions
  Windows couldn't read. It now reads each partition's own signature.
- A failure while adding the startup entry threw away a finished copy. The installer is now kept and
  Restart now tries again.
- Undo missed partitions that were created but never formatted.
- Undo left Fast Startup off and BitLocker paused.
- A missing drive letter after a restart looked like a failed attempt and offered to delete the installer.
- A download that had already finished, or came from an expired link, failed on every retry.
- Downloads now check for disk space first, detect stalled connections, use the Windows proxy, verify
  the final size and use the real Downloads folder.
- Sparse ISO files, ISOs in cloud folders, ISOs too big for FAT32 and a full EFI partition now work or
  explain themselves.

- Installer files with very long names, like two of Pop!_OS's packages, now keep their real names.
- Cancel could land just as the disk started changing. Now either Cancel wins or the install does.
- The message after Undo says what actually happened to the space.

- The next restart only goes to the installer after **Restart now**. Before, a Windows Update restart could
  start it after you clicked **Later**.
- If the firmware removes hop's startup entry, hop says so, and no longer suggests turning off Secure Boot.
- A blocked EFI partition is now found before the disk changes, not after.
- Work proxies that need a Windows sign-in now work for downloads.
- ISOs whose kernel depends on a link are refused before the disk changes.

### Changed

- The installer now sits next to C:, so removing it after installing Linux gives its space to Windows.
- hop warns about another Linux installer on the PC, and won't restart with one on a USB drive.
- Renamed from LinuxHop to hop, with a new logo. Setups made by LinuxHop builds are still recognised.
- The boot loader now runs from Windows' EFI partition, because many firmwares won't start files from anywhere else.
