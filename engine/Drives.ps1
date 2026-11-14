# --- Drives ----------------------------------------------------------------
# Where Linux can go: C:, another volume to shrink, or free space on any eligible disk.
# A place is named by its disk's GUID and where it starts, because disk and partition
# numbers change. '' means C:, which is what every build before this one used.

$InternalBusTypes = @('NVMe', 'SATA', 'SAS', 'ATA', 'SCSI')     # SCSI includes virtual machines' own disks
$DynamicDiskTypes = @('{5808c8aa-7e8f-42e0-85d2-e1e90434cfb3}', '{af9b60a0-1431-4f62-bc68-3311714a69ad}')
$RecoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$DataReserve = 2GB          # free space left on a drive that isn't Windows'
$MinGapBytes = 10GB         # smaller free space isn't worth listing
$SizeQueryLimitSeconds = 300
$StartupSizeWaitSeconds = 20   # what opening hop waits for that, before showing an estimate

function Get-LetterOf($Partition) {
    if ($Partition.DriveLetter -and $Partition.DriveLetter -ne [char]0) { [string]$Partition.DriveLetter } else { '' }
}

function Get-DiskLabel($Disk) { ($Disk.FriendlyName -replace '\s+', ' ').Trim() }

function Get-DiskGB($Disk) { [int][math]::Round([int64]$Disk.Size / 1GB) }

function Get-PartitionSignature($Partition) {
    try { [Hop.DiskProbe]::ReadSignature($Partition.DiskNumber, [int64]$Partition.Offset) } catch { $null }
}

function Test-HoldsWindows([string]$Letter) {
    $Letter -and (Test-Path -LiteralPath "$Letter`:\Windows\System32\config\SYSTEM" -PathType Leaf)
}

function Test-BitLockerChanging([string]$Letter) {
    try {
        $volume = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$Letter`:'" -ErrorAction SilentlyContinue
        # 2 and 3 are encrypting and decrypting, and 4 and 5 are the same when paused.
        $volume -and (Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus).ConversionStatus -in 2, 3, 4, 5
    } catch { $false }
}

# What Plug and Play says about a device. Empty when Windows doesn't say.
function Get-DeviceProperty([string]$InstanceId, [string]$Key) {
    (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction Stop).Data
}

# Whether a disk is 'internal', 'external' or 'unclear'. A Thunderbolt or USB4 NVMe enclosure reports
# the bus type NVMe, so that can't tell. What can is Windows' removal policy, which it keeps for each
# device, based on whether the bus says the device can be removed: 1 is "expect no removal", and 2 and
# 3 are the two ways of expecting it. It's the slot a drive is tunnelled through that's hot-pluggable,
# so every parent gets asked too. An internal disk on a port with hot-plug turned on comes out as
# external, which is the safe mistake.
function Get-DiskAttachment($Disk) {
    try {
        $drive = Get-CimInstance Win32_DiskDrive -Filter "Index=$($Disk.Number)" -ErrorAction Stop | Select-Object -First 1
        if (-not $drive.PNPDeviceID) { return 'unclear' }
        if ($drive.MediaType -in @('External hard disk media', 'Removable media')) { return 'external' }
        $policy = Get-DeviceProperty $drive.PNPDeviceID 'DEVPKEY_Device_RemovalPolicy'
        if ($null -eq $policy) { return 'unclear' }
        if ([int]$policy -ne 1) { return 'external' }
        $device = $drive.PNPDeviceID
        # The limit is only there so that bad data can't keep this going.
        for ($depth = 0; $depth -lt 32; $depth++) {
            $device = Get-DeviceProperty $device 'DEVPKEY_Device_Parent'
            if (-not $device) { break }
            # Not every parent has a policy, and only a disk's own is needed to go on.
            $policy = try { Get-DeviceProperty $device 'DEVPKEY_Device_RemovalPolicy' } catch { $null }
            if ($null -ne $policy -and [int]$policy -ne 1) { return 'external' }
        }
        'internal'
    } catch {
        Write-Log "Could not tell how disk $($Disk.Number) is attached: $($_.Exception.Message)"
        'unclear'
    }
}

# The one place that says whether Linux can go somewhere. $Partition is the volume to shrink,
# or nothing for free space on the disk. Returns the reason in plain words, or nothing if it can.
#
# Viable means: an internal fixed disk (NVMe, SATA, SAS, ATA or SCSI, and not one Windows expects
# to be unplugged) that's GPT, basic, online, writable and healthy, not RAID, and with no other system on it. To shrink a volume it must also
# be an ordinary data partition with a letter, NTFS, healthy, unlocked, not changing encryption,
# and hold neither another Windows nor Windows' recovery files. Paging files and restore points
# don't refuse a drive: they limit how far it shrinks, which Make room deals with.
#
# With -Windows it's C: itself, which keeps what hop has always checked and nothing more. Its disk
# gets the same disk checks as C:, so an RST laptop still only gets a warning for D:.
function Get-DriveBlocker($Disk, $Partition, [switch]$Windows) {
    $windowsDisk = $Windows -or $Disk.Number -eq (Get-WindowsPartition).DiskNumber
    $name = Get-DiskLabel $Disk

    if ($Disk.PartitionStyle -ne 'GPT') {
        if ($windowsDisk) { return 'The Windows disk uses the old MBR layout. hop only works on GPT disks.' }
        if ($Disk.PartitionStyle -eq 'RAW') { return "$name isn't set up yet. Set it up as GPT in Disk Management, then open hop again." }
        return "$name uses the old MBR layout. hop only works on GPT disks."
    }
    if ($Disk.BusType -in @('File Backed Virtual', 'Spaces')) {
        if ($windowsDisk) { return 'Windows is running from a virtual disk or Storage Spaces, which hop cannot resize.' }
        return "$name is a virtual disk or part of Storage Spaces, which hop cannot use."
    }
    if (-not $windowsDisk) {
        if ($Disk.BusType -eq 'RAID') { return "$name is in RAID mode, which most Linux installers can't see." }
        if ($Disk.BusType -notin $InternalBusTypes) { return "$name is a USB, removable or network drive. Linux has to go on a drive inside this PC." }
        $attachment = Get-DiskAttachment $Disk
        if ($attachment -eq 'external') { return "$name can be unplugged while the PC is running, as a Thunderbolt or USB4 drive can. Linux has to go on a drive inside this PC." }
        if ($attachment -ne 'internal') { return "hop can't tell whether $name is inside this PC or plugged in, as a Thunderbolt or USB4 drive is. Linux has to go on a drive inside this PC." }
    }
    if (-not $Windows) {
        if ($Disk.IsOffline -eq $true) { return "$name is offline. Bring it online in Disk Management, then open hop again." }
        if ($Disk.IsReadOnly -eq $true) { return "$name is read-only." }
        if ($Disk.IsClustered -eq $true) { return "$name belongs to a cluster, which hop cannot use." }
        if ($Disk.HealthStatus -in @('Warning', 'Unhealthy')) { return "Windows reports a problem with $name. Check it before putting Linux on it." }

        $partitions = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)
        if (@($partitions | Where-Object { $_.GptType -in $DynamicDiskTypes }).Count) { return "$name is a dynamic disk, which Linux installers can't use." }
        if (-not $windowsDisk) {
            foreach ($other in $partitions) {
                if (Test-HoldsWindows (Get-LetterOf $other)) { return "$name has another copy of Windows on it. hop leaves that drive alone." }
            }
            if (@(Get-LinuxPartitions $partitions).Count) { return "$name already has Linux on it. Remove that first." }
        }
    }
    if (-not $Partition) { return }

    if ($Windows) {
        $volume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')
        if ($volume.FileSystemType -ne 'NTFS') { return "Drive $env:SystemDrive uses $($volume.FileSystemType). Windows can only shrink NTFS drives." }
        if ($volume.HealthStatus -in @('Warning', 'Unhealthy')) { return "Windows reports a problem with drive $env:SystemDrive. Run chkdsk $env:SystemDrive /f in an administrator terminal, restart, and open hop again." }
        if (Test-BitLockerChanging $env:SystemDrive.TrimEnd(':')) { return "Drive $env:SystemDrive is being encrypted or decrypted by BitLocker. Wait for that to finish, then open hop again." }
        return
    }

    $letter = Get-LetterOf $Partition
    $drive = if ($letter) { "Drive $letter`:" } else { 'This partition' }
    if ($Partition.GptType -eq $RecoveryType) { return "$drive is Windows' recovery partition." }
    if ($Partition.IsSystem -or $Partition.IsBoot -or $Partition.GptType -ne $BasicDataType) { return "$drive is a system partition." }
    $volume = try { $Partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
    # Windows can't see inside a locked BitLocker drive, so it shows as having no file system.
    if ($volume.FileSystemType -ne 'NTFS' -and (Get-PartitionSignature $Partition) -eq 'bitlocker') {
        return "$drive is locked with BitLocker. Unlock it in File Explorer, then open hop again."
    }
    if (-not $letter) { return "$drive has no drive letter." }
    if (Test-BitLockerChanging $letter) { return "$drive is being encrypted or decrypted by BitLocker. Wait for that to finish." }
    if ($volume.FileSystemType -ne 'NTFS') { return "$drive uses $(if ($volume.FileSystemType) { $volume.FileSystemType } else { 'an unknown format' }). Windows can only shrink NTFS drives." }
    if ($volume.HealthStatus -in @('Warning', 'Unhealthy')) { return "Windows reports a problem with drive $letter`:. Run chkdsk $letter`: /f in an administrator terminal, then open hop again." }
    if (Test-HoldsWindows $letter) { return "$drive has another copy of Windows on it." }
    if (Test-Path -LiteralPath "$letter`:\Recovery\WindowsRE\winre.wim") { return "$drive holds Windows' recovery files." }
}

# Unallocated space big enough to list, each with the partition it follows.
function Get-DiskGaps($Disk, $Partitions) {
    $start = [int64]1MB
    $before = $null
    foreach ($partition in @($Partitions | Sort-Object Offset) + $null) {
        # GPT keeps a backup at the end.
        $end = if ($partition) { [int64]$partition.Offset } else { [int64]$Disk.Size - 2MB }
        $aligned = [int64]([math]::Ceiling($start / 1MB) * 1MB)
        if ($end - $aligned -ge $MinGapBytes) {
            [pscustomobject]@{ Offset = $aligned; Size = [int64]($end - $aligned); After = $before }
        }
        if ($partition) {
            $start = [int64]($partition.Offset + $partition.Size)
            $before = $partition
        }
    }
}

function New-DriveRow([string]$Id, [string]$Kind, $Disk, [string]$Letter, [string]$Title, [string]$Blocker, [bool]$OnWindowsDisk) {
    [pscustomobject]@{
        Id = $Id; Kind = $Kind; Letter = $Letter; Title = $Title; Blocker = $Blocker
        DiskName = Get-DiskLabel $Disk; DiskGB = Get-DiskGB $Disk; OnWindowsDisk = $OnWindowsDisk
        Estimated = $true; SizeGB = 0; UsedGB = 0; FreeGB = 0; TailFreeGB = 0; UsableGB = 0; StuckGB = 0; ShrinkBlocker = $null; BlockerKind = 'unknown'
    }
}

# Every place Linux could go, and every place it can't with the reason. Working out how far a
# volume can really shrink can take minutes on a big drive, so this estimates from its free
# space, and Get-DriveSpace gets the real figure once it's chosen.
function Get-DriveTargets {
    $c = Get-WindowsPartition
    foreach ($disk in @(Get-Disk | Sort-Object { $_.Number -ne $c.DiskNumber }, Number)) {
        $onWindowsDisk = $disk.Number -eq $c.DiskNumber
        $diskBlocker = Get-DriveBlocker $disk $null
        # A disk that's refused is one row, except Windows' own: C: has rules of its own.
        if ($diskBlocker -and -not $onWindowsDisk) {
            New-DriveRow "disk:$($disk.Number)" 'disk' $disk '' (Get-DiskLabel $disk) $diskBlocker $onWindowsDisk
            continue
        }
        $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Sort-Object Offset)
        $usable = @{}
        foreach ($partition in $partitions) {
            $isWindows = $onWindowsDisk -and [int64]$partition.Offset -eq [int64]$c.Offset
            $volume = try { $partition | Get-Volume -ErrorAction SilentlyContinue } catch { $null }
            $letter = Get-LetterOf $partition
            if (-not $isWindows -and ($partition.GptType -ne $BasicDataType -or $partition.IsHidden)) { continue }
            if (-not $letter -and (Get-PartitionSignature $partition) -ne 'bitlocker') { continue }

            $blocker = if ($isWindows) { Get-DriveBlocker $disk $partition -Windows } else { Get-DriveBlocker $disk $partition }
            $id = if ($isWindows) { '' } else { "volume:$($disk.Guid):$([int64]$partition.Offset)" }
            $title = if ($letter) { "Drive $letter`:" } else { 'Locked drive' }
            $row = New-DriveRow $id 'volume' $disk $letter $title $blocker $onWindowsDisk
            $row.SizeGB = [int][math]::Floor($partition.Size / 1GB)
            if ($volume) {
                $row.UsedGB = [int][math]::Ceiling(($volume.Size - $volume.SizeRemaining) / 1GB)
                $row.FreeGB = [int][math]::Floor($volume.SizeRemaining / 1GB)
            }
            if (-not $blocker) {
                $usable[[int64]$partition.Offset] = $true
                $tail = Get-TailFree $partition
                $row.TailFreeGB = [int][math]::Floor($tail / 1GB)
                $reserve = if ($isWindows) { $WindowsReserve } else { $DataReserve }
                # The reserve is about what's inside the drive, not the free space after it.
                $row.UsableGB = [int][math]::Floor(($tail + [math]::Max([int64]0, [int64]($volume.SizeRemaining - $reserve))) / 1GB)
            }
            $row
        }
        if ($diskBlocker) { continue }
        foreach ($gap in @(Get-DiskGaps $disk $partitions)) {
            # Free space right after a volume is part of that volume's row.
            if ($gap.After -and $usable[[int64]$gap.After.Offset]) { continue }
            $row = New-DriveRow "gap:$($disk.Guid):$($gap.Offset)" 'gap' $disk '' 'Free space' $null $onWindowsDisk
            $row.TailFreeGB = $row.FreeGB = $row.UsableGB = [int][math]::Floor($gap.Size / 1GB)
            $row.Estimated = $false
            $row
        }
    }
}

# The real figures for one place, for showing once it's chosen.
function Get-DriveSpace([string]$Target) {
    $row = @(Get-DriveTargets) | Where-Object Id -eq $Target | Select-Object -First 1
    if (-not $row) { throw "That drive isn't there any more. Open hop again." }
    if ($row.Blocker -or $row.Kind -ne 'volume') { return $row }
    $space = Get-SpaceInfo $Target -Join
    $row.UsableGB = $space.UsableGB
    $row.TailFreeGB = [int][math]::Floor($space.TailFree / 1GB)
    $row.StuckGB = Get-StuckGB ([int64]$row.FreeGB * 1GB) $space $space.Reserve
    if ($row.StuckGB -ge 20) {
        $row.ShrinkBlocker = Get-ShrinkBlocker $space.Partition -Reuse
        $row.BlockerKind = Get-BlockerKind $row.ShrinkBlocker
    }
    $row.Estimated = $false
    $row
}

# Turns a place's name back into what's there now.
function Resolve-Target([string]$Target) {
    if (-not $Target) { return [pscustomobject]@{ Kind = 'volume'; IsWindows = $true; Partition = Get-WindowsPartition; Disk = $null } }
    $parts = $Target -split ':'
    $disk = Get-Disk | Where-Object Guid -eq $parts[1] | Select-Object -First 1
    if (-not $disk) { throw "That drive isn't there any more. Open hop again." }
    if ($parts[0] -eq 'volume') {
        $partition = Get-PartitionAt $disk.Number ([int64]$parts[2])
        if (-not $partition) { throw "That drive isn't there any more. Open hop again." }
        return [pscustomobject]@{ Kind = 'volume'; IsWindows = $false; Partition = $partition; Disk = $disk }
    }
    $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)
    $gap = @(Get-DiskGaps $disk $partitions) | Where-Object { [int64]$_.Offset -eq [int64]$parts[2] } | Select-Object -First 1
    if (-not $gap) { throw "That free space isn't there any more. Open hop again." }
    # Shaped like a volume of no size, so the plan treats it as free space after one.
    $partition = [pscustomobject]@{ DiskNumber = $disk.Number; PartitionNumber = 0; Offset = [int64]$gap.Offset; Size = [int64]0 }
    [pscustomobject]@{ Kind = 'gap'; IsWindows = $false; Partition = $partition; Disk = $disk; Gap = $gap }
}

function Assert-DriveUsable([string]$Target) {
    $place = Resolve-Target $Target
    if ($place.IsWindows) {
        $reason = Get-DriveBlocker (Get-Disk -Number $place.Partition.DiskNumber) $place.Partition -Windows
    } elseif ($place.Kind -eq 'gap') {
        $reason = Get-DriveBlocker $place.Disk $null
    } else {
        $reason = Get-DriveBlocker $place.Disk $place.Partition
    }
    if ($reason) { throw $reason }
}

# hop keeps its state and logs on C: whichever drive Linux goes on, and a state file that can't be
# written is a setup that can't be undone. It only takes a little, but a truly full C: hasn't got it.
function Assert-StateRoom {
    $free = ([IO.DriveInfo][IO.Path]::GetPathRoot($StateDir)).AvailableFreeSpace
    if ($free -lt 50MB) { throw "Drive $($StateDir.Substring(0, 2)) is completely full, and hop needs a little room there to keep track of what it does. Free up 50 MB and try again. Linux can still go on another drive." }
}

# Asking Windows how far a volume can shrink has no limit of its own, and takes longer the bigger and fuller
# the drive is: issue #17 waited 45 minutes. So it runs in a separate runspace, and there's only ever one for a
# drive. A caller that only reads, with -Join, waits for the one already running instead of asking again behind
# it, and may wait less than the limit, leaving it running for the next. It also takes an answer that came while
# nobody was waiting, if that's recent. Others, such as Make room and Install, which change the drive, wait for
# it to finish and ask afresh, so they never get a figure from before. Past the limit it's stopped, whoever was
# waiting, and until it has stopped nobody asks again.
$SizeQueries = @{}
$SizeAnswered = @{}   # each drive's last answer: when it was asked for and when it came, for Get-ShrinkBlocker
$SizeQuerySlowSeconds = 5
$SizeAnswerFreshSeconds = 120

function Get-SizeQueryKey($Partition) { "$($Partition.DiskNumber):$($Partition.PartitionNumber)" }

function Start-SizeQuery($Partition) {
    $session = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $session.ExecutionPolicy = 'Bypass'
    $runspace = [runspacefactory]::CreateRunspace($session)
    $runspace.Open()
    $query = [powershell]::Create()
    $query.Runspace = $runspace
    # When it answered goes with the answer, because nobody may be waiting when it comes.
    [void]$query.AddScript('param($Disk, $Number) $size = Get-PartitionSupportedSize -DiskNumber $Disk -PartitionNumber $Number; if ($size) { [pscustomobject]@{ SizeMin = [int64]$size.SizeMin; SizeMax = [int64]$size.SizeMax; Finished = [DateTime]::UtcNow } }').AddArgument($Partition.DiskNumber).AddArgument($Partition.PartitionNumber)
    [pscustomobject]@{ Query = $query; Runspace = $runspace; Running = $query.BeginInvoke(); Started = [DateTime]::UtcNow; Stopped = $false }
}

function Close-SizeQuery($Entry) {
    try { $Entry.Query.Dispose() } catch { }
    try { $Entry.Runspace.Dispose() } catch { }
}

function Get-SizeQuerySecondsLeft($Entry) { [math]::Max(0, $SizeQueryLimitSeconds - ([DateTime]::UtcNow - $Entry.Started).TotalSeconds) }

function New-SizeQueryError([string]$Message, [string]$Id) {
    $e = New-Object InvalidOperationException $Message
    $e.Data['ErrorId'] = $Id
    $e
}

# In short waits, so that cancelling or closing hop isn't held up behind one long one.
function Wait-SizeHandle($Handle, [double]$Seconds) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $left = ($until - [DateTime]::UtcNow).TotalMilliseconds
        if ($Handle.WaitOne([int][math]::Max(0, [math]::Min(250, $left)))) { return $true }
    } while ($left -gt 250)
    $false
}

# Waits up to $Seconds for it, and says what it's waiting for once that's noticeable. True when it's finished.
function Wait-SizeQuery($Entry, [double]$Seconds, $Partition) {
    $handle = $Entry.Running.AsyncWaitHandle
    $first = [math]::Min($Seconds, $SizeQuerySlowSeconds)
    if (Wait-SizeHandle $handle $first) { return $true }
    if ($Seconds -le $first) { return $false }
    $before = $Sync.Status; $percent = $Sync.Percent
    $letter = Get-LetterOf $Partition
    $Sync.Status = "Asking Windows how much room $(if ($letter) { "drive $letter`:" } else { 'the drive' }) can give up. On a big drive this can take a few minutes..."
    try { Wait-SizeHandle $handle ($Seconds - $first) } finally { $Sync.Status = $before; $Sync.Percent = $percent }
}

# Its answer, with when it was asked for and when it came. Throws Windows' reason if it gave one.
function Receive-SizeQuery($Entry, [string]$Key) {
    $SizeQueries.Remove($Key)
    try {
        $result = $Entry.Query.EndInvoke($Entry.Running) | Select-Object -First 1
        if ($Entry.Query.Streams.Error.Count) {
            # Kept, so a caller can tell Windows' reasons apart without reading its words, which change with its language.
            $err = $Entry.Query.Streams.Error[0]
            $err.Exception.Data['ErrorId'] = $err.FullyQualifiedErrorId
            throw $err.Exception
        }
        if (-not $result) { throw 'Windows didn''t say how far this drive can shrink.' }
        $finished = if ($result.Finished) { [DateTime]$result.Finished } else { [DateTime]::UtcNow }
        [pscustomobject]@{ Result = $result; Started = $Entry.Started; Finished = $finished }
    } finally {
        Close-SizeQuery $Entry
    }
}

function Stop-SizeQuery($Entry, $Partition) {
    if (-not $Entry.Stopped) {
        Write-Log "Windows didn't say how far drive $(Get-LetterOf $Partition): shrinks within $SizeQueryLimitSeconds seconds, so hop stopped asking."
        [void]$Entry.Query.BeginStop($null, $null)
        $Entry.Stopped = $true
    }
    New-SizeQueryError "Windows took too long to work out how much space this drive can give up. Try again in a few minutes." 'hop.SizeTimeout'
}

function Get-SupportedSize($Partition, [double]$WaitSeconds = $SizeQueryLimitSeconds, [switch]$Join) {
    $key = Get-SizeQueryKey $Partition
    $entry = $SizeQueries[$key]
    if ($entry -and $entry.Running.IsCompleted) {
        # It finished while nobody was waiting. A reader takes that if it's recent, and anything else asks again.
        if ($entry.Stopped) { Close-SizeQuery $entry; $SizeQueries.Remove($key) }
        else {
            $got = try { Receive-SizeQuery $entry $key } catch { $null }
            if ($Join -and $got -and ([DateTime]::UtcNow - $got.Finished).TotalSeconds -le $SizeAnswerFreshSeconds) {
                $SizeAnswered[$key] = $got
                return $got.Result
            }
        }
        $entry = $null
    }
    if ($entry -and -not $Join) {
        # Its answer could be from before this caller changed the drive, so it only waits for it to be done.
        if (-not (Wait-SizeQuery $entry (Get-SizeQuerySecondsLeft $entry) $Partition)) { throw (Stop-SizeQuery $entry $Partition) }
        try { [void](Receive-SizeQuery $entry $key) } catch { }
        $entry = $null
    }
    if (-not $entry) {
        $entry = Start-SizeQuery $Partition
        $SizeQueries[$key] = $entry
    }
    $left = Get-SizeQuerySecondsLeft $entry
    if (-not (Wait-SizeQuery $entry ([math]::Min($WaitSeconds, $left)) $Partition)) {
        if ($WaitSeconds -lt $left) {
            throw (New-SizeQueryError "Windows is still working out how much space this drive can give up." 'hop.SizePending')
        }
        throw (Stop-SizeQuery $entry $Partition)
    }
    $got = Receive-SizeQuery $entry $key
    $SizeAnswered[$key] = $got
    $got.Result
}

# Disks hop could have used. Labels on a USB drive mean nothing here, because it could have
# come from another PC. Only the checks in this file decide what's used for a new install.
function Get-HopDisks {
    $windowsDisk = (Get-WindowsPartition).DiskNumber
    @(Get-Disk | Where-Object { $_.Number -eq $windowsDisk -or $_.BusType -in $InternalBusTypes })
}

# The disk a setup is on. Numbers change between restarts, especially with a second disk, so
# it's found by its GUID. A setup from before this was recorded can only be on the Windows disk.
function Get-StateDisk($State) {
    if ($State -and $State.DiskGuid) {
        return (Get-Disk | Where-Object Guid -eq $State.DiskGuid | Select-Object -First 1).Number
    }
    (Get-WindowsPartition).DiskNumber
}

# False when the installer's easy option wouldn't use hop's space: Ubuntu's picks the largest free
# space and Mint's the biggest, on any disk. Called once the partitions exist, so what's left free
# beside them counts too.
function Test-AlongsideFindsLinux($Plan) {
    $linux = [int64]$Plan.LinuxGB * 1GB
    foreach ($disk in @(Get-Disk | Where-Object PartitionStyle -eq 'GPT')) {
        $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)
        foreach ($gap in @(Get-DiskGaps $disk $partitions)) {
            if ($disk.Number -eq $Plan.DiskNumber -and [int64]$gap.Offset -eq [int64]$Plan.FreeStart) { continue }
            if ($gap.Size -ge $linux) { return $false }
        }
    }
    $true
}

# --- Where the ISO goes ------------------------------------------------------

# Drives with room for the download. A USB drive is fine here, because the ISO is only read while
# its files are copied, unlike Linux itself, which has to be inside the PC.
function Get-DownloadDrives {
    $default = try { [IO.Path]::GetPathRoot((Get-DownloadFolder)).TrimEnd('\').TrimEnd(':') } catch { '' }
    foreach ($volume in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -in @('Fixed', 'Removable') -and $_.FileSystemType -in @('NTFS', 'exFAT', 'ReFS') })) {
        [pscustomobject]@{
            Letter = [string]$volume.DriveLetter
            FreeGB = [int][math]::Floor($volume.SizeRemaining / 1GB)
            IsDefault = [string]$volume.DriveLetter -eq $default
        }
    }
}

# --- Linux left on another disk ----------------------------------------------
# The Windows disk is always looked at for another Linux. Other disks are only looked at once
# hop has put Linux there: an ext4 disk of someone's files is not for offering to delete.

$LinuxDisksPath = Join-Path $StateDir 'linux-disks.json'

function Get-LinuxDisks {
    if (-not (Test-Path -LiteralPath $LinuxDisksPath)) { return }
    # Windows PowerShell passes a JSON list along as one object, so it's taken apart here.
    try { Get-Content -LiteralPath $LinuxDisksPath -Raw | ConvertFrom-Json | ForEach-Object { $_ } } catch { Write-Log "Could not read $LinuxDisksPath`: $($_.Exception.Message)" }
}

function Set-LinuxDisks([string[]]$Guids) {
    if (-not $Guids) { Remove-Item -LiteralPath $LinuxDisksPath -Force -ErrorAction SilentlyContinue; return }
    Write-StateFile $LinuxDisksPath (ConvertTo-Json -InputObject @($Guids))
}

function Add-LinuxDisk([string]$Guid) {
    Set-LinuxDisks (@(@(Get-LinuxDisks) + $Guid) | Where-Object { $_ } | Sort-Object -Unique)
}
