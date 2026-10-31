# --- What hop left on this PC ------------------------------------------
# Everything hop makes is recognisable without the state file: partitions by
# their labels, startup entries by "(hop)" in their description.

# Looks on every disk hop could have used, because a crash can leave its state file behind or
# out of date. Off the Windows disk, a label alone isn't enough: the format has to match too,
# so someone's own drive named LINUXBOOT isn't mistaken for hop's.
function Get-HopPartitions {
    $windowsDisk = (Get-WindowsPartition).DiskNumber
    foreach ($disk in @(Get-HopDisks)) {
        foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
            $volume = try { $partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
            if (-not $volume -or $volume.FileSystemLabel -notin ($InstallerLabels + $BootLabel, $RootLabel)) { continue }
            if ($disk.Number -ne $windowsDisk) {
                $format = if ($volume.FileSystemLabel -eq $RootLabel) { 'exFAT' } else { 'FAT32' }
                if ($volume.FileSystemType -ne $format) { continue }
            }
            [pscustomobject]@{ Partition = $partition; Label = $volume.FileSystemLabel; Letter = $volume.DriveLetter }
        }
    }
}

function Get-FirmwareEntries {
    try { @($EntryMarkers | ForEach-Object { [Hop.Firmware]::FindEntries($_) }) } catch { Write-Log "Could not read startup entries: $($_.Exception.Message)"; @() }
}

# Earlier hop builds made startup entries with bcdedit; those live in the BCD store.
function Get-BcdEntries {
    $text = try { Invoke-Bcdedit /enum all } catch { '' }
    foreach ($block in ($text -split '(?:\r?\n){2,}')) {
        if ($block -match $EntryPattern) {
            $id = [regex]::Match($block, '\{[0-9a-fA-F-]{36}\}').Value
            if ($id) { $id }
        }
    }
}

# 'ready'    an installer is in place and set up to start
# 'installed' the installer is still here, and Linux has been installed from it
# 'leftover' something from an earlier attempt is left behind
# 'none'     nothing from hop on this PC
function Get-InstallStatus {
    $state = Read-State
    $partitions = @(Get-HopPartitions)
    $entries = @(Get-FirmwareEntries)
    $installer = $partitions | Where-Object { $_.Label -in $InstallerLabels } | Select-Object -First 1
    # Finished copying is what counts. The startup entry isn't required: some firmwares
    # delete entries, and Restart now makes a fresh one. Builds before Copied existed only
    # set BootNumber once the copy was done.
    $copied = $state -and ($state.Copied -or $null -ne $state.BootNumber)
    if ($copied -and $installer) {
        # Windows doesn't always give the partition its letter back after a restart.
        $letter = if ($installer.Letter) { $installer.Letter } else { try { Get-DriveLetter $installer.Partition } catch { $null } }
        if ($letter -and (Test-Path -LiteralPath "$($letter):\EFI\BOOT\BOOTX64.EFI")) {
            if (Test-LinuxInstalled $state) { return 'installed' }
            return 'ready'
        }
    }
    if ($state -or $partitions.Count -or $entries.Count -or @(Get-BcdEntries).Count) { return 'leftover' }
    'none'
}

# A Linux boot loader or partition that wasn't there when the install began. Partitions
# count too because firmware can drop a startup entry, and Linux must not look absent then.
function Test-LinuxInstalled($State) {
    $names = $State.PSObject.Properties.Name
    if ($names -notcontains 'LoadersBefore') { return $false }
    $disk = Get-StateDisk $State
    if (@(Get-LinuxLoaders $disk | Where-Object { $_.Path -notin @($State.LoadersBefore) }).Count) { return $true }
    if ($names -notcontains 'LinuxBefore' -or $null -eq $disk) { return $false }
    $partitions = @(Get-Partition -DiskNumber $disk)
    @(Get-LinuxPartitions $partitions | Where-Object { $_.Guid -notin @($State.LinuxBefore) }).Count -gt 0
}

# Partitions hop recorded but may not have got as far as labelling, for example when
# formatting failed. Anything holding a real file system by now isn't touched.
function Get-RecordedPartitions($State, [string[]]$Roles) {
    $recorded = @($State.Partitions | Where-Object { $_.Role -in $Roles })
    if (-not $recorded.Count) { return }
    $disk = Get-StateDisk $State
    if ($null -eq $disk) { return }
    foreach ($partition in Get-Partition -DiskNumber $disk) {
        $match = $recorded | Where-Object { [int64]$_.Offset -eq [int64]$partition.Offset -and [int64]$_.Size -eq [int64]$partition.Size }
        if (-not $match -or $partition.IsSystem -or $partition.IsBoot -or (Test-LinuxSignature $partition)) { continue }
        $volume = try { $partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
        if (-not $volume -or -not $volume.FileSystemType -or $volume.FileSystemType -eq 'Unknown') { $partition }
    }
}

function Save-State($State) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    # Write then swap, so losing power mid-write can't leave half a file. Move-Item -Force
    # replaces it in one step on the same drive.
    $temporary = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $StatePath -Force
}

function Read-State {
    $path = @($StatePath, $LegacyStatePath) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $path) { return }
    try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { Write-Log "Ignoring a damaged state file: $($_.Exception.Message)" }
}
