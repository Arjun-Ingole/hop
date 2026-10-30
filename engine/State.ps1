# --- What hop left on this PC ------------------------------------------
# Everything hop makes is recognisable without the state file: partitions by
# their labels, startup entries by "(hop)" in their description.

function Get-HopPartitions {
    foreach ($partition in Get-Partition -DiskNumber (Get-WindowsPartition).DiskNumber) {
        $volume = try { $partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
        if ($volume -and $volume.FileSystemLabel -in ($InstallerLabels + $BootLabel, $RootLabel)) {
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
# 'leftover' something from an earlier attempt is left behind
# 'none'     nothing from hop on this PC
function Get-InstallStatus {
    $state = Read-State
    $partitions = @(Get-HopPartitions)
    $entries = @(Get-FirmwareEntries)
    $installer = $partitions | Where-Object { $_.Label -in $InstallerLabels } | Select-Object -First 1
    # The startup entry itself isn't required: some firmwares delete entries, and
    # Restart now makes a fresh one.
    $hasBootNumber = $state -and ($state.PSObject.Properties.Name -contains 'BootNumber') -and $null -ne $state.BootNumber
    if ($hasBootNumber -and $installer -and $installer.Letter -and
        (Test-Path -LiteralPath "$($installer.Letter):\EFI\BOOT\BOOTX64.EFI")) {
        return 'ready'
    }
    if ($state -or $partitions.Count -or $entries.Count -or @(Get-BcdEntries).Count) { return 'leftover' }
    'none'
}

function Save-State($State) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Read-State {
    $path = @($StatePath, $LegacyStatePath) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}
