# --- Disk ----------------------------------------------------------------

function Get-WindowsPartition {
    Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
}

# Unallocated space directly after C:, for example where another Linux used to be.
function Get-TailFree {
    $c = Get-WindowsPartition
    $end = $c.Offset + $c.Size
    $next = Get-Partition -DiskNumber $c.DiskNumber | Where-Object Offset -gt $c.Offset | Sort-Object Offset | Select-Object -First 1
    $limit = if ($next) { $next.Offset } else { (Get-Disk -Number $c.DiskNumber).Size - 2MB }   # GPT keeps a backup at the end
    [math]::Max([int64]0, [int64]($limit - $end))
}

function Get-SpaceInfo {
    $c = Get-WindowsPartition
    $supported = Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber
    $tail = Get-TailFree
    [pscustomobject]@{
        Partition = $c
        MinSize   = [int64]$supported.SizeMin
        TailFree  = $tail
        # GB Linux can get: free space after C:, plus what C: can give up while Windows keeps its reserve.
        UsableGB  = [int][math]::Floor(($tail + $c.Size - $supported.SizeMin - $WindowsReserve) / 1GB)
    }
}

function Get-Plan([int]$LinuxGB, [int]$InstallerGB) {
    $space = Get-SpaceInfo
    $maxLinux = $space.UsableGB - $InstallerGB
    if ($LinuxGB -gt $maxLinux) {
        if ($maxLinux -lt $MinLinuxGB) { throw "Not enough free space on C:. Free up at least $($MinLinuxGB - $maxLinux) GB and try again." }
        throw "Not enough free space for $LinuxGB GB. Lower the Linux size to $maxLinux GB or less and click Install again."
    }
    # Linux goes last and the installer straight before it, at the end of C: and the free
    # space after it. So the installer's space, and anything left over, stays next to C:,
    # which is the only place Windows can use it once Linux is installed. C: only shrinks
    # when the free space isn't enough.
    $c = $space.Partition
    $windowsEnd = [int64]($c.Offset + $c.Size)
    $regionEnd = [int64]([math]::Floor(($windowsEnd + $space.TailFree) / 1MB) * 1MB)
    $linuxStart = [int64]($regionEnd - [int64]$LinuxGB * 1GB)
    $installerOffset = [int64]($linuxStart - [int64]$InstallerGB * 1GB)
    $shrink = $installerOffset -lt $windowsEnd
    [pscustomobject]@{
        DiskNumber      = $c.DiskNumber
        PartitionNumber = $c.PartitionNumber
        Shrink          = $shrink
        NewWindowsSize  = if ($shrink) { [int64]($installerOffset - $c.Offset) } else { [int64]$c.Size }
        FreeStart       = $linuxStart
        LinuxGB         = $LinuxGB
        InstallerOffset = $installerOffset
        InstallerSize   = [int64]$InstallerGB * 1GB
    }
}

function Get-DriveLetter($Partition) {
    for ($i = 0; $i -lt 20; $i++) {
        $letter = (Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber).DriveLetter
        if ($letter -and $letter -ne [char]0) { return [string]$letter }
        # Asking while Windows is already on it fails harmlessly.
        if ($i % 4 -eq 0) { try { Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AssignDriveLetter } catch { } }
        Start-Sleep -Milliseconds 500
    }
    throw 'Windows did not give the installer partition a drive letter. If every letter is in use, remove a network drive or USB drive and try again.'
}

# Partition numbers can shift once a partition is removed, and acting on a stale one could
# delete Windows' recovery partition. So each is looked up again by where it starts.
function Remove-PartitionAt([int]$DiskNumber, [int64]$Offset) {
    $partition = Get-Partition -DiskNumber $DiskNumber | Where-Object { [int64]$_.Offset -eq $Offset } | Select-Object -First 1
    if (-not $partition) { return }
    if ($partition.IsSystem -or $partition.IsBoot) { throw "Refusing to remove partition $($partition.PartitionNumber): Windows needs it to start." }
    Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
}

function Remove-DriveLetter($Partition) {
    $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
    if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) {
        Remove-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath "$($p.DriveLetter):\"
    }
}

function New-LinuxSpace($Plan, [string]$Strategy, $State) {
    if ($Plan.Shrink) {
        Set-Status ('Shrinking Windows to {0:N0} GB to make room (can take a few minutes)...' -f ($Plan.NewWindowsSize / 1GB))
        try {
            Resize-Partition -DiskNumber $Plan.DiskNumber -PartitionNumber $Plan.PartitionNumber -Size $Plan.NewWindowsSize
        } catch {
            # Hibernation, paging and restore point files can't be moved, so they limit the shrink.
            throw "Windows could not shrink C: that far ($($_.Exception.Message)). Try a smaller Linux size. If that doesn't help, turn off hibernation (powercfg /h off in an administrator terminal), the paging file and System Protection for C:, then restart and try again. You can turn them back on afterwards."
        }
        $State.WindowsShrunk = $true
        Save-State $State
    } else {
        Write-Log 'Using free space next to C:; Windows keeps its size.'
    }

    if ($Strategy -eq 'prepared') {
        Set-Status 'Creating the Linux partitions...'
        $boot = New-Partition -DiskNumber $Plan.DiskNumber -Offset $Plan.FreeStart -Size 1GB
        $State.Partitions += [pscustomobject]@{ Role = 'boot'; Offset = $boot.Offset; Size = $boot.Size }
        Save-State $State
        Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel $BootLabel -Confirm:$false -Force | Out-Null
        Remove-DriveLetter $boot

        $root = New-Partition -DiskNumber $Plan.DiskNumber -Offset ($Plan.FreeStart + 1GB) -Size ([int64]($Plan.LinuxGB - 1) * 1GB)
        $State.Partitions += [pscustomobject]@{ Role = 'root'; Offset = $root.Offset; Size = $root.Size }
        Save-State $State
        # A placeholder file system: it gives the partition a recognisable label in the
        # Linux installer and stops Windows offering to format a blank partition.
        # The installer replaces it with ext4.
        Format-Volume -Partition $root -FileSystem exFAT -NewFileSystemLabel $RootLabel -Confirm:$false -Force | Out-Null
        Remove-DriveLetter $root
    }

    Set-Status 'Creating the installer partition...'
    $installer = New-Partition -DiskNumber $Plan.DiskNumber -Offset $Plan.InstallerOffset -Size $Plan.InstallerSize
    $State.Partitions += [pscustomobject]@{ Role = 'installer'; Offset = $installer.Offset; Size = $installer.Size }
    Save-State $State
    Format-Volume -Partition $installer -FileSystem FAT32 -NewFileSystemLabel $InstallerLabel -Confirm:$false -Force | Out-Null
    $installer
}

function Copy-Installer($Iso, [string]$Target) {
    $volume = Get-Volume -DriveLetter $Target
    $startFree = $volume.SizeRemaining
    # robocopy instead of Copy-Item: it keeps hidden folders like .disk that the live system needs.
    $proc = Start-Process -FilePath robocopy.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        "$($Iso.Letter):\", "$Target`:\", '/E', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    $null = $proc.Handle
    while (-not $proc.HasExited) {
        $copied = $startFree - (Get-Volume -DriveLetter $Target).SizeRemaining
        $Sync.Status = 'Copying the installer... {0:N1} of {1:N1} GB' -f ($copied / 1GB), ($Iso.Bytes / 1GB)
        Set-ByteProgress ([math]::Max([int64]0, [int64]$copied)) $Iso.Bytes
        Start-Sleep -Milliseconds 700
    }
    if ($proc.ExitCode -ge 8) { throw "Copying the installer files failed (robocopy code $($proc.ExitCode))." }

    # Check file by file. Comparing totals doesn't work: Windows adds its own
    # "System Volume Information" folder to every drive with a letter.
    $sourceRoot = "$($Iso.Letter):\"
    $targetRoot = "$Target`:\"
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File) {
        $relative = $file.FullName.Substring($sourceRoot.Length)
        $copy = Get-Item -LiteralPath (Join-Path $targetRoot $relative) -Force -ErrorAction SilentlyContinue
        if (-not $copy -or $copy.Length -ne $file.Length) { $missing.Add($relative) }
    }
    if ($missing.Count) {
        foreach ($name in $missing) { Write-Log "Not copied: $name" }
        throw "$($missing.Count) installer file(s) did not copy, for example $($missing[0]). The full list is under Show details."
    }
    Write-Log 'Installer files copied and checked.'
    # Offline packages are a convenience: a problem here must not cost a finished copy.
    try { Repair-ShortenedNames $targetRoot } catch { Write-Log "Could not check package names: $($_.Exception.Message)" }
}

# The files the ISO's package indexes say it has, as paths from its root.
function Get-PackagePaths([string]$Root) {
    $dists = Join-Path $Root 'dists'
    if (-not (Test-Path -LiteralPath $dists)) { return }
    $indexes = Get-ChildItem -LiteralPath $dists -Recurse -Force -File | Where-Object { $_.Name -in @('Packages', 'Packages.gz') }
    $paths = foreach ($index in $indexes) {
        $stream = [IO.File]::OpenRead($index.FullName)
        try {
            $input_ = if ($index.Extension -eq '.gz') { New-Object IO.Compression.GZipStream($stream, [IO.Compression.CompressionMode]::Decompress) } else { $stream }
            $text = (New-Object IO.StreamReader($input_)).ReadToEnd()
        } finally { $stream.Dispose() }
        [regex]::Matches($text, '(?m)^Filename:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value -replace '^\./', '' }
    }
    $paths | Sort-Object -Unique
}

# Windows reads an ISO through its Joliet names, which stop at 103 characters, so a very
# long package name arrives shortened (Pop!_OS has two). The indexes still use the real
# name, which FAT32 can hold, so the installer wouldn't find the file until it is renamed.
function Repair-ShortenedNames([string]$Root) {
    $known = @(Get-PackagePaths $Root)
    foreach ($relative in $known) {
        $path = Join-Path $Root ($relative -replace '/', '\')
        if (Test-Path -LiteralPath $path) { continue }
        $folder = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $name = Split-Path $path -Leaf
        $extension = [IO.Path]::GetExtension($name)
        $matches_ = @(Get-ChildItem -LiteralPath $folder -Force -File | Where-Object {
                $_.Extension -eq $extension -and $name.StartsWith($_.BaseName) -and $_.BaseName.Length -ge 40 -and
                (($relative.Substring(0, $relative.Length - $name.Length) + $_.Name) -notin $known)
            })
        # More than one candidate would be a guess.
        if ($matches_.Count -eq 1) {
            Rename-Item -LiteralPath $matches_[0].FullName -NewName $name
            Write-Log "Restored the full name of $name."
        }
    }
}
