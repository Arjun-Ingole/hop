<#
    hop engine. Loaded into an in-process PowerShell runspace by hop.exe,
    which passes $Sync (a synchronized hashtable) for progress: Status, Percent,
    Stage and Log.

    How it works (what a USB installer does, but on the internal disk):
      1. Download the official ISO and check its checksum.
      2. Shrink the chosen drive and make room for Linux plus a small FAT32 "HOPINSTALL" partition.
      3. Copy the ISO's files onto HOPINSTALL.
      4. Add a UEFI boot entry for HOPINSTALL and boot it once on the next restart.
    The Linux installer then runs from HOPINSTALL and installs into the room made.

    The catalog says how each system's live ISO finds its files, and a chosen ISO has
    to be Ubuntu-style ("casper"). No file in the ISO may be 4 GB or larger (FAT32
    limit). Both are checked before the disk is touched.
#>

$ErrorActionPreference = 'Stop'

# This app used to be called LinuxHop. What those builds left on a PC is still
# recognised, so it can be used or undone; only the new names are ever written.
# Not $env:ProgramData, because the account's own settings can change that for an elevated process too.
$ProgramData = [Environment]::GetFolderPath('CommonApplicationData')
$StateDir = Join-Path $ProgramData 'hop'
$StatePath = Join-Path $StateDir 'state.json'
$LogDir = Join-Path $StateDir 'logs'
$LogPath = Join-Path $LogDir ('hop-{0:yyyy-MM-dd}.log' -f (Get-Date))
$LegacyStatePath = Join-Path $ProgramData 'LinuxHop\state.json'
$InstallerLabel = 'HOPINSTALL'
$InstallerLabels = @($InstallerLabel, 'LINUXHOP')
$LiveLabel = 'HOPLIVE'     # the second partition, for a live image FAT32 can't hold
$BootLabel = 'LINUXBOOT'
$RootLabel = 'LINUXROOT'
$EspFolder = 'EFI\hop'   # on Windows' EFI partition
$EspFolders = @($EspFolder, 'EFI\linuxhop')
$EntryMarker = '(hop)'
$EntryMarkers = @($EntryMarker, '(LinuxHop)')
$EntryPattern = '\((hop|LinuxHop)\)'
$WindowsReserve = 8GB    # free space Windows keeps on top of what it already uses
$MinLinuxGB = 25
$ShrinkMargin = 1GB       # kept between what's planned and how far Windows says it can shrink a drive

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Work proxies usually want the Windows sign-in, which isn't sent unless asked for.
try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }

# --- Progress reporting -------------------------------------------------
# Stages match the checklist in the app: 0 check PC, 1 download, 2 check
# download, 3 make room, 4 copy installer, 5 startup menu.

function Write-Log([string]$Message) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    [void]$Sync.Log.Add($line)
    # The log outlives the app, for bug reports. Failing to write it must never stop an install.
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            # hop.exe made the folder as it started, so this is only if it's been deleted since.
            if (-not (Test-Path -LiteralPath $StateDir)) { [void][Hop.StateFolder]::Protect($StateDir, $true) }
            New-Item -ItemType Directory -Path $LogDir | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Set-Status([string]$Message, [int]$Percent = -1) {
    $Sync.Status = $Message
    $Sync.Percent = $Percent
    Write-Log $Message
}

function Set-Stage([int]$Stage) {
    $Sync.Stage = $Stage
    $Sync.Percent = -1
    $Sync.Bytes = 0
    $Sync.TotalBytes = 0
}

function Set-ByteProgress([int64]$Done, [int64]$Total) {
    $Sync.Bytes = $Done
    $Sync.TotalBytes = $Total
    $Sync.Percent = if ($Total -gt 0) { [int][math]::Min([double]100, 100.0 * $Done / $Total) } else { -1 }
}

$LinuxSignatures = @('ext', 'btrfs', 'xfs', 'luks', 'lvm', 'swap')   # from [Hop.DiskProbe]
$EspType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$BasicDataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
