<#
    hop engine. Loaded into an in-process PowerShell runspace by hop.exe,
    which passes $Sync (a synchronized hashtable) for progress: Status, Percent,
    Stage and Log.

    How it works (what a USB installer does, but on the internal disk):
      1. Download the official ISO and check its checksum.
      2. Shrink C: and make room for Linux plus a small FAT32 "HOPINSTALL" partition.
      3. Copy the ISO's files onto HOPINSTALL.
      4. Add a UEFI boot entry for HOPINSTALL and boot it once on the next restart.
    The Linux installer then runs from HOPINSTALL and installs into the room made.

    Only Ubuntu-style ("casper") live ISOs work, and no file in the ISO may be
    4 GB or larger (FAT32 limit). Both are checked before the disk is touched.
#>

$ErrorActionPreference = 'Stop'

# This app used to be called LinuxHop. What those builds left on a PC is still
# recognised, so it can be used or undone; only the new names are ever written.
$StateDir = Join-Path $env:ProgramData 'hop'
$StatePath = Join-Path $StateDir 'state.json'
$LegacyStatePath = Join-Path $env:ProgramData 'LinuxHop\state.json'
$InstallerLabel = 'HOPINSTALL'
$InstallerLabels = @($InstallerLabel, 'LINUXHOP')
$BootLabel = 'LINUXBOOT'
$RootLabel = 'LINUXROOT'
$EspFolder = 'EFI\hop'   # on Windows' EFI partition
$EspFolders = @($EspFolder, 'EFI\linuxhop')
$EntryMarker = '(hop)'
$EntryMarkers = @($EntryMarker, '(LinuxHop)')
$EntryPattern = '\((hop|LinuxHop)\)'
$WindowsReserve = 8GB    # free space Windows keeps on top of what it already uses
$MinLinuxGB = 25

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Progress reporting -------------------------------------------------
# Stages match the checklist in the app: 0 check PC, 1 download, 2 check
# download, 3 make room, 4 copy installer, 5 startup menu.

function Write-Log([string]$Message) {
    [void]$Sync.Log.Add(('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message))
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

$EspType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$BasicDataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
