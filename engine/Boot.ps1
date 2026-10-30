function Invoke-Bcdedit {
    # Windows PowerShell turns a native program's stderr into a terminating error under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $output = & bcdedit.exe @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "bcdedit $($args -join ' ') failed: $output" }
    $output
}

# Opens Windows' EFI system partition for a moment.
function Use-Esp([scriptblock]$Action) {
    $letter = [char[]](90..68) | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1
    if (-not $letter) { throw 'Every drive letter is in use, so the EFI system partition cannot be opened. Remove a network drive or USB drive and try again.' }
    & mountvol.exe "$($letter):" /s | Out-Null
    if (-not (Test-Path "$($letter):\EFI")) {
        & mountvol.exe "$($letter):" /d 2>$null | Out-Null
        throw 'Could not open the EFI system partition.'
    }
    try { & $Action "$($letter):\" } finally { & mountvol.exe "$($letter):" /d | Out-Null }
}

function Get-WindowsEsp {
    $partitions = @(Get-Partition -DiskNumber (Get-WindowsPartition).DiskNumber | Where-Object GptType -eq $EspType)
    $windows = @(try { [Hop.Firmware]::ListEntries() } catch { @() }) |
        Where-Object { $_.Path -like '\EFI\Microsoft\*' } | Select-Object -First 1
    $esp = if ($windows) { $partitions | Where-Object Guid -eq $windows.PartitionGuid | Select-Object -First 1 }
    if (-not $esp) { $esp = $partitions | Select-Object -First 1 }
    if (-not $esp) { throw 'Could not find the EFI system partition.' }
    $esp
}

# Puts the installer in the startup menu. Many firmwares (MSI's included) only start
# files from the EFI system partition, and some delete entries that point anywhere
# else, so the installer's signed boot loader is copied to \EFI\hop there. It
# finds the installer partition by its /.disk/info file and loads the menu from it.
# Safe to run again: old hop entries are replaced.
function Register-Installer([string]$Name) {
    Set-Status 'Adding the installer to the startup menu...'
    $installer = Get-HopPartitions | Where-Object { $_.Label -in $InstallerLabels } | Select-Object -First 1
    $letter = if (-not $installer) { $null } elseif ($installer.Letter) { $installer.Letter } else { Get-DriveLetter $installer.Partition }
    if (-not $letter -or -not (Test-Path -LiteralPath "$($letter):\EFI\BOOT\BOOTX64.EFI")) {
        throw 'The installer partition is missing or incomplete. Undo the changes and install again.'
    }
    $source = "$($letter):\EFI\BOOT"
    $needed = (Get-ChildItem -LiteralPath $source -Filter '*.efi' -Force | Measure-Object -Property Length -Sum).Sum + 1MB
    Use-Esp {
        param($root)
        # Windows' EFI partition is small, and other systems may have filled it.
        $free = ([IO.DriveInfo]$root).AvailableFreeSpace
        if ($free -lt $needed) {
            throw ('The EFI system partition is too full: the boot loader needs {0:N0} MB and {1:N0} MB is free. Remove boot files from other systems and try again.' -f ($needed / 1MB), ($free / 1MB))
        }
        foreach ($old in $EspFolders -ne $EspFolder) {
            $path = Join-Path $root $old
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        $folder = Join-Path $root $EspFolder
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Get-ChildItem -LiteralPath $source -Filter '*.efi' -Force | Copy-Item -Destination $folder -Force
        Set-Content -LiteralPath (Join-Path $folder 'grub.cfg') -Encoding ASCII -Value @(
            'search --no-floppy --file --set=root /.disk/info'
            'set prefix=($root)/boot/grub'
            'configfile $prefix/grub.cfg')
    }
    Write-Log "Copied the installer's boot loader to \$EspFolder on the EFI system partition."

    foreach ($number in @(Get-FirmwareEntries)) { [Hop.Firmware]::DeleteBootEntry($number) }
    $esp = Get-WindowsEsp
    $sector = (Get-Disk -Number $esp.DiskNumber).LogicalSectorSize
    $number = [Hop.Firmware]::CreateBootEntry("$Name installer $EntryMarker", $esp.PartitionNumber,
        [int64]($esp.Offset / $sector), [int64]($esp.Size / $sector), $esp.Guid, "\$EspFolder\BOOTX64.EFI")
    Write-Log ('Added startup entry Boot{0:X4}.' -f $number)
    $number
}

function Set-BootOnce([int]$Number) {
    # Only the next restart goes to the installer; after that Windows is the default again.
    [Hop.Firmware]::SetBootNext($Number)
    Write-Log ('The next restart starts Boot{0:X4}.' -f $Number)
}
