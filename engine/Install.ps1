# --- Main flows ------------------------------------------------------------

function Invoke-Install([string]$DistroId, [string]$IsoPath, [int]$LinuxGB) {
    Set-Stage 0
    Set-Status 'Checking this PC...'
    Test-System
    if ((Get-InstallStatus) -ne 'none') { throw 'hop found changes from an earlier attempt. Clean them up first.' }
    $distro = Get-Distro $DistroId $IsoPath
    Assert-SecureBootAllows $distro
    $diskChanged = $false

    if (-not $IsoPath) {
        Set-Stage 1
        Set-Status "Finding the latest $($distro.Name) on $($distro.Source)..."
        $download = try { Resolve-Download $distro } catch {
            throw "Couldn't find the download on $($distro.Source): $($_.Exception.Message) Check the internet connection, or download the ISO yourself and pick ""Use an ISO file""."
        }
        Write-Log "Official download: $($download.Url)"
        $IsoPath = Join-Path (Get-DownloadFolder) $download.FileName
        Get-Iso $download $IsoPath
    } elseif (-not (Test-Path -LiteralPath $IsoPath)) {
        throw "Can't find $IsoPath. Pick the ISO file again."
    }

    try {
        # Nothing on the disk changes until New-LinuxSpace.
        Set-Stage 2
        $iso = Read-Iso $IsoPath
        $plan = Get-Plan $LinuxGB $iso.InstallerGB
        Use-Esp { param($root) Assert-EspRoom $root "$($iso.Letter):\EFI\BOOT" }

        Set-Stage 3
        if (-not $Sync.Gate.EnterDiskStage()) { throw 'Cancelled.' }
        $state = [pscustomobject]@{
            Distro = $distro.Name; DistroId = $distro.Id; Strategy = $distro.Strategy; LinuxGB = $LinuxGB
            DiskNumber = $plan.DiskNumber; WindowsShrunk = $false; Partitions = @(); BootNumber = $null
            IsoPath = $IsoPath; Created = (Get-Date).ToString('s'); Copied = $false; RestartedAt = $null
            LoadersBefore = @(Get-LinuxLoaders | ForEach-Object { $_.Path })
            LinuxBefore = @(Get-LinuxPartitions @(Get-Partition -DiskNumber $plan.DiskNumber) | ForEach-Object { $_.Guid })
            FastStartupWasOn = (Get-FastStartup) -eq 1; BitLockerPaused = $false; InstallerNextToWindows = $true
        }
        $diskChanged = $true
        Save-State $state
        $state.BitLockerPaused = Suspend-BitLockerForSetup
        Disable-FastStartup
        Save-State $state
        $installer = New-LinuxSpace $plan $distro.Strategy $state | Select-Object -Last 1
        $letter = Get-DriveLetter $installer

        Set-Stage 4
        Copy-Installer $iso $letter
        $state.Copied = $true
        Save-State $state
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

    # From here a failure doesn't undo anything: the installer is complete, and Restart
    # now tries the startup menu again and reports the problem if it persists.
    Set-Stage 5
    try {
        $state.BootNumber = Register-Installer $distro.Name
        Save-State $state
        Set-BootOnce $state.BootNumber
    } catch {
        Write-Log "Could not add the installer to the startup menu yet: $($_.Exception.Message)"
    }

    Set-Stage 6
    Set-Status 'Ready to restart.' 100
    Write-Log "You can delete $IsoPath once Linux is installed."
}

function Get-StartupInfo {
    $status = Get-InstallStatus
    # Only for a new install: what stops an install must not stop someone undoing one.
    if ($status -eq 'none') { Test-System }
    $state = Read-State
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
        Status    = $status
        State     = $state
        CameBack  = $status -eq 'ready' -and (Test-CameBack $state)
        SecureBoot = Test-SecureBoot
        BootKey   = Get-BootMenuKey
    }
}

# True when hop restarted the PC for the installer and Windows has started since.
function Test-CameBack($State) {
    if (-not $State.RestartedAt) { return $false }
    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt [datetime]$State.RestartedAt
}

function Get-StateSteps {
    $state = Read-State
    # A system removed from the catalog since the install still needs its steps.
    $distro = Get-Distro $state.DistroId $state.IsoPath
    if (-not $distro) { $distro = Get-Distro 'custom' "$($state.Distro).iso" }
    Get-Steps $distro $state.LinuxGB
}

function Restart-IntoInstaller {
    Set-InstallerForNextStart
    Invoke-Shutdown '/r', '/t', '0'
}

# The BIOS settings, for turning off Secure Boot. Leaving them starts the installer.
function Restart-IntoFirmware {
    Set-InstallerForNextStart
    Invoke-Shutdown '/r', '/fw', '/t', '0'
}

function Set-InstallerForNextStart {
    $others = @(Get-OtherInstallers)
    $usb = $others | Where-Object Usb | Select-Object -First 1
    if ($usb) { throw "Unplug $($usb.Name) and try again. It also holds a Linux installer, and the PC could start that one instead." }
    # Can't be unplugged, and may well be fine, so it's in the warnings and doesn't block.
    foreach ($other in $others) { Write-Log "Another installer is on $($other.Name); the PC could start that one instead." }
    $state = Read-State
    Suspend-BitLockerForRestart $state
    $state.BootNumber = Register-Installer $state.Distro
    Set-BootOnce ([int]$state.BootNumber)
    # Builds before this one didn't have the field, so it may need adding.
    $state | Add-Member -NotePropertyName RestartedAt -NotePropertyValue (Get-Date).ToString('s') -Force
    Save-State $state
}

function Invoke-Shutdown([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = & shutdown.exe @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Windows could not restart this PC: $($output.Trim())" }
}

# Removes what hop made: its startup entries and partitions, found by their
# description and labels, so this also works when an earlier attempt failed half way.
# With -InstallerOnly, Linux and its partitions stay.
function Invoke-Cleanup([switch]$InstallerOnly) {
    $state = Read-State
    # Choosing "Linux isn't installed yet" by mistake must not take its boot partition with it.
    if (-not $InstallerOnly -and $state -and (Test-LinuxInstalled $state)) {
        Write-Log 'Linux is installed, so only the installer will be removed.'
        $InstallerOnly = [switch]$true
    }
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
        Remove-PartitionAt $found.Partition.DiskNumber $found.Partition.Offset
    }
    $roles = if ($InstallerOnly) { @('installer') } else { @('installer', 'root', 'boot') }
    foreach ($partition in @(Get-RecordedPartitions $state $roles)) {
        Set-Status 'Removing an unfinished partition...'
        Remove-PartitionAt $partition.DiskNumber $partition.Offset
    }

    # Free space that was next to C: before hop started stays free, unless C: was shrunk.
    # With Linux staying, the installer's space goes to C:, if it's next to it: builds before
    # InstallerNextToWindows put it after Linux, where Windows can't reach it.
    $growWindows = if ($InstallerOnly) { $state.InstallerNextToWindows } else { $null -eq $state -or $state.WindowsShrunk -ne $false }
    if ($growWindows) {
        try {
            $c = Get-WindowsPartition
            $max = (Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber).SizeMax
            if ($max -gt $c.Size + 1MB) {
                Set-Status 'Giving the space back to Windows...'
                Resize-Partition -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -Size $max
            }
        } catch {
            # The installer is gone by now, and that's what was asked for.
            if (-not $InstallerOnly) { throw }
            Write-Log "Could not give the installer's space to Windows: $($_.Exception.Message)"
        }
    }

    # Only without Linux: Fast Startup stays off for a dual boot, because it locks the Windows drive.
    if (-not $InstallerOnly) {
        if ($state.FastStartupWasOn) { Restore-FastStartup }
        if ($state.BitLockerPaused) { Resume-BitLockerAfterUndo }
    }

    foreach ($path in @($StatePath, $LegacyStatePath)) { if (Test-Path $path) { Remove-Item -LiteralPath $path -Force } }
    Set-Status 'hop changes removed.' 100
}
