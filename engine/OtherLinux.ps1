# --- Another Linux on this drive (for example Pond) ------------------------

$LinuxPartitionTypes = @(
    '{0fc63daf-8483-4772-8e79-3d69d8477de4}'   # Linux file system
    '{4f68bce3-e8cd-4db1-96e7-fbcaf984b709}'   # Linux root (x86-64)
    '{933ac7e1-2eb4-4f13-b844-0e14e2aef915}'   # Linux /home
    '{3b8f8425-20e0-4f3b-907f-1a25a76f98e8}'   # Linux /srv
    '{bc13c2ff-59e6-4262-a352-b275fd6f7172}'   # Linux /boot (XBOOTLDR)
    '{0657fd6d-a4ab-43c4-84e5-0933c84b4f4f}'   # Linux swap
    '{e6d6d379-f507-44c2-a23c-238f2a3df928}'   # Linux LVM
    '{a19d880f-05fc-4d3b-a006-743f0f84911e}'   # Linux RAID
)

# Linux partitions on the Windows drive, the startup entries that boot them, and a
# separate EFI partition if that Linux made its own. Windows' EFI partition is never included.
function Get-OtherSystem {
    $partitions = @(Get-Partition -DiskNumber (Get-WindowsPartition).DiskNumber)
    $onDisk = @($partitions | ForEach-Object { $_.Guid })
    $entries = @(try { [Hop.Firmware]::ListEntries() } catch { Write-Log "Could not read startup entries: $($_.Exception.Message)" })
    $windowsEsp = ($entries | Where-Object { $_.Path -like '\EFI\Microsoft\*' } | Select-Object -First 1).PartitionGuid
    $loaders = @($entries | Where-Object {
            $_.PartitionGuid -and $onDisk -contains $_.PartitionGuid -and $_.Path -and
            $_.Path -notlike '\EFI\Microsoft\*' -and $_.Description -notmatch $EntryPattern -and
            $_.Path -match '(shim|grub|systemd-boot|refind)[^\\]*\.efi$'
        })

    $linux = @($partitions | Where-Object { $_.GptType -in $LinuxPartitionTypes })
    if ($loaders.Count) {
        # Installers that run on Windows (Pond's does) may leave the generic "basic data" type on
        # their partitions. To Windows those look like a basic data partition with no file
        # system it can read and no drive letter.
        $linux += @($partitions | Where-Object {
                $_.GptType -eq $BasicDataType -and (-not $_.DriveLetter -or $_.DriveLetter -eq [char]0) -and $linux.Guid -notcontains $_.Guid -and
                (Get-UnreadableVolume $_)
            })
    }
    if (-not $linux.Count) { return $null }
    $removing = @($linux | ForEach-Object { $_.Guid })

    $boot = @($entries | Where-Object {
            $_.PartitionGuid -and $onDisk -contains $_.PartitionGuid -and $_.Path -and
            $_.Path -notlike '\EFI\Microsoft\*' -and $_.Description -notmatch $EntryPattern -and
            ($removing -contains $_.PartitionGuid -or $loaders.Number -contains $_.Number)
        })
    # Only when Windows' own EFI partition is known for certain, so it can never be picked.
    $esps = if (-not $windowsEsp) { @() } else {
        @($partitions | Where-Object {
                $_.GptType -eq $EspType -and $_.Guid -ne $windowsEsp -and ($boot | Where-Object PartitionGuid -eq $_.Guid)
            })
    }

    $name = ($boot | Select-Object -First 1).Description
    if (-not $name) { $name = 'the other Linux' }
    $all = @($linux) + @($esps)
    [pscustomobject]@{
        Name       = $name
        SizeGB     = [int][math]::Round((($all | Measure-Object -Property Size -Sum).Sum) / 1GB)
        Partitions = $all
        Entries    = $boot
        WindowsEsp = $windowsEsp
    }
}

# True when Windows can't read the partition's file system (ext4, btrfs and the like),
# and it isn't one of hop's own.
function Get-UnreadableVolume($Partition) {
    $volume = try { $Partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
    if (-not $volume) { return $true }
    $volume.FileSystemType -notin @('NTFS', 'FAT', 'FAT32', 'exFAT', 'ReFS', 'CSVFS') -and
        $volume.FileSystemLabel -notin ($InstallerLabels + $BootLabel, $RootLabel)
}

function Remove-PartitionByGuid([string]$Guid) {
    $partition = Get-Partition -DiskNumber (Get-WindowsPartition).DiskNumber | Where-Object Guid -eq $Guid
    if (-not $partition) { return }
    try {
        Remove-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
        return
    } catch { }
    # Windows protects EFI partitions; diskpart can still delete one that isn't Windows' own.
    $ErrorActionPreference = 'Continue'
    $script = [IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $script -Encoding ASCII -Value @(
        "select disk $($partition.DiskNumber)", "select partition $($partition.PartitionNumber)", 'delete partition override')
    $output = & diskpart.exe /s $script 2>&1 | Out-String
    Remove-Item -LiteralPath $script -Force
    if ($LASTEXITCODE -ne 0) { throw "Could not delete partition $($partition.PartitionNumber): $output" }
}

function Remove-OtherSystem {
    $other = Get-OtherSystem
    if (-not $other) { throw 'There is no other Linux on this drive.' }
    Set-Status "Removing $($other.Name)..."

    foreach ($entry in $other.Entries) {
        [Hop.Firmware]::DeleteBootEntry($entry.Number)
        Write-Log ('Removed startup entry Boot{0:X4} ({1}).' -f $entry.Number, $entry.Description)
    }

    # Its boot loader files on Windows' EFI partition, e.g. \EFI\pond.
    $folders = @($other.Entries | Where-Object { $_.PartitionGuid -eq $other.WindowsEsp } |
        ForEach-Object { ($_.Path -split '\\')[2] } | Where-Object { $_ -and $_ -notin @('Microsoft', 'Boot') } | Sort-Object -Unique)
    if ($folders.Count) {
        $letter = [char[]](90..68) | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1
        & mountvol.exe "$($letter):" /s | Out-Null
        try {
            foreach ($folder in $folders) {
                $path = "$($letter):\EFI\$folder"
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; Write-Log "Removed $path." }
            }
        } finally {
            & mountvol.exe "$($letter):" /d | Out-Null
        }
    }

    foreach ($partition in $other.Partitions) {
        Set-Status "Removing $($other.Name) ($([math]::Round($partition.Size / 1GB)) GB partition)..."
        Remove-PartitionByGuid $partition.Guid
    }
    Set-Status "$($other.Name) removed." 100
}

# Gives the free space right after C: to Windows.
function Expand-Windows {
    $c = Get-WindowsPartition
    $max = (Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber).SizeMax
    if ($max -le $c.Size + 1MB) { throw "The free space isn't next to drive C:, so Windows can't use it directly." }
    Set-Status 'Giving the space to Windows...'
    Resize-Partition -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -Size $max
    Set-Status 'Done.' 100
}
