# Troubleshooting

If you need more help, open an issue and paste the report from **Copy a bug report**. Logs are in
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

## A different installer started

GRUB starts the first partition it finds with a Linux installer on it. Unplug any USB installers, and
delete other tools' installer partitions in Disk Management if you don't need them. hop warns about these.

## The installer can't see the drive

The drive is probably in RAID or Intel RST mode. Linux needs AHCI, set in the BIOS. **Don't just switch
it:** Windows may stop starting until it's prepared. Search for the steps for your PC first.

## "Windows could not shrink C: that far"

Hibernation, paging and restore point files can't be moved, so they limit the shrink. Try a smaller
size, then in an administrator terminal run `powercfg /h off`, restart, and try again.

## Windows asks for a BitLocker recovery key

hop pauses BitLocker for three restarts, but changes to startup can still trigger this. The key is at
[account.microsoft.com/devices/recoverykey](https://account.microsoft.com/devices/recoverykey). Get it
**before** you start.

## Windows doesn't appear in the Linux boot menu

Start Windows from the firmware's boot menu key, then in Linux run `sudo update-grub`. Some systems
also need `GRUB_DISABLE_OS_PROBER=false` in `/etc/default/grub` first.

## How to undo everything

Open hop and click **Undo changes**:

- **Linux isn't installed yet:** removes everything hop made and gives the space back to C:.
- **Linux is installed:** removes only the installer. Linux stays.

To remove an installed Linux, open hop again. It offers to remove it and free the space.
