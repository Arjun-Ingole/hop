# Changelog

## Unreleased

### Fixed

- **Remove the installer could stop Linux starting.** Windows renumbers every partition after one it removes, and Linux and GRUB find partitions by number, so GRUB stopped at "no such partition". hop now keeps the installer partition when removing it would renumber Linux, and says so. Seen in a real GPT on a virtual disk.
- Debian and CachyOS are no longer offered next to Windows, because nobody has seen either start afterwards. Debian can still replace Windows.

- The steps for Debian, CachyOS and Arch now find Windows' EFI partition by its size and FAT32, as every installer shows it. CachyOS lists it as /dev/nvme0n1p1 or Windows Boot Manager, never "EFI System Partition", and HOPINSTALL is FAT32 too.

- When an ordinary file limits the shrink, Make room tries to move it too. Something usually keeps a file like that in place, such as the app using it, so this may not work. If it doesn't, hop now names the full path and says what to do.

## 0.3.2 - 2026-11-02

### Added

- Omarchy 4.5.0-rc3, from your own ISO with the name it's downloaded with. Its new installer reads a system image from the install media, which hop now keeps where it looks. Tested installing next to Windows in a virtual PC, with and without encryption.

### Fixed

- New partitions that start offline, as on some PCs, are brought online. Formatting them failed with "Invalid Parameter".
- Undo after a failed install removes the partitions it just made, even over old data, and says if one is left.
- Make room moves NTFS system files even when defrag used up its time.
- Your own ISO of Omarchy, Arch, CachyOS, Fedora, Ultramarine or Debian is accepted, by its original name.
- hop says when BitLocker is encrypting or decrypting C:, and when it's on for a drive that's short of room.
- A damaged Make room record no longer reopens hop at every sign-in, and hop says so, and what Make room couldn't turn back on, as it opens.
- hop checks which partition diskpart has selected before deleting with it.
- Make room's safety task names SYSTEM by its SID, so it registers on Windows in any language.

## 0.3.1 - 2026-11-02

### Added

- **Try another way.** When the firmware won't follow hop's one-time start, hop can put the installer first in the startup order, and moves it back the next time hop opens in Windows. Until then, the PC's boot menu is how to reach Windows.
- **Turn off Secure Boot.** Systems that need it off now get a button and steps, by PC maker, and hop restarts into the BIOS for you. BitLocker is paused for that restart.
- **Report this on GitHub** copies a report and opens a new issue to paste it into. Nothing is sent by itself.
- hop keeps the PC from sleeping on its own while it works.
- hop tests a startup menu change before the disk changes, and warns if the firmware refuses it.
- Intel RST/VMD and other RAID controllers are spotted by name, because their drives can report as plain NVMe.
- Troubleshooting for a black screen, with `nomodeset`.

### Fixed

- **hop no longer says a system is ready when it isn't.** A Cancel could stop the install with no error, and hop read that as success: "ready", with steps for 0 GB. A stopped install now counts as stopped, hop checks it reached the end, and Cancel appears a moment later, so a double click on Start can't hit it.
- **Screens only say what's been checked.** Removed, gone and space back now rest on reading the PC afterwards. A new partition alone no longer means Linux is installed. Clean up lists what it couldn't remove. Undo says the ISO stays, and where. A drive that can't be measured no longer reads as full.
- **Make room gets past `$Mft::$BITMAP`.** Windows' defrag can leave this NTFS file near the end of a drive, where it stops Windows shrinking it. hop now moves it, and the other NTFS files Microsoft lists as movable, when Windows names one.
- hop took its 8 GB safety margin off what Windows could release, even with plenty left free inside the drive, so a drive that could release a few GB showed 0.
- Make room left the paging file on for most 8 GB PCs, which report less than 8 GB. PCs with too little memory now get told why it may not help.
- If Windows stops moving files early, hop offers **Move files again** instead of saying it did all it could. Make room also waits up to a day for you to sign in before undoing itself, and says so when hop won't reopen by itself.
- Remove now lists every partition it deletes, because it takes all the Linux partitions on the disk, and it stops if that list has changed. It deletes partitions before startup entries, so trying again after a failure finds everything.
- hop's startup entry can no longer land first in the startup order if that order lists an entry that's gone, which would have started the installer on every restart.
- Copied installer files are compared by checksum, so damage that keeps a file's size is found before the restart.
- Downloads retry once when antivirus or a work network breaks the certificate revocation check. A web page saved as an ISO no longer gets reused for systems with no checksum.
- A missing EFI shell on an Arch ISO is found before the disk changes, and an empty card reader's letter is no longer used for the EFI partition.
- After keeping Linux and removing the installer, Mint and Zorin PCs no longer get a false "earlier attempt" screen.
- Closing hop can't freeze while a bug report is being made, messages name the real Windows drive, and bug reports keep the partition table when a drive can't be measured.

## 0.3.0 - 2026-11-01

### Added

- **Replace Windows, where hop has seen it work.** For Ubuntu, Xubuntu, Ubuntu Budgie, Ubuntu Cinnamon, Edubuntu, Ubuntu Studio, Zorin OS, Fedora Workstation, Ultramarine,
  elementary OS, Debian, Arch and Omarchy, hop can set up an installer
  that erases the whole disk Windows is on. It's the last row of the drive list, is never chosen for you, and shows the disk,
  its size and every drive on it that would go, then asks you to type ERASE. hop itself still only makes the
  installer: the Linux installer does the erasing, when you tell it to. Undo works until then.
  It needs enough memory to hold the ISO with 4 GB left over, and says so if there isn't.
- Omarchy 4.0, next to Windows. Its 6 GB file doesn't fit on the installer partition, so hop makes a second one for it. It needs Secure Boot off, and
  BitLocker fully off on its disk, because its installer refuses even a paused one. hop checks before the download and won't turn it off for you. A full install
  and restart worked in a virtual PC. Afterwards the PC starts Omarchy, and its menu doesn't list Windows until you add it. Later versions of Omarchy
  are refused until they've been tried.
- Omarchy, Fedora, Ultramarine and Arch on a second disk. A full install and restart worked in a virtual PC for each. The first three make their own EFI partition there, and use the largest free space on that disk, which can be more than hop set aside. Arch uses Windows' EFI partition. Fedora, Ultramarine and Arch ran with an unattended config, so their screens are still unclicked.
- Zorin OS, Debian, Fedora Workstation, Ultramarine, CachyOS and Arch Linux. CachyOS and Arch need Secure
  Boot off, as they say when picked, and Arch installs from a text prompt.
- Fedora and Ultramarine no longer need a command typed in Terminal. Their installer can now use the drive
  by itself, with Secure Boot on. Automated installs into free space finished and started again in a virtual
  PC, though the installer's graphical screens haven't been clicked through yet.
- hop checks the EFI partition has about 20 MB more room for Arch, whose GRUB files go there, before changing the disk. Fedora and Ultramarine on a second disk no longer need it, as they make their own.
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

- **Linux Mint Cinnamon, Xfce and MATE and Zorin OS are back next to Windows, through a partition hop makes first,** after a full install and restart in a virtual PC for each. They stay refused on a second disk. Its installer replaces the fallback loader `\EFI\Boot\bootx64.efi` on Windows' EFI partition.
- **hop's steps for Zorin OS and Linux Mint were wrong in earlier builds.** Their installer, started from the disk it's installing to, says it can't make partitions there and doesn't offer to install alongside Windows. The steps above replace them.
- **The Ready screen could hide its buttons.** Omarchy's and Arch's steps ran over Undo changes, Restart now and Later, so they couldn't be seen or clicked. Long lists now stop above the buttons and scroll, with the wheel, the keyboard or a thin bar.
- Clicking something while hop was checking the PC could start two things at once, and let hop be closed in the middle of changing the disk. Nothing can be clicked during those checks now.
- After a failed install, Choose and Make room kept showing the old log in place of the drive.
- If Windows didn't restart when asked, the buttons stayed greyed out for good. After a minute hop now says so and they come back.
- Cancel could stop an unrelated program, if it had been given the number the finished download had.
- "Choose another drive" could crash hop on a PC with one drive. It's gone when there's no other drive.
- hop refused to close during checks that only read the PC, saying it was changing the disk. It closes now. When it really is changing the disk, that message stays on screen.
- Labels in the drive bar were cut to "1 GB used ·…", "Wind…" or vanished on big drives, and the stuck bar's mark could land on them. The mark was also in the wrong place when there was free space after the drive.
- Long disk names and restore-point file names ran over each other or off the screen.
- The bar always drew an 8 GB installer even for your own ISO, and on a very small space its labels went off the left edge.
- The window could be taller than the screen, as at 1920×1080 with 200% scaling, which put its buttons out of reach.
- Holding Enter on Install went straight through the confirmation and started.
- A stuck drive said "Windows can release 0 GB" when Windows could release a little and hop's reserve took it. It now says what hop can use.
- **hop's folder in `%ProgramData%` wasn't protected, though hop trusts what's in it.** Any user could leave files there that hop, running as administrator, would then act on, including settings it writes at startup and a partition for Clean up to delete. hop now makes the folder so that only administrators and SYSTEM can write there. It takes over the folder an older build left, keeps what's in it, and moves anything an ordinary user could have put there to a folder named `hop-moved-...`. With UAC turned off, the older folder itself is moved, so Undo goes by partition labels instead of the state file.
- **Clean up could delete a Linux partition.** A recorded partition it couldn't read, or whose file system Windows didn't know, counted as unfinished. Now it has to be unformatted, with nothing written at its start, and not marked as Linux.
- **Make room's safety net went before the settings were back.** A failed shrink, or hop being stopped part way, could leave hibernation and the paging file off with nothing to bring them back. The tasks and the file now go only once everything is back. What didn't go back is tried again by the task and when hop next opens, up to 8 times, and hop still opens.
- A second Make room that restarted the PC, run from the copy the tasks use, set its tasks on a folder Windows deleted as it started.
- A damaged Make room file made the safety net remove itself, and starting again lost the original settings. It's now kept, and hop says what to do.
- One startup entry the firmware refused stopped Undo part way.
- Restart now could say the EFI partition was too full, counting the copy of the boot loader it was about to replace.
- A disk with no partitions could stop hop opening, or Undo finishing.
- Moving files had 15 minutes for each try rather than for them all, and asking Windows how far a drive shrinks had no limit, while hop couldn't be closed. If Windows cancels every try, the log now says nothing moved.
- A problem reading the copy's progress undid the install while the copy was still writing.
- A crash just after shrinking the drive, or just after making a partition, left no record of it for Undo.
- If Windows refused a restart, the one-time start stayed set for whichever restart came next.
- Opening hop while the safety net was running could crash before hop could say anything. The safety net also now stops after 5 minutes, so it can't keep hop locked.
- Removing another Linux's EFI partition no longer runs diskpart from a script in the temp folder.
- Removing Omarchy left its `Limine` startup entry and its EFI partition behind, because hop didn't count its boot loader as a Linux one.
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
- If hop gave up turning hibernation or the paging file back on, only the log said so. It now tells you before the next install.
- If Windows refused a restart, hop could later say the installer hadn't started, when the PC had never restarted.

### Changed

- **Stuck space no longer looks like an error.** A drive with free space Windows can't release yet shows how much is free,
  the mark it can't shrink past and the file in the way, with Make room as the next step. The Make room screen now says how
  much is stuck, and moving files has its own screen.
- The size slider starts at what the chosen system needs, so Omarchy's starts at 33 GB.
- Make room works on the chosen drive. Other drives usually need no restart.
- The steps for the Linux installer now depend on where Linux is going. They use the manual option if the
  easy one would pick different free space.
- Undo gives space back to the drive it came from, and clean-up finds hop's partitions on any internal disk.
- Debian, CachyOS, Linux Mint and Zorin OS can't go on a second disk for now, because none has finished an install there.
  hop says so before anything changes.

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
