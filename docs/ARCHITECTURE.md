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

Four things limit what it can install:

- **FAT32 can't hold a file of 4 GB or more,** which rules out Kubuntu's ISO. Omarchy's has the same problem,
  with a 6.1 GB `airootfs.sfs`, and gets a second partition. See [Omarchy](#omarchy).
- **The firmware has to start it.** Many firmwares only start files from the EFI system partition, so
  the ISO's signed boot loader is copied to `\EFI\hop` there. It then has to find the installer partition,
  and how it does that depends on the system.
- **The live system has to find itself.** Ubuntu's `casper` and Debian's `live-boot` search every
  partition, so they find it. Fedora's `dracut` and Arch's `archiso` look for a specific label or disc
  stamp, so `Update-BootConfig` changes the copy of their boot menu to name `HOPINSTALL`.
- **The live system mustn't take the space.** Left alone, `casper` makes a partition in it. See
  [Casper and the free space](#casper-and-the-free-space).

## Two languages, one exe

| | |
| --- | --- |
| `src/` (C#, WinForms on .NET Framework 4.8) | The window, plus what PowerShell can't do well: UEFI variables (`Firmware.cs`) and raw disk reads (`DiskProbe.cs`), and the copy of hop that comes back after a restart (`RestartCopy.cs`) |
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
| `FullDisk.ps1` | Replacing Windows: whether it can be done, the warning's facts, the steps |
| `Disk.ps1` | Plans the space, makes partitions, copies files |
| `Boot.ps1` | The copied boot menu, the EFI partition and the startup entry |
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
| Second installer partition (Omarchy) | After the installer | Label `HOPLIVE` |
| Linux partitions (`prepared` systems) | After the installer | Labels `LINUXBOOT`, `LINUXROOT` |
| Boot loader copy | `\EFI\hop` on Windows' EFI partition | Fixed path |
| Startup entry | UEFI variables | `(hop)` in its name |
| ISO | Downloads, or `\hop` on another drive | Named in the log |
| State and logs | `C:\ProgramData\hop` | Fixed path |
| Which disks hold Linux hop put there | `C:\ProgramData\hop\linux-disks.json` | Fixed path |
| What Make room changed, until it's put back | `C:\ProgramData\hop\make-room.json` | Fixed path |
| Scheduled tasks, while Make room is under way | `hop resume`, to come back after its restart, and `hop restore settings`, in case hop doesn't open again | Fixed names |
| The copy of hop those tasks start | `%ProgramData%\hop-restart-*`, which it removes itself | Fixed pattern |
| Casper's partition, only from builds up to 0.2.0 | The end of the disk | See [Casper and the free space](#casper-and-the-free-space) |

Clean-up works from these, not just the state file, so it works after a crash. It looks for labels on
the Windows disk and every internal disk. USB drives are skipped, because they could be from another PC,
and off the Windows disk the format has to match as well as the label. Builds named LinuxHop used
`LINUXHOP`, `\EFI\linuxhop` and `(LinuxHop)`, which are still recognised.

A label isn't enough on its own, because anyone can name a drive. A partition the state file recorded is hop's.
Otherwise it has to look as hop leaves it: empty apart from what Windows puts on every drive, or for the installer,
holding `EFI`. Clean up lists what it will delete first, with its size and drive.

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

Other systems differ in steps 2, 3 and 5. The catalog holds what differs (`Live`, `BootConfigs`,
`BootEdits`, `GrubDir`, `EspShell`), so a similar system is one entry. Read from the October 2026 ISOs:

| System | Boot loader, signed by | How it finds the installer partition | How the live system finds itself |
| --- | --- | --- | --- |
| Zorin OS 18.1 | shim and GRUB, Microsoft and Canonical | `/.disk/info` | `casper` searches |
| Debian 13 | shim and GRUB, Microsoft and Debian | `/.disk/info` | `live-boot` searches |
| Fedora 44, Ultramarine 44 | shim and GRUB, Microsoft and Fedora | `grub.cfg` next to GRUB, by label | `root=live:LABEL=HOPINSTALL` |
| CachyOS | GRUB, unsigned | Its own built-in config, by a marker file | `archisolabel=HOPINSTALL` |
| Arch Linux | systemd-boot, unsigned | See below | `archisolabel=HOPINSTALL` |
| Omarchy 4.0 | GRUB, unsigned | Its own built-in config, by a marker file | `archisolabel=HOPLIVE`. See [Omarchy](#omarchy) |

Fedora's and Ultramarine's installer, Anaconda, protects the whole disk behind `/run/initramfs/live`,
and so refuses the disk holding the installer partition. So `Get-DracutBoot` adds kernel arguments that
have systemd run `umount -l /run/initramfs/live` as it starts:

| Argument | Why |
| --- | --- |
| `"systemd.run=..."` | The command. Quoted so GRUB keeps it as one argument |
| `systemd.run_success_action=none`, `systemd.run_failure_action=none` | Otherwise the PC turns off once it has run |
| `systemd.unit=graphical.target` | `systemd.run` points the default target at itself, which would mean no desktop |
| `systemd.wants=kernel-command-line.service` | Naming a target drops the command, so this adds it back |

The alternatives were worse. `rd.live.ram=1` doesn't help: it copies 2.5 GB to memory and leaves the
partition mounted. [Dracut never unmounts it](https://github.com/dracut-ng/dracut-ng/blob/main/modules.d/70dmsquash-live/dmsquash-live-root.sh),
and a test showed the same. A second initrd would have to be built on Windows. The live system still reads
its image from the partition after this, so the partition stays busy, read-only, and must stay in place.

**The EFI partition has to have room, because Anaconda doesn't check.** It warns about anything under 500 MB
but carries on, and reuses Windows' partition. It adds 21 MB. With too little room it still says `Complete!`
and exits 0, but leaves no `shimx64.efi`, so the PC starts hop's entry and the live system again. So
`EspLinuxMB` adds 25 MB to what `Assert-EspRoom` asks for before the disk changes.

What was tested, in QEMU with a 100 MB EFI partition and no real Windows, November 2026: Fedora 44 and
Ultramarine 44 installed into free space and started from the disk with Secure Boot on, and the NTFS and
installer partitions came through byte for byte. Anaconda was driven by a kickstart using its default
layout, which is 2 GB of ext4 `/boot` and btrfs for the rest. **The graphical installer itself wasn't
clicked through, so "Share disk" wasn't run.** See [Testing](TESTING.md).

Anaconda also renames the EFI partition's GPT name to `EFI System Partition`, and puts its entry first in the
firmware's boot order. Neither changes the files Windows has there.

The edits only touch the copy on the installer partition. Shim checks the signatures of programs, not of
GRUB's config, so a changed menu still starts with Secure Boot on. This was seen with Ubuntu's menu: with Secure
Boot on, the kernel's line had the new word in it.

Arch is the odd one. systemd-boot only reads its menu and kernels from its own partition, and they
need 270 MB, which Windows' EFI partition doesn't have. So `\EFI\hop\BOOTX64.EFI` is the EFI Shell from
Arch's ISO, whose `startup.nsh` finds the installer partition and starts systemd-boot there.

A problem from step 3 onwards stops at GRUB or the Linux console. **Coming straight back to Windows
means step 1 or 2 failed, or the firmware never tried:** firmware moves on to the next startup entry
when a loader is refused or exits. Firmware clears `BootNext` as it starts, so one still set after
coming back means it never tried, which is what `Test-BootNextIgnored` looks for.

## Omarchy

Omarchy's 4.0.6 ISO had three things in the way. Each was tried on the real ISO. See [Testing](TESTING.md).

**A 6.1 GB file.** `Read-Iso` keeps the catalog's `LiveFiles` apart. They go on a second partition straight after the
installer, formatted exFAT and labelled `HOPLIVE`, and the rest goes on FAT32 as ever. GRUB only needs FAT32, for the
kernel and initramfs. Archiso only needs the second partition, which `archisolabel=HOPLIVE` names. Its initramfs has
`exfat` and `ntfs3` modules, and both were seen working. exFAT was chosen because hop already formats `LINUXROOT` that way.

**A disk it won't offer.** `disk_form` in `/root/configurator` leaves out the disk behind `/run/archiso/bootmnt`. Both ways round
this worked:

| | `systemd.run=umount -l` | `copytoram` |
| --- | --- | --- |
| The disk is offered | Yes: the mount point has gone | Yes: archiso unmounts it |
| Memory | Worked at 8 GB | Copies 5.8 GB to a tmpfs limited to 75% of memory. Worked at 12 GB |
| Disk busy | Yes, the image is still read from `HOPLIVE` | No: `blockdev --rereadpt` works |

hop uses the first, as it does for Fedora, because the second would rule out PCs with 8 GB. Omarchy adds its partitions
one at a time, which a busy disk allows. So **hop has taken away what stopped Full disk install reaching this disk.** It's where
the cursor starts on that screen, so the steps warn about it, and it still asks for confirmation. With this route it's also
erasing the image it's running from, unless it was copied to memory. So replacing Windows with Omarchy adds `copytoram` to the same
menu, and that was seen working at the ISO plus 4 GB of memory: see docs/TESTING.md.

**BitLocker.** `run_partition_decide`, which only Free space install runs, reads each partition on the disk for `-FVE-FS-`, and stops if it finds one. Full disk install doesn't look, so hop doesn't refuse BitLocker when replacing Windows. That mark stays
until the drive has finished decrypting, so hop's pause doesn't help. `Assert-NoBitLocker` makes the same check before the download,
and refuses in plain words. Turning it off is the owner's choice, and it can take hours. A partition hop can't read counts as refused.

**The EFI partition doesn't matter here.** Omarchy never uses Windows' for itself: it always makes its own 2 GB one, `OMARCHY_EFI`, then
`OMARCHY_ROOT`, in the largest free space on the disk, and needs 32 GB of that, which `MinGB` turns into 33 for rounding. Limine goes on its
own partition and comes first in the firmware's boot order. Two things to know:

- **Its menu doesn't list Windows.** That's what Omarchy's manual says, with `limine-scan` to add it. Until then Windows is in the
  firmware's boot menu. The note under the steps says so, since hop's own cleanup is in Windows.
- **Starting it writes one thing to Windows' EFI partition.** `\loader\random-seed`, 32 bytes, appeared there on the first start. Nothing in the
  journal mounted that partition, so it looks to come from before the kernel, though what wrote it wasn't pinned down. Windows' own files were
  unchanged. Undo doesn't remove it.

**4.5 will need looking at again.** Omarchy's source after 4.0.6 installs from `arch/x86_64/omarchy-root.img.zst`, under `/run/archiso/bootmnt`,
which neither route above leaves there. So `Resolve-Download` only takes 4.0 and `Read-Iso` refuses an ISO with that file. **When omarchy.org
moves on, hop stops offering a download until it's tried again**, which the weekly catalog check will show.

**Installing Arch first, then Omarchy, isn't an option.** Its online installer was removed in June 2026. `omarchy.org/install` now prints that
it installs from its ISO.

## Casper and the free space

When casper finds itself on a partition, `check_dev` in its `scripts/casper` calls
`find_or_create_persistent_partition` from `scripts/casper-helpers` on that partition's disk. Unless a partition
called `writable` already exists, that one:

1. Takes the highest end of any partition on the disk, and goes to the next multiple of 4096 sectors.
2. Stops if less than 100 MiB is left after that.
3. Adds a partition there with `sfdisk -a`, up to the end of the disk, of the type Linux filesystem.
4. Runs `mkfs.ext4 -L writable` on it. With no partition node yet, this fails and leaves an empty partition.

`setup_auto_log_persistence` then mounts it, on `/var/log` and `/var/crash`. On a USB stick that's a good use of
spare space. Here, **if nothing comes after hop's free space, it's all of it,** and the installer is left with
what's between its partition and the next multiple of 4096 sectors, about 1 MiB. So what happens depends on the disk:

| What's after hop's free space | What casper does |
| --- | --- |
| Nothing | Takes all of it. An install into free space then fails, out of room in a 1 MiB partition |
| A partition, right up to the end of the disk, as Windows' recovery partition usually is | Nothing |
| A partition, then 100 MiB or more | Takes that last bit. hop's space is fine, but the partition is left behind |

**The fix is one word.** `nopersistent` makes `check_dev` and `setup_auto_log_persistence` both do nothing.
`Get-CasperBoot` adds it to the copy of the menu, for each entry in the catalog that uses casper and for a chosen ISO.
It goes straight after the kernel's path, before `---` or `--`, so that the installed system doesn't get it.
`toram` already implies it, which is why this never showed up when replacing Windows. The live system's logs then stay in memory.

`Register-Installer` makes the same edit when the installer is restarted, for an installer partition that an older build copied.

**Where it's already happened,** the partition looks like Linux to Windows, and older builds took it for that. They
said Linux was installed and Undo left it behind. Now `Get-CasperPartition` recognises it, so hop doesn't say that. Undo
and Restart now remove it. A partition called `writable` could be anyone's, so all of this has to hold:

- hop did restart into this setup's installer (`RestartedAt`).
- It's new since the setup began (`LinuxBefore`), after the installer partition, on that disk, and the last on it.
- It starts on exactly the sector casper would pick, with casper's partition type.
- Its superblock says ext and `writable`, or its first 128 KB are all zero, for when `mkfs.ext4` failed.

With no state file, or a Linux installed as well, it isn't removed. In the first case hop offers it as another Linux, on the
Windows disk. In the second, Windows can't see whether that Linux is using it. A failed `mkfs` over old data
on a real disk won't look empty either, so that one still counts as Linux.

## Where Linux can go

`Get-DriveBlocker` in `Drives.ps1` is the one place that decides, and it gives the reason.

| | Viable |
| --- | --- |
| A disk | NVMe, SATA, SAS, ATA or SCSI, and not one Windows expects to be unplugged. GPT and basic, online, writable and healthy. Not RAID, and with no other Windows or Linux on it |
| A volume to shrink | All of that, plus: an ordinary data partition with a letter, NTFS, healthy, unlocked, not part way through encrypting, and not holding Windows' recovery files |
| Free space | Any free space on such a disk, unless it's right after a volume that can use it |

**A Thunderbolt or USB4 NVMe enclosure reports the bus type NVMe**, so the bus can't tell it from a drive inside
the PC. `Get-DiskAttachment` asks Windows instead, through [the device's removal
policy](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/devpkey-device-removalpolicy), found from
`Win32_DiskDrive.PNPDeviceID`. 1 means Windows expects no removal, and that has to hold for the disk and for each
parent up the device tree, since it's the slot the drive is tunnelled through that's hot-pluggable. Any other value,
or `MediaType` saying external or removable, refuses the disk. So does not getting an answer about the disk itself.
Internal disks on a port with hot-plug turned on are refused as well, which is the safe mistake to make.
**This hasn't been tried on real Thunderbolt hardware.**

Clean-up still looks at these disks, because `Get-HopDisks` only goes by the bus. A setup made on one by an earlier
build can still be undone.

The Windows disk keeps the checks it has always had, so C: is still judged by them and nothing else.
RST mode there only gets a warning. A volume on that disk gets the volume checks too.

Paging files and restore points don't refuse a drive, because they only limit how far it shrinks. That's
what Make room is for. Working that limit out can take minutes on a big drive, so the list estimates from
free space and hop asks Windows once a drive is chosen, with a limit of five minutes.

Make room needs less on another drive. It has no hibernation file, and usually no paging file. So hop clears
the change journal and moves files, with the same 15 minute limit, and restarts only if that drive has a
paging file of its own. A paging file left to "Windows chooses" isn't touched, because hop can't tell where
it will go next.

All of this is saved in one file, so a second drive puts back what the first run changed before it starts. Closing hop
during the download stops the install first, because the install holds the engine. Windows asks hop's window before the
restart: hop lets that through without restoring anything, since Make room carries on afterwards. If nothing has
happened after a minute, it says so and offers to restart again or put the settings back.

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
| Linux Mint, Zorin OS: **refused**, see [Testing](TESTING.md) ([partman-efi](https://github.com/linuxmint/ubiquity/blob/master/d-i/source/partman-efi/fstab.d/efi), [bug](https://bugs.launchpad.net/bugs/1396379)) | The first one it finds, whatever the list says. Usually Windows' | Leave the list alone |
| Lubuntu (Calamares) | The existing one it's told to use | Its existing step, which is Windows' |
| elementary OS, Pop!_OS ([distinst](https://github.com/pop-os/distinst/blob/master/src/installer/steps/bootloader.rs)) | Whichever is mounted at `/boot/efi`, which is hop's `LINUXBOOT` on the target disk. The startup entry points at it | The same steps as ever |
| Omarchy | Its own new one, on the disk it's given, in that disk's largest free space. Seen in a virtual PC: see [Testing](TESTING.md) | Choose the second disk, and expect it to say more than hop set aside |
| Fedora, Ultramarine | Their own new one, on the one drive selected, with a new `/boot` and root in its largest free space. Seen with a kickstart: see [Testing](TESTING.md) | Select only the second disk. The usual warning about Windows' small EFI partition doesn't apply |
| Arch (archinstall) | The existing one it's told to use, on any disk it was told about. Seen with a config file: see [Testing](TESTING.md) | Choose both disks, and use Windows' |
| Debian, CachyOS | Not known | **Refused** by `Assert-SystemFitsDrive`. Their steps are written for Windows' disk, and name its EFI partition or the drive with the free space. Not yet shown on a second disk |

**The easy option isn't used for a second disk.** Ubuntu's [picks the largest free space on any
disk](https://github.com/canonical/ubuntu-desktop-provision/blob/main/apps/ubuntu_bootstrap/lib/pages/storage/guided_resize/guided_resize_model.dart),
and [skips a disk](https://github.com/canonical/subiquity/blob/main/subiquity/server/controllers/storage.py)
whose only partition is the running installer. Mint's takes the biggest free space it finds. On the Windows
disk hop still suggests it, unless other free space is as big as Linux's, which `Test-AlongsideFindsLinux`
checks once the partitions exist.

None of this has been started on real hardware. Omarchy, Fedora, Ultramarine and Arch were seen in a virtual PC, as their
rows say. The rest comes from reading those installers' source. See [Testing](TESTING.md).

## Replacing Windows

**hop never erases anything here.** It makes the same installer partition as ever, plus the same startup
entry. The Linux installer erases the disk, if someone chooses that in it, and until then Windows is untouched.
Undo, coming back and clean-up all work as they do for any other install, because to them it is one. The
state file just says `FullDisk`, which changes the steps and nothing else.

**The problem is that the installer starts from the disk it would erase.** Live systems keep their
medium mounted, which holds the disk open: the kernel refuses to reread its partition table, and installers
refuse or hide it. So the live system has to copy itself to memory first, and each family has its own word:

| Family | Word | Seen after booting with it |
| --- | --- | --- |
| casper (Ubuntu, Zorin OS, Lubuntu) | `toram` | `/cdrom` is a tmpfs, nothing on the disk is open, and it can be repartitioned |
| live-boot (Debian) | `toram` | Same, at `/run/live/medium` |
| archiso (Arch) | `copytoram` | Same, with the image in `/run/archiso/copytoram` |
| dracut (Fedora) | `rd.live.ram=1` | The image is copied, **but the partition stays mounted at `/run/initramfs/live`, and the disk stays busy until that's unmounted** |

The word goes in through the mechanism every other boot change uses: `Update-BootConfig -FullDisk` adds the
entry's `FullDisk.Edits` to the copy on the installer partition. It goes straight after the kernel's path, so
before casper's `---`, and what's after that isn't copied into the installed system. `Test-BootConfigKnown` checks
the ISO's menu can take it before the disk changes, and `Test-FullDiskConfig` checks it's really there afterwards.

**A catalog setting decides who's offered this.** `FullDisk` is only set for a system that was really seen
erasing the disk it started from and then starting from that disk. See [Testing](TESTING.md). A
chosen ISO is never offered it.

**Memory is checked twice**, because too little only shows after the restart. Ubuntu's 6 GB ISO, in a virtual PC
with 7 GB, copied itself and then didn't reach a login in seven minutes. It needs the ISO's size plus
`$FullDiskMemoryRoom`, 4 GB. First against the catalog's `IsoGB`, before the download, then against the real
ISO, before the disk changes.

**The installer partition goes on Windows' disk**, on the chosen drive if it's there and next to C: if not. Other
reasons for refusing are in `Get-FullDiskBlocker`: a RAID disk, a disk too small for Linux, and Windows starting
from another disk's EFI partition, which hop hasn't tried and wouldn't be erased, and **another disk with the
same name and size**. hop can only name a disk by those in the steps, and the installer's list would show two the same.

**Other systems can start from this disk's EFI partition.** Linux Mint's installer leaves its loader there even for
Linux on another disk, and a second Windows can share it. `Get-SystemsOnWindowsEsp` looks at the folders there, the
startup entries and Windows' own boot menu, and the warning and the ERASE screen name each as stopping. If it can't look,
hop refuses, because the alternative is promising other disks are safe without knowing.

**Screens, none of which changes anything until the last.** The last row of the drive list, then a check that can
only read, then the warning with the disk, its size, what's on it and what stays, then typing ERASE. Back and
Cancel go back to choosing, and only that last screen sets `fullDisk`, which `ShowChoose` clears.

## Removing another Linux

A startup entry only says which partition and file it starts, and Windows' EFI partition can hold loaders for several
systems. So `Find-OtherSystem` ties an entry there to the Linux being removed only if there's no other Linux it could
belong to, or if the small `grub.cfg` next to it names the file system of a partition being removed. Anything else
stays, with its name in `Kept`, and the screen says so. A leftover entry is much easier to fix than another system's.

## Why the startup entry is written directly

`bcdedit` can only make Windows Boot Manager objects, and the firmware's one-time boot can't use those.
`Firmware.cs` writes `Boot####` and `BootNext` itself, as `efibootmgr` does on Linux.

## Why partitions are identified by signature

To Windows, an ext4 partition and a locked BitLocker drive look the same: unreadable, with no letter.
`DiskProbe.cs` reads the first bytes of the partition, so hop only offers to remove what it can
positively identify as Linux.
