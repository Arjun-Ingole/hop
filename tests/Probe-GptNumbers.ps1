<#
    Whether Windows keeps every other partition's GPT number when hop removes one. Linux names partitions by those
    numbers, nvme0n1p6 and GRUB's (hd0,gpt6), so a change after Linux is installed would stop it starting. Reads the
    GPT itself, on a throwaway virtual disk. Only run it on a disposable Windows machine, as administrator, after a build:

        powershell -File tests\Probe-GptNumbers.ps1
#>
$root = Split-Path $PSScriptRoot -Parent
$Sync = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Version = 'probe' })
. (Join-Path $root 'engine\Common.ps1')
foreach ($module in Get-ChildItem (Join-Path $root 'engine\*.ps1') | Where-Object Name -ne 'Common.ps1') { . $module.FullName }
[void][Reflection.Assembly]::LoadFrom((Join-Path $root 'bin\Release\hop.exe'))
$ErrorActionPreference = 'Stop'
$failed = 0
function Check([string]$What, [bool]$Ok, $Detail) { if ($Ok) { Write-Output "  pass  $What" } else { $script:failed++; Write-Output "  FAIL  $What  ($Detail)" } }

# Start sector of each used entry, by its number, read from the disk.
function Get-GptNumbers([int]$Disk) {
    $sector = (Get-Disk -Number $Disk).LogicalSectorSize
    $table = [Hop.DiskProbe]::ReadHead($Disk, 2 * $sector)
    $numbers = [ordered]@{}
    for ($i = 0; $i -lt 128 -and ($i + 1) * 128 -le $table.Length; $i++) {
        $type = [BitConverter]::ToString($table, $i * 128, 16)
        if ($type -ne '00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00') { $numbers[$i + 1] = [BitConverter]::ToInt64($table, $i * 128 + 32) }
    }
    $numbers
}

$vhd = Join-Path $env:TEMP 'hop-gpt.vhdx'
if (Test-Path $vhd) { Remove-Item $vhd -Force }
$lines = @("create vdisk file=`"$vhd`" maximum=4000 type=expandable", "select vdisk file=`"$vhd`"", 'attach vdisk', 'convert gpt') + (1..5 | ForEach-Object { 'create partition primary size=300' }) + 'exit'
$lines | diskpart.exe | Out-Null
try {
    $disk = (Get-Disk | Where-Object Location -eq $vhd).Number
    $before = Get-GptNumbers $disk
    Write-Output ("Before: " + (($before.Keys | ForEach-Object { "$_ at sector $($before[$_])" }) -join ', '))
    $middle = @(Get-Partition -DiskNumber $disk | Sort-Object Offset)[2]
    Write-Output "Removing the partition at $($middle.Offset), as hop removes its installer"
    Remove-PartitionAt $disk ([int64]$middle.Offset)
    $after = Get-GptNumbers $disk
    Write-Output ("After: " + (($after.Keys | ForEach-Object { "$_ at sector $($after[$_])" }) -join ', '))
    $sector = (Get-Disk -Number $disk).LogicalSectorSize
    $kept = @($before.Keys | Where-Object { $before[$_] -ne [int64]($middle.Offset / $sector) })
    Check 'every other partition keeps its number' (@($kept | Where-Object { $after[$_] -ne $before[$_] }).Count -eq 0) (($kept | ForEach-Object { "$_ : $($before[$_]) -> $($after[$_])" }) -join '; ')
} finally {
    "select vdisk file=`"$vhd`"", 'detach vdisk', 'exit' | diskpart.exe | Out-Null
}
if ($failed) { exit 1 }
Write-Output 'All passed.'
