# Changelog

## Unreleased

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

### Changed

- Renamed from LinuxHop to hop, with a new logo. Setups made by LinuxHop builds are still recognised.
- The boot loader now runs from Windows' EFI partition, because many firmwares won't start files from anywhere else.
