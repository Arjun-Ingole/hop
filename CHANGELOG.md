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

### Fixed

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
