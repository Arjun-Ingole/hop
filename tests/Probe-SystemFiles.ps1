<#
    Puts $Mft::$BITMAP near the end of a real NTFS volume on a throwaway virtual disk, the way it stops
    Windows shrinking a drive on some PCs, then checks hop moves it, Windows can shrink again, and the
    file system is still sound. Not a Pester test because it changes disks. Only run it on a disposable
    Windows machine, as administrator, after a build:

        powershell -File tests\Probe-SystemFiles.ps1
#>
param([string]$Folder = (Join-Path $env:TEMP 'hop-probe-files'))

$root = Split-Path $PSScriptRoot -Parent
$Sync = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Version = 'probe' })
. (Join-Path $root 'engine\Common.ps1')
foreach ($module in Get-ChildItem (Join-Path $root 'engine\*.ps1') | Where-Object Name -ne 'Common.ps1') { . $module.FullName }
[void][Reflection.Assembly]::LoadFrom((Join-Path $root 'bin\Release\hop.exe'))
$ErrorActionPreference = 'Stop'
$stream = '$Mft::$BITMAP'
$failed = 0
function Check([string]$What, [bool]$Ok, $Detail) {
    if ($Ok) { Write-Output "  pass  $What" } else { $script:failed++; Write-Output "  FAIL  $What  ($Detail)" }
}

New-Item -ItemType Directory -Force $Folder | Out-Null
$vhd = Join-Path $Folder 'files.vhdx'
if (Test-Path $vhd) { Remove-Item $vhd -Force }
"create vdisk file=`"$vhd`" maximum=40000 type=expandable", "select vdisk file=`"$vhd`"", 'attach vdisk', 'convert gpt', 'create partition primary', 'format fs=ntfs quick label=PROBE', 'assign', 'exit' | diskpart.exe | Out-Null
try {
    $volume = Get-Volume -FileSystemLabel PROBE
    $letter = [string]$volume.DriveLetter
    $partition = Get-Partition -DriveLetter $letter
    $room = "$letter`:"
    # Something for the disk check to find changed.
    1..2000 | ForEach-Object { Set-Content "$room\file$_.txt" "contents $_" }

    $sizeBefore = (Get-PartitionSupportedSize -DriveLetter $letter).SizeMin
    Write-Output "Can shrink to $([math]::Round($sizeBefore / 1GB, 2)) GB on a new volume."
    $up = [Hop.NtfsMove]::MoveToEnd($letter, $stream, 0.97)
    Check 'the bitmap moved to the end of the drive' ($up -gt 0) $up
    $stuck = (Get-PartitionSupportedSize -DriveLetter $letter).SizeMin
    Write-Output "Can shrink to $([math]::Round($stuck / 1GB, 2)) GB with it there."
    Check 'that stops the drive shrinking' ($stuck -gt $partition.Size * 0.9) $stuck
    $blocker = Get-ShrinkBlocker $partition
    Write-Output "Windows names: $blocker"
    Check 'Windows names it' ($blocker -like '*$Mft::$BITMAP*') $blocker
    Check 'hop knows it can move it' ([bool](Test-MovableSystemFile $blocker)) $blocker

    Check 'hop moves what Windows names' ([bool](Move-SystemFiles $room $partition)) (($Sync.Log | Select-Object -Last 3) -join ' / ')
    $after = (Get-PartitionSupportedSize -DriveLetter $letter).SizeMin
    Write-Output "Can shrink to $([math]::Round($after / 1GB, 2)) GB afterwards."
    Check 'the drive can shrink again' ($after -lt $partition.Size * 0.5) $after

    Resize-Partition -DriveLetter $letter -Size ([int64]($after + 1GB))
    Check 'the drive really shrinks' ((Get-Partition -DriveLetter $letter).Size -lt $partition.Size * 0.6) (Get-Partition -DriveLetter $letter).Size

    $scan = Repair-Volume -DriveLetter $letter -Scan
    Write-Output "Disk check: $scan"
    Check 'the file system is sound' ("$scan" -eq 'NoErrorsFound') $scan
    $missing = @(1..2000 | Where-Object { (Get-Content "$room\file$_.txt") -ne "contents $_" }).Count
    Check 'every file reads back' ($missing -eq 0) $missing
    foreach ($line in $Sync.Log) { Write-Output "log: $line" }
} finally {
    "select vdisk file=`"$vhd`"", 'detach vdisk', 'exit' | diskpart.exe | Out-Null
}
if ($failed) { Write-Output "$failed failed."; exit 1 }
Write-Output 'All passed.'
