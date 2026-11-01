# Troubleshooting

## Replacing Windows

**Can't replace Windows, not enough memory.** The installer has to copy itself into memory before it can
erase the disk it started from. hop checks this before anything changes. Install next to Windows instead,
or add memory.

**"This PC has more than one disk called..."** The Linux installer's list would show those two disks the same, and hop
can't give you anything else to tell them apart by. Disconnect the other one first, or install next to Windows.

**The warning says something will stop starting.** That system keeps its startup files on the EFI partition of the disk
being erased. Its files on another disk stay, but it won't start until it's repaired, using that system's own recovery tools.

**The Linux installer says the disk is in use, or doesn't offer to erase it.** Don't force it. Turn the PC off
and on: Windows is still there, because nothing has been erased, and **Undo changes** in hop still works.

**You came back to Windows without erasing.** Nothing has changed. hop treats it like any other install
that came back: try again, or undo.

If you need more help, click **Report this on GitHub**. It copies a report, with no serial numbers or names, and opens a new issue to paste it into. Nothing is sent by itself. Logs are in
`C:\ProgramData\hop\logs`.

## The PC went back to Windows after restarting

Reopen hop. It shows what to try for your PC, and leads with the boot menu if the firmware ignored
hop's request. In short:

1. **Pick it by hand.** Restart and keep tapping the boot menu key as the PC powers on, then choose the
   entry ending in **(hop)**.
2. **Turn off Secure Boot.** Click **Open BIOS** in hop, find **Secure Boot** (usually under Security or
   Boot), set it to **Disabled**, then save and exit.

| Maker | Boot menu key |
| --- | --- |
| MSI | F11 |
| ASUS | F8 |
| HP | F9 |
| Acer, Dell, Lenovo, Gigabyte, Toshiba, Razer | F12 |

If the entry isn't listed, your firmware removed it, and clicking **Restart now** in hop adds it again.

## A black screen when the installer or Linux starts

It's usually the graphics driver, most often on NVIDIA laptops. Wait a couple of minutes first, because the first start can be slow. Windows hasn't been touched, so holding the power button is safe.

1. Start the installer again, and hold **Shift** or tap **Esc** as it starts if no menu appears.
2. Choose **Safe graphics** or **Compatibility mode** if the menu has it.
3. Otherwise highlight the first entry and press **e**. On the line starting with `linux`, add `nomodeset` before the `---` or at the end, then press **Ctrl+X** or **F10**.

If the installed Linux has the same problem, do the same in its boot menu, then install your graphics driver from inside Linux. To get to Windows meanwhile, use the PC's boot menu key and choose **Windows Boot Manager**.

## "Secure Boot doesn't trust this ISO's boot loader"

Your PC's list of trusted certificates doesn't include the one that signed this system's boot loader.
Some PCs, including Secured-core ones, come with Microsoft's third-party certificate turned off. In the
BIOS it's called something like **Allow Microsoft 3rd Party UEFI CA**, under Secure Boot. Newer PCs may
only have the 2023 certificate, and today's ISOs are signed with the 2011 one. In either case, turning
off Secure Boot works.

## "Verifying shim SBAT data failed: Security Policy Violation"

The PC has blocked this boot loader as out of date. This can happen with an older ISO, or one that uses
an older shim. Use a newer ISO, or turn off Secure Boot.

## The installer doesn't offer to install alongside Windows

Ubuntu 24.04's installer is [reported](https://bugs.launchpad.net/ubuntu-desktop-provision/+bug/2068915)
to ask for BitLocker to be turned off before offering this. If yours does, use the manual option hop
lists, or turn off BitLocker first.

## A partition called writable, or Linux "installed" when it isn't

Builds up to 0.2.0 let Ubuntu's live system make a partition for its logs, and it could take all the space hop set aside
for Linux. The installer then said there wasn't room, and hop said Linux was installed. It happens when nothing comes
after that space on the disk. Open this build of hop: if it was this setup's doing, **Undo changes** and **Restart now** both
remove it. If hop can't be sure, it leaves it, and it shows up as another Linux that hop offers to remove. Check it's
not yours first.

## A different installer started

GRUB starts the first partition it finds with a Linux installer on it. Unplug any USB installers, and
delete other tools' installer partitions in Disk Management if you don't need them. hop warns about these.

## The installer can't see the drive

The drive is probably in RAID or Intel RST mode. Linux needs AHCI, set in the BIOS. **Don't just switch
it:** Windows may stop starting until it's prepared. Search for the steps for your PC first.

## hop won't use a drive

Choose the drive and hop says why. The usual reasons:

- **USB, removable or network drive.** Linux has to go on a disk inside the PC. The download can still go there.
- **Can be unplugged, or hop can't tell.** A Thunderbolt or USB4 drive looks like an internal NVMe drive, so hop
  asks Windows whether it expects the drive to be unplugged. A disk inside the PC is refused too if its port has
  hot-plug turned on in the BIOS settings. Turning that off, then restarting, lets hop use it.
- **Not set up, or MBR.** A new disk needs setting up as GPT in Disk Management. Converting an MBR disk
  that holds files means erasing it first, so copy them off.
- **RAID or dynamic.** Linux installers can't use these. Leave them to their own tools.
- **Locked with BitLocker.** Unlock it in File Explorer and open hop again. An unlocked drive can be shrunk.
- **Not NTFS.** Windows can only shrink NTFS drives. Free space next to one is still offered.
- **Another system on the disk.** hop leaves a disk with another Windows or Linux alone.
- **Windows' recovery files are there.** Moving them is beyond hop. Use another drive.

## The PC stops at a grub> prompt, with Linux on a second drive

The PC's firmware didn't start the second drive before GRUB looked for the installer. Fast Boot is the usual
reason. Hold the power button to turn it off, and the PC goes back to Windows. Click **Open BIOS** in hop, turn
off **Fast Boot** (sometimes **Ultra Fast Boot**), and click **Try again**.

If this happens later, after Linux is installed, it's the same cause. Windows still starts from the boot menu key.

## Which drive should Linux go on?

Any that hop offers works the same way. Free space on a second disk changes nothing else, and so is the
easiest to undo. A second disk also means Linux keeps working if Windows is reinstalled. An SSD will be much
faster than a hard drive.

## C: has free space, but hop can't use it

If another drive has room, hop suggests it, and that's quicker than what follows.

Windows can only shrink C: down to the last file it can't move, wherever that sits on the drive. So a
drive with hundreds of GB free can still give up very little, and deleting files won't help. Hibernation,
paging and restore point files are the usual cause. The same applies to "Windows could not shrink C: that far".

Click **Make room** and hop clears the usual causes. It turns off hibernation and the paging file, clears the
change journal, restarts, moves what it can, and turns them back on once Linux has its space or you close hop.
hop opens again by itself after the restart, without asking. If you close it some other way, or never get back to it, Windows
turns them back on by itself about 20 minutes after it starts. The paging file returns at the next restart.
It asks first if restore points are in the way, because deleting those can't be undone.

hop also moves NTFS system files that Windows' defrag leaves behind, such as `$Mft::$BITMAP`. If it still can't release
enough, hop says what's in the way. Choose another drive or a second disk, or a smaller size if there's enough for one.

If Windows doesn't restart, something else stopped it. After a minute hop says so. Click **Restart now**, or **Back**
to put its settings back. If the drive isn't there after the restart, hop puts them back and opens as usual.

On another drive there's less to do. hop clears the change journal and moves files without restarting, unless
that drive has its own paging file.

## Windows asks for a BitLocker recovery key

hop pauses BitLocker for three restarts, but changes to startup can still trigger this. The key is at
[account.microsoft.com/devices/recoverykey](https://account.microsoft.com/devices/recoverykey). Get it
**before** you start.

## The firmware keeps removing the startup entry

Some firmwares reset their boot list. On Lenovo PCs, turn off **Boot Order Lock** in the BIOS. hop adds the
entry back each time you click **Restart now**.

## The Windows drive is read-only in Linux

Windows may be hibernating, and laptops can do that by themselves. Restart Windows fully, not shut down or
sleep, and then open the drive in Linux. Don't force it to mount: that can damage your files.

## The clock is wrong after switching systems

Windows and Linux read the PC's clock differently. In Linux, run `timedatectl set-local-rtc 1`.

## A Windows recovery update fails

Windows keeps its recovery partition straight after C:, and hop puts Linux after C: too. If an update fails
with event 4502 because that partition is too small, Windows can't grow it past Linux. Microsoft's steps are
in [KB5028997](https://support.microsoft.com/en-us/topic/kb5028997-instructions-to-manually-resize-your-partition-to-install-the-winre-update-400faa27-9343-461c-ada9-24c8229763bf).

## Windows doesn't appear in the Linux boot menu

Start Windows from the firmware's boot menu key, then in Linux run `sudo update-grub`. Some systems
also need `GRUB_DISABLE_OS_PROBER=false` in `/etc/default/grub` first.

## How to undo everything

Open hop and click **Undo changes**:

- **Linux isn't installed yet:** removes everything hop made and gives the space back to the drive it came from.
- **Linux is installed:** removes only the installer. Linux stays.

To remove an installed Linux, open hop again. It offers to remove it and free the space. On a second disk, it
only offers this for a Linux that hop put there. So a disk of your own Linux files is never offered for removal.

If you unplugged a drive hop was using, plug it back in before you undo.
