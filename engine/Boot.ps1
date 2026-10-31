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
        # Under 'Stop', a native program's stderr would replace this message.
        try { & mountvol.exe "$($letter):" /d 2>$null | Out-Null } catch { }
        throw 'Could not open the EFI system partition. Security software may be blocking it: turn that off for a moment and try again.'
    }
    try { & $Action "$($letter):\" } finally { & mountvol.exe "$($letter):" /d | Out-Null }
}

# Looks on every disk: Windows on a second drive often starts from the first drive's EFI partition.
function Get-WindowsEsp {
    $partitions = @(Get-Partition | Where-Object GptType -eq $EspType)
    $windows = @(try { [Hop.Firmware]::ListEntries() } catch { @() }) |
        Where-Object { $_.Path -like '\EFI\Microsoft\*' } | Select-Object -First 1
    $esp = if ($windows) { $partitions | Where-Object Guid -eq $windows.PartitionGuid | Select-Object -First 1 }
    if (-not $esp) { $esp = $partitions | Where-Object IsSystem | Select-Object -First 1 }
    if (-not $esp) {
        $disk = (Get-WindowsPartition).DiskNumber
        $esp = $partitions | Where-Object DiskNumber -eq $disk | Select-Object -First 1
    }
    if (-not $esp) { throw 'Could not find the EFI system partition.' }
    $esp
}

# Windows' EFI partition is small, and other systems may have filled it.
function Assert-EspRoom([string]$Root, [string]$Source) {
    $needed = (Get-ChildItem -LiteralPath $Source -Filter '*.efi' -Force | Measure-Object -Property Length -Sum).Sum + 1MB
    $free = ([IO.DriveInfo]$Root).AvailableFreeSpace
    if ($free -lt $needed) {
        throw ('The EFI system partition is too full: the boot loader needs {0:N0} MB and {1:N0} MB is free. Remove boot files from other systems and try again.' -f ($needed / 1MB), ($free / 1MB))
    }
}

# Security software can block this partition. Finding out now costs nothing; after the disk has changed it costs a lot.
function Assert-EspWritable([string]$Root) {
    $probe = Join-Path $Root 'EFI\hop-write-test.tmp'
    try {
        Set-Content -LiteralPath $probe -Value 'hop'
        Remove-Item -LiteralPath $probe -Force
    } catch {
        throw "Couldn't write to the EFI system partition ($($_.Exception.Message)). Security software may be blocking it: turn that off for a moment and try again."
    }
}

# GRUB starts the first partition it finds with /.disk/info, and hop can't choose the order, so
# a USB installer left plugged in, or another tool's leftovers, could start instead of hop's.
function Get-OtherInstallers {
    foreach ($volume in @(Get-Volume)) {
        if ($volume.DriveType -eq 'CD-ROM' -or $volume.FileSystemLabel -in $InstallerLabels -or -not $volume.Path) { continue }
        $found = try { [IO.File]::Exists("$($volume.Path).disk\info") } catch { $false }
        if (-not $found) { continue }
        $usb = $volume.DriveType -eq 'Removable' -or $(try { ($volume | Get-Partition | Get-Disk).BusType -eq 'USB' } catch { $false })
        $name = if ($volume.DriveLetter) { "drive $($volume.DriveLetter):" } elseif ($volume.FileSystemLabel) { "the $($volume.FileSystemLabel) partition" } else { 'an unnamed partition' }
        [pscustomobject]@{ Name = $name; Usb = $usb }
    }
}

# Puts the installer in the startup menu. Many firmwares (MSI's included) only start
# files from the EFI system partition, and some delete entries that point anywhere
# else, so the installer's signed boot loader is copied to \EFI\hop there. The config
# built into Ubuntu's signed GRUB finds the installer partition by its /.disk/info file;
# grub.cfg here is only its last resort. Safe to run again: old hop entries are replaced.
function Register-Installer([string]$Name) {
    Set-Status 'Adding the installer to the startup menu...'
    $installer = Get-HopPartitions | Where-Object { $_.Label -in $InstallerLabels } | Select-Object -First 1
    $letter = if (-not $installer) { $null } elseif ($installer.Letter) { $installer.Letter } else { Get-DriveLetter $installer.Partition }
    if (-not $letter -or -not (Test-Path -LiteralPath "$($letter):\EFI\BOOT\BOOTX64.EFI")) {
        throw 'The installer partition is missing or incomplete. Undo the changes and install again.'
    }
    $source = "$($letter):\EFI\BOOT"
    Use-Esp {
        param($root)
        Assert-EspRoom $root $source
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

function Test-FirmwareAccess { [Hop.Firmware]::CheckAccess() }

# The startup entry is added after the disk has changed, so find out now if it can't be.
function Assert-FirmwareAccess {
    try { Test-FirmwareAccess } catch {
        throw "hop can't change this PC's startup menu, so it couldn't start a Linux installer. Nothing has been changed. $($_.Exception.GetBaseException().Message)"
    }
}

function Set-BootOnce([int]$Number) {
    # Only the next restart goes to the installer; after that Windows is the default again.
    [Hop.Firmware]::SetBootNext($Number)
    Write-Log ('The next restart starts Boot{0:X4}.' -f $Number)
}
