<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/hop-lockup-dark.svg">
    <img src="assets/brand/hop-lockup-light.svg" alt="hop" width="200">
  </picture>
</p>

<p align="center">Install Linux next to Windows without a USB stick.</p>

`hop.exe` is a single file. It runs on Windows 10 (1803 or newer) and Windows 11 with
nothing to install, and asks for administrator access when it opens. Windows SmartScreen may
warn about it because it isn't code-signed: click **More info → Run anyway**.

## Status

Early. hop resizes partitions and changes startup entries, so back up anything you care about
first. The full route from Windows into the Linux installer has not yet been confirmed on real
hardware, and Secure Boot may need to be turned off. Reports from different PCs are very welcome:
see [Troubleshooting](docs/TROUBLESHOOTING.md) if something goes wrong.

## Features

- **One click, official sources.** Pick a system, and hop downloads it from the project's own server
  and verifies its checksum. Or use an ISO you already have.
- **Checks first.** It refuses PCs it can't work on and warns about battery power, RAID mode, pending
  updates and BitLocker before anything on the disk changes.
- **Picks up where it left off.** Interrupted downloads resume, and failures part way put the disk back.
- **Gets you unstuck.** If the PC comes back to Windows, reopening hop says why and offers to restart
  straight into the BIOS.
- **Removes itself.** Undo gives the space back, and once Linux is installed it offers to remove the
  installer. It can also remove another Linux that's on the drive, like Pond.

## What it does

1. Downloads the ISO from the project's official server and checks its SHA256 checksum.
   elementary OS publishes no checksum, so that download is checked by HTTPS only.
2. Checks the ISO is an Ubuntu-style live system with no file over 4 GB.
3. Uses free space after C:, shrinking C: only if it has to, and creates a small FAT32 partition
   called `HOPINSTALL`, plus either
   - free space that the installer's "alongside Windows" option uses (Ubuntu, Mint and flavours), or
   - a 1 GB `LINUXBOOT` partition and a `LINUXROOT` placeholder (elementary OS, Pop!_OS, whose
     easy install mode can't use free space).
4. Copies the ISO's files onto `HOPINSTALL`.
5. Copies the installer's signed boot loader to `\EFI\hop` on Windows' EFI system partition, adds a
   UEFI startup entry for it, and boots it once on the next restart.

Nothing on the disk changes until steps 1 and 2 pass. BitLocker is paused for three restarts
if it is on, and Windows Fast Startup is turned off. The app then lists the exact choices to
make in the Linux installer.

**Undo** removes the startup entry, the boot loader copy and hop's partitions, and gives the
space back to C: if Linux isn't installed yet.

hop can also remove another Linux it finds on the drive and give that space to Windows.

## Systems

elementary OS, Ubuntu 26.04 LTS, Ubuntu Budgie, Xubuntu, Lubuntu, Ubuntu Cinnamon,
Ubuntu Unity, Edubuntu, Ubuntu Studio, Linux Mint (Cinnamon, Xfce, MATE) and Pop!_OS 24.04.
Any other Ubuntu-based ISO also works, for example Zorin OS.

Not supported: Kubuntu (its ISO has a file over 4 GB, too big for FAT32) and systems not based
on Ubuntu, such as Fedora, Bazzite or Arch (their installers look for the USB stick differently).

Requires UEFI startup mode and a GPT disk, which every PC sold with Windows 10 or 11 has.

## The app

One window: a sentence ("Install elementary OS next to Windows, with 120 GB"), drive C: drawn
to scale, and one button. Click the system name to pick another; drag the line between Windows
and Linux to choose the size. The same window then shows progress, the choices to make in the
Linux installer, and undo.

## Project layout

| Path | What it is |
| --- | --- |
| `engine/` | Download, disk and boot-entry logic in PowerShell, embedded in the exe |
| `src/MainForm*.cs` | The window, with one file per group of screens |
| `src/Engine.cs` | Runs the engine and passes its results to the window |
| `src/Firmware.cs`, `src/DiskProbe.cs` | UEFI boot entries, and identifying what's on a partition |
| `src/Sentence.cs`, `src/DriveBar.cs`, `src/Picker.cs`, `src/Controls.cs` | Custom-drawn controls |
| `src/Theme.cs`, `src/Text.cs` | Colours, the embedded Instrument Sans font, text layout |
| `assets/brand/` | The hop frog and wordmark |
| `assets/logos/` | Each project's logo (see `SOURCES.md`) |
| `assets/fonts/` | Instrument Sans, SIL Open Font License (`OFL.txt`) |
| `tools/make_icon.py` | Draws `assets/hop.ico` and the brand PNGs |
| `tests/` | Unit tests, and a check that every download still resolves |
| `docs/` | [How it works](docs/ARCHITECTURE.md), [testing](docs/TESTING.md), [troubleshooting](docs/TROUBLESHOOTING.md) |
| `app.manifest` | Administrator rights and high-DPI support |

The app hosts the engine in Windows' built-in PowerShell 5.1 and shows its progress.

## Build

Needs the .NET SDK (any OS). Produces `bin/Release/hop.exe`.

```
dotnet build -c Release
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), including how to add a Linux system. To report a security
problem, see [SECURITY.md](SECURITY.md).

## License

hop is MIT licensed, see `LICENSE`. Instrument Sans is under the SIL Open Font License. The Linux
logos belong to their projects, keep their own licences (listed in `assets/logos/SOURCES.md`) and
are shown only to identify each download. hop isn't affiliated with any of those projects.
