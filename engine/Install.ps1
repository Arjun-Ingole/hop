# --- Main flows ------------------------------------------------------------

function Invoke-Install([string]$DistroId, [string]$IsoPath, [int]$LinuxGB) {
    Set-Stage 0
    Set-Status 'Checking this PC...'
    Test-System
    if ((Get-InstallStatus) -ne 'none') { throw 'hop found changes from an earlier attempt. Clean them up first.' }
    $distro = Get-Distro $DistroId $IsoPath
    $diskChanged = $false

    if (-not $IsoPath) {
        Set-Stage 1
        Set-Status "Finding the latest $($distro.Name) on $($distro.Source)..."
        $download = Resolve-Download $distro
        Write-Log "Official download: $($download.Url)"
        $IsoPath = Join-Path (Join-Path $env:USERPROFILE 'Downloads') $download.FileName
        Get-Iso $download $IsoPath
    }

    try {
        # Nothing on the disk changes until New-LinuxSpace.
        Set-Stage 2
        $iso = Read-Iso $IsoPath
        $plan = Get-Plan $LinuxGB $iso.InstallerGB

        Set-Stage 3
        Suspend-BitLockerForSetup
        Disable-FastStartup
        $state = [pscustomobject]@{
            Distro = $distro.Name; DistroId = $distro.Id; Strategy = $distro.Strategy; LinuxGB = $LinuxGB
            DiskNumber = $plan.DiskNumber; WindowsShrunk = $false; Partitions = @(); BootNumber = $null
            IsoPath = $IsoPath; Created = (Get-Date).ToString('s')
        }
        $diskChanged = $true
        $installer = New-LinuxSpace $plan $distro.Strategy $state | Select-Object -Last 1
        $letter = Get-DriveLetter $installer

        Set-Stage 4
        Copy-Installer $iso $letter

        Set-Stage 5
        $state.BootNumber = Register-Installer $distro.Name
        Save-State $state
        Set-BootOnce $state.BootNumber
    } catch {
        # Leave the PC as it was: a half-made installer is worse than none.
        if ($diskChanged) {
            Write-Log "Failed: $($_.Exception.Message)"
            Write-Log 'Undoing the changes made so far...'
            try { Invoke-Cleanup } catch { Write-Log "Could not undo everything: $($_.Exception.Message)" }
        }
        throw
    } finally {
        try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch { }
    }

    Set-Stage 6
    Set-Status 'Ready to restart.' 100
    Write-Log "You can delete $IsoPath once Linux is installed."
}

function Get-StartupInfo {
    Test-System
    $space = Get-SpaceInfo
    $volume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')
    $disk = Get-Disk -Number $space.Partition.DiskNumber
    [pscustomobject]@{
        UsableGB  = $space.UsableGB
        WindowsGB = [int][math]::Floor($space.Partition.Size / 1GB)
        UsedGB    = [int][math]::Ceiling(($volume.Size - $volume.SizeRemaining) / 1GB)
        DiskName  = ($disk.FriendlyName -replace '\s+', ' ').Trim()
        TailFreeGB = [int][math]::Floor($space.TailFree / 1GB)
        Other     = Get-OtherSystem | Select-Object Name, SizeGB
        Status    = Get-InstallStatus
        State     = Read-State
    }
}

function Get-StateSteps {
    $state = Read-State
    Get-Steps (Get-Distro $state.DistroId $state.IsoPath) $state.LinuxGB
}

function Restart-IntoInstaller {
    $state = Read-State
    $state.BootNumber = Register-Installer $state.Distro
    Save-State $state
    Set-BootOnce ([int]$state.BootNumber)
    & shutdown.exe /r /t 0
}

# Removes what hop made: its startup entries and partitions, found by their
# description and labels, so this also works when an earlier attempt failed half way.
# With -InstallerOnly, Linux and its partitions stay.
function Invoke-Cleanup([switch]$InstallerOnly) {
    Set-Status 'Removing hop from the startup menu...'
    foreach ($id in @(Get-BcdEntries)) {
        try { Invoke-Bcdedit /delete $id | Out-Null; Write-Log "Removed startup entry $id." } catch { Write-Log "Could not remove $id." }
    }
    foreach ($number in @(Get-FirmwareEntries)) {
        [Hop.Firmware]::DeleteBootEntry($number)
        Write-Log ('Removed startup entry Boot{0:X4}.' -f $number)
    }
    try {
        Use-Esp {
            param($root)
            foreach ($name in $EspFolders) {
                $folder = Join-Path $root $name
                if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force; Write-Log "Removed \$name." }
            }
        }
    } catch { Write-Log "Could not tidy the EFI system partition: $($_.Exception.Message)" }

    $labels = if ($InstallerOnly) { $InstallerLabels } else { $InstallerLabels + $RootLabel, $BootLabel }
    foreach ($found in @(Get-HopPartitions | Where-Object { $_.Label -in $labels })) {
        Set-Status "Removing the $($found.Label) partition..."
        Remove-Partition -DiskNumber $found.Partition.DiskNumber -PartitionNumber $found.Partition.PartitionNumber -Confirm:$false
    }

    if (-not $InstallerOnly) {
        $c = Get-WindowsPartition
        $max = (Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber).SizeMax
        if ($max -gt $c.Size + 1MB) {
            Set-Status 'Giving the space back to Windows...'
            Resize-Partition -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -Size $max
        }
    }

    foreach ($path in @($StatePath, $LegacyStatePath)) { if (Test-Path $path) { Remove-Item -LiteralPath $path -Force } }
    Set-Status 'hop changes removed.' 100
}
