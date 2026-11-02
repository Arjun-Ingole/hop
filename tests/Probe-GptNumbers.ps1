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

$vhd = Join-Path $env:TEMP 'hop-gpt.vhdx'
if (Test-Path $vhd) { Remove-Item $vhd -Force }
@("create vdisk file=`"$vhd`" maximum=4000 type=expandable", "select vdisk file=`"$vhd`"", 'attach vdisk', 'exit') | diskpart.exe | Out-Null
try {
    $disk = (Get-DiskImage -ImagePath $vhd | Get-Disk).Number
    Initialize-Disk -Number $disk -PartitionStyle GPT
    # Made the way hop makes its own, one after another.
    1..5 | ForEach-Object { New-Partition -DiskNumber $disk -Size 300MB | Out-Null }
    $before = Get-GptNumbers $disk
    Write-Output ("Before: " + (($before.Keys | Sort-Object | ForEach-Object { "number $($before[$_]) at $_" }) -join ', '))
    Check 'hop reads every partition''s number' (@(Get-Partition -DiskNumber $disk | Where-Object { $before[[int64]$_.Offset] }).Count -eq @(Get-Partition -DiskNumber $disk).Count) ''
    $middle = @(Get-Partition -DiskNumber $disk | Sort-Object Offset)[2]
    Write-Output "Removing the partition at $($middle.Offset), as hop removes its installer"
    Remove-PartitionAt $disk ([int64]$middle.Offset)
    $after = Get-GptNumbers $disk
    Write-Output ("After: " + (($after.Keys | Sort-Object | ForEach-Object { "number $($after[$_]) at $_" }) -join ', '))
    $later = @($before.Keys | Where-Object { $_ -gt [int64]$middle.Offset })
    $moved = @($later | Where-Object { $after[$_] -ne $before[$_] })
    # What Windows does, recorded rather than wished away. hop's Undo has to allow for it.
    Write-Output "Partitions after it that Windows renumbered: $($moved.Count) of $($later.Count)"
    Check 'hop''s check would have seen this coming' (($moved.Count -gt 0) -eq ($later.Count -gt 0 -and $moved.Count -gt 0)) ''
} finally {
    "select vdisk file=`"$vhd`"", 'detach vdisk', 'exit' | diskpart.exe | Out-Null
}
if ($failed) { exit 1 }
Write-Output 'All passed.'
