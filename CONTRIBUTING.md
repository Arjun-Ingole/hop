# Contributing

hop changes people's disks and startup menus, so the bar is: it must never leave a PC worse than it
found it. Reports from real PCs are as useful as code. If hop failed for you, please open an issue
with the bug report the app copies for you.

## Setup

You need the [.NET SDK](https://dotnet.microsoft.com/download). It builds on any OS, but hop only
runs on Windows.

```
dotnet build -c Release
```

The result is `bin/Release/hop.exe`. Tests need Windows PowerShell and Pester 5:

```powershell
Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester tests
```

They mock everything that touches the disk, the firmware or the network, so they're safe on your
own PC. **Running hop itself is not**: try changes in a virtual machine first, see
[docs/TESTING.md](docs/TESTING.md).

## Adding a Linux system

Most additions are one line in `Get-Catalog` in `engine/Catalog.ps1`, plus a logo:

1. Check the ISO qualifies: Ubuntu-based, with a `casper` folder and `.disk/info`, and no file of
   4 GB or more. hop checks this at runtime too.
2. Add the entry. An official Ubuntu flavour needs only `New-UbuntuFlavor`. Anything else needs a
   `Kind` and a matching branch in `Resolve-Download` in `engine/Download.ps1`, which finds the newest
   ISO and its checksum on the project's own server.
3. Add `assets/logos/<name>.png` (128 px) and its `.svg`, and record where it came from in
   `assets/logos/SOURCES.md`.
4. Run the installer once and write down exactly what its screens say, because `Get-Steps` in
   `engine/Steps.ps1` shows those words to people. Use `Strategy = 'prepared'` if its easy mode
   can't use free space.

## Rules for code that touches a PC

- **Everything hop makes must be findable later**, without relying on the state file: partitions by
  label, startup entries by `(hop)` in the name. Undo has to work after a crash half way.
- **Never delete on a guess.** A partition only counts as Linux if its type or its own first bytes
  say so. Windows' EFI partition, and the system and boot partitions, are never candidates.
- **Nothing changes on the disk until the checks pass.** Failing before that point costs nothing.
- **Say what to do next.** "Failed" isn't an error message. Say what happened and the next step, in
  words someone who has never opened a terminal can follow.
- **Keep old setups working.** Someone may open a new build with an installer made by an old one.
  `engine/Common.ps1` lists the names older builds used.

## Commits and pull requests

Keep commits to one change, with a subject that says what it does in the imperative ("Check the EFI
partition has room") and a body that says why. Branch from `main` and open a pull request. CI must
pass. If the change touches disks, boot entries or the installer, say how you tested it for real.

Add a line to `CHANGELOG.md` under Unreleased for anything people would notice.

## Releases

Update `CHANGELOG.md`, then push a tag such as `v0.2.0`. The release workflow builds `hop.exe`,
stamps the version and publishes it with its checksum.
