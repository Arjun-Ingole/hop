# Testing

## What CI covers

Every pull request builds the exe, checks the scripts parse, lints them and runs the unit tests in
`tests/`. Those cover decisions: the space plan, status detection, what counts as Linux, the download
parsers, the startup entry's bytes. They mock the disk and firmware, so **they can't tell you hop
really boots**. A weekly job also checks every download in the catalog still resolves.

## Testing for real

Use a virtual machine, not a PC you care about. It has to use UEFI:

- **Hyper-V:** a Generation 2 VM. Secure Boot defaults to a template Linux won't pass, so set it to
  "Microsoft UEFI Certificate Authority", or turn it off.
- **VirtualBox:** turn on "Enable EFI".
- **VMware:** set the firmware type to UEFI.

Give it 100 GB or more, and take a snapshot before each run.

## What to check

Note which of these you ran in your pull request. Anything touching disks or boot needs the first three.

**Install**

- [ ] Fresh Windows: install a `prepared` system (elementary OS) through to a working Linux
- [ ] Fresh Windows: install a `freespace` system (Ubuntu) through to a working Linux
- [ ] Windows still starts afterwards, from the firmware's boot menu

**When it goes wrong**

- [ ] Secure Boot on: the installer starts, or the "didn't start" screen appears on reopening
- [ ] Secure Boot on, Pop!_OS: refused before the download, with what to do
- [ ] Secure Boot on, third-party certificate off: refused before the disk changes
- [ ] Windows on a second drive, EFI partition on the first: the startup entry is added to the first
- [ ] Cancel during the download, then install again: it resumes
- [ ] Disconnect the network during the download: the error says what to do
- [ ] Close the window during the download, then reopen
- [ ] Turn the VM off during the copy, then reopen: "didn't finish", and Clean up restores everything
- [ ] Fill C: until there isn't room: the window says how much to free
- [ ] Pick an ISO that isn't Ubuntu-based, and one with a file over 4 GB: both refused before the disk changes
- [ ] Open a second copy of hop: refused
- [ ] Click **Later**, then restart Windows yourself: Windows starts, not the installer
- [ ] Turn on Controlled Folder Access: making partitions still works, or the error explains why
- [ ] Linux Mint's installer works when run from the installer partition
- [ ] Plug in a USB stick with an Ubuntu ISO written to it: warned before starting, refused at restart
- [ ] Click Cancel as "Making room" begins: either it cancels with the disk untouched, or the install carries on

**Undo**

- [ ] Undo before installing Linux: C: gets all its space back, and no startup entry or `\EFI\hop` remains
- [ ] Fast Startup is back on after undo, if it was on before
- [ ] After installing Linux: reopen hop, it says installed, and removing the installer leaves Linux working and grows C:

**Another Linux**

- [ ] Another Linux on the drive is offered for removal, and goes
- [ ] A locked BitLocker data partition with no letter is **not** offered for removal

**Upgrades**

- [ ] Prepare with an old build, open with the new one: the setup is still recognised
