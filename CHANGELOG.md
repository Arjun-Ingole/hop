# Changelog

## Unreleased

### Added

- **Replace Windows, where hop has seen it work.** For Ubuntu, Zorin OS, Debian and Arch, hop can set up an installer
  that erases the whole disk Windows is on. It's the last row of the drive list, is never chosen for you, and shows the disk,
  its size and every drive on it that would go, then asks you to type ERASE. hop itself still only makes the
  installer: the Linux installer does the erasing, when you tell it to. Undo works until then.
  It needs enough memory to hold the ISO with 4 GB left over, and says so if there isn't.
- Omarchy 4.0, next to Windows. Its 6 GB file doesn't fit on the installer partition, so hop makes a second one for it. It needs Secure Boot off, and
  BitLocker fully off on its disk, because its installer refuses even a paused one. hop checks before the download and won't turn it off for you. A full install
  and restart worked in a virtual PC. Afterwards the PC starts Omarchy, and its menu doesn't list Windows until you add it. Later versions of Omarchy
  are refused until they've been tried.
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

- **Make room asked for permission at sign-in, with No already chosen.** hop came back through an elevation prompt after its
  restart, from an unknown publisher. Clicking No left hibernation and the paging file off until hop was next opened. hop now
  comes back by itself, with no prompt, through a scheduled task that it removes as soon as hop has opened.
- **Make room's settings come back even if you never return to hop.** A second task puts them back from 20 minutes after Windows
  starts, once hop isn't running. If either task can't be made, hop puts the settings back and doesn't restart.
- **The tasks can't be used to get around UAC.** They run a copy of hop in a new folder under `%ProgramData%` that only administrators
  can write to, with fixed arguments, and it's deleted when Make room is finished.
- **Make room could leave hibernation off on a new Windows.** Windows only records a default there until something changes it, and hop
  read that as hibernation being off, so it never turned it back on.
- **Words ran together at 100% display scale,** as in "Movingfiles". Text was measured with different settings from those it was drawn with.
- The heading says **Making room** while files are being moved after the restart, not **Checking this PC**.
- **Ubuntu's live system could take the space set aside for Linux.** If nothing came after that space on the disk, its
  `casper` startup code made a partition called `writable` over all of it, and the installer then had nowhere to put
  Linux. This also affects released builds, and every system built on it: Ubuntu's flavours, Linux Mint, elementary OS,
  Pop!_OS and Zorin OS. A PC with Windows' recovery partition at the end of the disk wasn't affected. hop now tells it
  not to, in the installer's copy of the boot menu, which still starts with Secure Boot on.
- That partition made hop say Linux was installed, and Undo left it there. hop now recognises it when it can tie it
  to its own setup, and doesn't say that. Undo and Restart now remove it. One it can't tie to its setup is left alone.
- A chosen ISO whose boot menu doesn't start the kernel from a `casper` folder is now refused before the disk changes.
- A Thunderbolt or USB4 NVMe enclosure counted as a drive inside the PC, because it reports the same bus. hop now asks
  Windows whether it expects a drive to be unplugged, and refuses it if so, or if Windows won't say. Windows' own disk
  isn't affected. This hasn't been tried on real Thunderbolt hardware.

### Changed

- Make room works on the chosen drive. Other drives usually need no restart.
- The steps for the Linux installer now depend on where Linux is going. They use the manual option if the
  easy one would pick different free space.
- Undo gives space back to the drive it came from, and clean-up finds hop's partitions on any internal disk.
- Debian, CachyOS, Arch, Fedora and Ultramarine can't go on a second disk for now. Their steps were written
  for the disk Windows is on, and none has been tried on another. hop says so before anything changes.

### Fixed

- **Make room's restart could be blocked by hop itself**, because it refused to close while waiting for that
  restart. Windows could then say hop was preventing it. If something else stops the restart, hop now says so
  and offers to restart again or put its settings back.
- **Replace Windows no longer risks the wrong disk.** It refuses when another disk has the same name and size,
  because the Linux installer's list couldn't tell them apart.
- **Replace Windows no longer says other disks are safe when they aren't.** A Linux or a second Windows that
  starts from the EFI partition on that disk is named in the warning as stopping, or hop refuses if it can't look.
- **Removing one Linux no longer takes another's way of starting.** It only removes startup entries and files it
  can tie to that system, and says which it left, so the name on the screen is the right one too.
- Clean up lists what it will delete, with size and drive, and a drive that only shares a name with what hop makes
  is no longer treated as hop's.
- Undo can't get stuck: if the drive that gave up the space has gone or won't grow, it finishes everything else and
  says the space stays free. A problem working out how far a drive shrinks no longer hides Undo either.
- Make room on a second drive turned C:'s settings off for good, a drive missing after its restart stopped
  hop opening at all, and closing hop during the download left the settings off. All three now put them back.
- The startup entry could point at a different EFI partition from its files on a PC with two Windows Boot Manager entries.
- Undo reported the wrong result straight after an install, and the confirmation could say a drive would keep its
  size when a bigger ISO would shrink it. Two drives that couldn't release their space kept suggesting each other.
- Sentences such as "Linux Mint , downloaded from..." no longer have a gap where a value is missing.

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
