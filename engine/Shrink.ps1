# --- Shrinking a drive from outside Windows ------------------------------------
# Windows can't move some of its own files, $Mft::$BITMAP among them, so on some PCs it can release almost none of a
# drive with plenty free. Outside Windows, nothing has them open, and ntfsresize moves them, as GParted does. hop's
# shrink image, built by tools/shrink, is Fedora's signed shim, GRUB and kernel with a small initramfs that does only
# that: it's started once, through BootNext, shrinks the drive, writes what happened to the EFI partition and restarts
# into Windows, which checks the drive as it starts. hop then finds the space after the drive, as Make room leaves it.
#
# Everything that can be checked from Windows is checked before the restart, and the image checks again before it
# writes anything. A refusal at either point changes nothing.

$ShrinkFolder = 'EFI\hop-shrink'   # on Windows' EFI partition
$ShrinkFiles = @('shimx64.efi', 'grubx64.efi', 'vmlinuz', 'initrd.img')
$ShrinkStatePath = Join-Path $StateDir 'shrink.json'
$ShrinkCache = Join-Path $StateDir 'shrink-image'
# Not hop's install marker, so nothing that tidies the installer's entries mistakes it for one, or leaves it.
$ShrinkEntryMarker = '(hop shrink)'
# The release asset, and each file's checksum, as tools/shrink/build.sh wrote them in manifest.txt. Until a release has
# one, this build offers nothing. A test build can name a local zip here: see tools/vm.
$ShrinkImage = [pscustomobject]@{
    Url    = ''
    Sha256 = ''
    Files  = @{}
}

function Test-ShrinkAvailable {
    $ShrinkImage.Url -and $ShrinkImage.Sha256 -and $ShrinkImage.Files.Count -eq $ShrinkFiles.Count -and (Test-Uefi)
}

# The menu Fedora's GRUB reads next to itself. It starts the one entry at once. The line says exactly what to shrink and
# from what size, so a drive that changed since can't be shrunk by an old plan. Partition IDs in lower case, as blkid has them.
function Get-ShrinkGrubConfig([string]$PartitionGuid, [int64]$Was, [int64]$NewSize, [string]$EspGuid, [string]$Id, [string]$Extra = '') {
    $part = $PartitionGuid.Trim('{}').ToLowerInvariant()
    $esp = $EspGuid.Trim('{}').ToLowerInvariant()
    $line = "hop.part=$part hop.was=$Was hop.size=$NewSize hop.esp=$esp hop.id=$Id quiet loglevel=3$(if ($Extra) { " $Extra" })"
    $folder = $ShrinkFolder -replace '\\', '/'
    @(
        'set timeout=0'
        "menuentry 'hop: make room for Linux' {"
        "    linux /$folder/vmlinuz $line"
        "    initrd /$folder/initrd.img"
        '}'
    )
}

function Read-ShrinkState {
    if (-not (Test-Path -LiteralPath $ShrinkStatePath)) { return }
    try { Get-Content -LiteralPath $ShrinkStatePath -Raw | ConvertFrom-Json } catch { Write-Log "Could not read the shrink's record: $($_.Exception.Message)"; $null }
}

function Remove-ShrinkState { Remove-Item -LiteralPath $ShrinkStatePath -Force -ErrorAction SilentlyContinue }

# The new size for a drive, so that $WantedBytes lies after it, counting free space already there. Whole MiB, as the image wants.
function Get-ShrinkTarget($Partition, [int64]$WantedBytes) {
    $need = [int64]$WantedBytes - [int64](Get-TailFree $Partition)
    if ($need -le 0) { return [int64]$Partition.Size }
    [int64]([math]::Floor(([int64]$Partition.Size - $need) / 1MB) * 1MB)
}

# Why this drive can't be shrunk from outside Windows, in plain words, or nothing. Only what's known before downloading.
function Get-OfflineShrinkProblem([string]$Drive, [int64]$WantedBytes, [int64]$KeepFreeBytes = 0) {
    $room = Get-RoomDrive $Drive
    if (-not (Test-Uefi)) { return 'This PC starts in legacy BIOS mode, which hop can''t start its shrink tool from.' }
    $c = Get-Partition -DriveLetter $room.TrimEnd(':') -ErrorAction SilentlyContinue
    $volume = if ($c) { Get-VolumeOf $c }
    if (-not $c -or -not $volume) { return "hop can't find drive $room." }
    if ($volume.FileSystemType -ne 'NTFS') { return "Drive $room isn't NTFS, which is all hop's shrink tool knows." }
    if ((Get-PartitionSignature $c) -eq 'bitlocker' -or (Test-BitLockerChanging $room.TrimEnd(':'))) {
        return "Drive $room is encrypted, and Linux can't shrink an encrypted drive. Turn off **Device encryption** or **BitLocker** for it in Settings, wait until it says it's decrypted, which can take an hour or more, then try again. You can turn it back on afterwards."
    }
    if (Test-RestartPending) { return 'Windows is waiting to restart for an update. Restart and let it finish first, so the update isn''t in the middle of something when the drive shrinks.' }
    if (Test-VolumeDirty $room) { return "Windows has marked drive $room to be checked. Restart and let it finish checking, then try again." }
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($battery -and $battery.BatteryStatus -eq 1) { return 'Plug in the charger first. Losing power while the drive shrinks could damage it.' }
    $new = Get-ShrinkTarget $c $WantedBytes
    $used = [int64]$volume.Size - [int64]$volume.SizeRemaining
    $least = $used + $WindowsReserve + $KeepFreeBytes + $ShrinkMargin
    if ($new -lt $least) { return ('Drive {0} has {1:N0} GB of files, and needs {2:N0} GB more free for that much Linux.' -f $room, ($used / 1GB), (($least - $new) / 1GB)) }
}

# From WMI, not fsutil, whose words change with Windows' language. Not being able to tell isn't dirty: the image checks again.
function Test-VolumeDirty([string]$Drive) {
    $volume = Get-CimInstance Win32_Volume -Filter "DriveLetter='$(Get-RoomDrive $Drive)'" -ErrorAction SilentlyContinue | Select-Object -First 1
    [bool]($volume -and $volume.DirtyBitSet)
}

# The image, downloaded once and checked file by file. Throws if it can't be had or doesn't match.
function Get-ShrinkImageFolder {
    $folder = Join-Path $ShrinkCache 'hop-shrink'
    if (Test-ShrinkImage $folder) { return $folder }
    if (-not (Test-ShrinkAvailable)) { throw "This build of hop doesn't include its shrink tool." }
    if (Test-Path -LiteralPath $ShrinkCache) { Remove-Item -LiteralPath $ShrinkCache -Recurse -Force }
    New-Item -ItemType Directory -Path $ShrinkCache -Force | Out-Null
    $zip = Join-Path $ShrinkCache 'hop-shrink.zip'
    Set-Status 'Downloading hop''s shrink tool...'
    if ($ShrinkImage.Url -notmatch '^https://') { Copy-Item -LiteralPath $ShrinkImage.Url -Destination $zip }
    else { Invoke-Download ([pscustomobject]@{ Url = $ShrinkImage.Url; Sha256 = $ShrinkImage.Sha256 }) $zip }
    if (-not (Test-FileSha256 $zip $ShrinkImage.Sha256)) { throw 'hop''s shrink tool downloaded damaged. Try again.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $ShrinkCache)
    Remove-Item -LiteralPath $zip -Force
    if (-not (Test-ShrinkImage $folder)) { throw 'hop''s shrink tool isn''t what this build of hop expects.' }
    $folder
}

function Test-ShrinkImage([string]$Folder) {
    if (-not $ShrinkImage.Files.Count) { return $false }
    foreach ($name in $ShrinkFiles) {
        $path = Join-Path $Folder $name
        if (-not (Test-Path -LiteralPath $path) -or -not (Test-FileSha256 $path $ShrinkImage.Files[$name])) { return $false }
    }
    $true
}

function Test-FileSha256([string]$Path, [string]$Expected) {
    $Expected -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected.ToUpperInvariant()
}

# The firmware's entries for the shrink tool.
function Get-ShrinkEntries { @([Hop.Firmware]::FindEntries($ShrinkEntryMarker)) }

# Takes away what the shrink left: its entries, its folder on the EFI partition and the one-time start, if it's still ours.
function Clear-OfflineShrink {
    foreach ($number in Get-ShrinkEntries) {
        try {
            if ([Hop.Firmware]::BootNext() -eq $number) { [Hop.Firmware]::ClearBootNext() }
            [Hop.Firmware]::DeleteBootEntry($number)
            Write-Log ('Removed the shrink tool''s startup entry Boot{0:X4}.' -f $number)
        } catch { Write-Log ('Could not remove startup entry Boot{0:X4}: {1}' -f $number, $_.Exception.Message) }
    }
    try {
        Use-Esp {
            param($root)
            $path = Join-Path $root $ShrinkFolder
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; Write-Log "Removed \$ShrinkFolder." }
        }
    } catch { Write-Log "Could not remove \$ShrinkFolder from the EFI partition: $($_.Exception.Message)" }
}

# The image's words, as a sentence of hop's.
function ConvertTo-Sentence([string]$Text) {
    $text = $Text.Trim().TrimEnd('.')
    if (-not $text) { return '' }
    $text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1) + '.'
}

# What the image wrote to the EFI partition: its first line is the attempt's ID, then ok or why not, then its log.
function Read-ShrinkResult {
    try {
        Use-Esp {
            param($root)
            $path = Join-Path (Join-Path $root $ShrinkFolder) 'result.txt'
            if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) }
        }
    } catch { Write-Log "Could not read what the shrink tool wrote: $($_.Exception.Message)" }
}

# Puts the image on the EFI partition, with a menu for this drive and size, adds its startup entry and sets it for the
# next start only. Then restarts. Says 'restarting'.
function Start-OfflineShrink([string]$Drive, [int]$WantedLinuxGB, [int64]$WantedBytes, [int64]$KeepFreeBytes = 0) {
    $room = Get-RoomDrive $Drive
    $problem = Get-OfflineShrinkProblem $room $WantedBytes $KeepFreeBytes
    if ($problem) { throw $problem }
    Assert-FirmwareAccess
    $image = Get-ShrinkImageFolder
    if (Test-SecureBoot) {
        $signedBy = @(Get-UefiAuthorities (Get-EfiSignature (Join-Path $image 'shimx64.efi')))
        $db = Get-SecureBootDb
        if ($signedBy.Count -and $db -and $db.Contains('Microsoft') -and -not @($signedBy | Where-Object { $db.Contains($_) }).Count) {
            throw "This PC's Secure Boot doesn't trust Microsoft's third-party certificate, which hop's shrink tool is signed with. Some BIOS settings have an option to allow it. Otherwise turn off Secure Boot, then try again."
        }
    }
    $c = Get-Partition -DriveLetter $room.TrimEnd(':')
    $new = Get-ShrinkTarget $c $WantedBytes
    if ($new -ge [int64]$c.Size) { throw "Drive $room already has that much free after it." }
    $esp = Get-WindowsEsp
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $menu = Get-ShrinkGrubConfig ([string]$c.Guid) ([int64]$c.Size) $new ([string]$esp.Guid) $id

    Set-Status 'Putting hop''s shrink tool on the EFI partition...'
    Clear-OfflineShrink
    Use-Esp {
        param($root)
        $bytes = [int64](Get-ChildItem -LiteralPath $image -File | Measure-Object -Property Length -Sum).Sum + 2MB
        $free = ([IO.DriveInfo]$root).AvailableFreeSpace
        if ($free -lt $bytes) { throw ('The EFI system partition is too full: hop''s shrink tool needs {0:N0} MB there and {1:N0} MB is free.' -f ($bytes / 1MB), ($free / 1MB)) }
        $folder = Join-Path $root $ShrinkFolder
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        foreach ($name in $ShrinkFiles) { Copy-Item -LiteralPath (Join-Path $image $name) -Destination (Join-Path $folder $name) -Force }
        Set-Content -LiteralPath (Join-Path $folder 'grub.cfg') -Encoding ASCII -Value $menu
        # What the firmware will read has to be what was checked.
        if (-not (Test-ShrinkImage $folder)) { throw 'hop''s shrink tool didn''t copy to the EFI partition intact.' }
    }
    $sector = (Get-Disk -Number $esp.DiskNumber).LogicalSectorSize
    $number = [Hop.Firmware]::CreateBootEntry("Make room for Linux $ShrinkEntryMarker", $esp.PartitionNumber,
        [int64]($esp.Offset / $sector), [int64]($esp.Size / $sector), $esp.Guid, "\$ShrinkFolder\shimx64.efi")
    Write-Log ('Added startup entry Boot{0:X4} for the shrink tool.' -f $number)

    $state = [pscustomobject]@{
        Id = $id; Drive = $room; DiskNumber = [int]$c.DiskNumber; Offset = [int64]$c.Offset; Was = [int64]$c.Size; NewSize = $new
        WantedLinuxGB = $WantedLinuxGB; BootNumber = $number; Saved = (Get-Date).ToString('s'); BootedBefore = (Get-LastBoot).ToString('o')
    }
    Write-StateFile $ShrinkStatePath ($state | ConvertTo-Json)
    Write-Log ('Shrinking drive {0} from {1:N1} GB to {2:N1} GB at the next start, from outside Windows.' -f $room, ($c.Size / 1GB), ($new / 1GB))
    try {
        [Hop.Firmware]::SetBootNext($number)
        $Sync.RoomRestarting = $true
        $state | Add-Member -NotePropertyName CopyFolder -NotePropertyValue (Register-RunAfterRestart) -Force
        Write-StateFile $ShrinkStatePath ($state | ConvertTo-Json)
        Set-Status 'Restarting...'
        Invoke-Shutdown '/r', '/t', '0'
    } catch {
        $Sync.RoomRestarting = $false
        Clear-OfflineShrink
        Remove-ShrinkState
        throw
    }
    'restarting'
}

# After the restart: what happened, from the drive's real size and the image's own words. A drive that shrank keeps
# the space after it for Linux, recorded as Make room records it, so the install takes it and Undo gives it back.
# Says a short result: 'shrunk', or why not in plain words.
function Complete-OfflineShrink {
    $state = Read-ShrinkState
    if (-not $state) { return }
    $text = Read-ShrinkResult
    if ($text) { foreach ($line in ($text -split "`r?`n" | Where-Object { $_ })) { Write-Log "shrink tool: $line" } }
    $lines = @($text -split "`r?`n")
    $mine = $lines.Count -gt 1 -and $lines[0] -eq "id $($state.Id)"
    $said = if ($mine) { $lines[1] } else { $null }
    $c = Get-PartitionAt ([int]$state.DiskNumber) ([int64]$state.Offset)
    $size = if ($c) { [int64]$c.Size } else { $null }
    Clear-OfflineShrink
    Unregister-ResumeTask
    # Make room's own restore task stays while its settings are off.
    if (-not (Read-RoomState)) { Remove-RoomTask $RestoreTaskName }
    Remove-RestartCopy $state.CopyFolder
    Remove-ShrinkState
    if ($null -ne $size -and $size -eq [int64]$state.NewSize) {
        # The earliest size is what Undo gives back, if Make room shrank it before this.
        $earlier = Read-RoomAside
        $before = if ($earlier -and [int64]$earlier.Offset -eq [int64]$state.Offset -and [int]$earlier.DiskNumber -eq [int]$state.DiskNumber) { [int64]$earlier.SizeBefore } else { [int64]$state.Was }
        Write-StateFile $AsidePath (ConvertTo-Json -InputObject ([pscustomobject]@{
            DiskNumber = [int]$state.DiskNumber; Offset = [int64]$state.Offset; SizeBefore = $before; Drive = $state.Drive
            WantedLinuxGB = [int]$state.WantedLinuxGB; Saved = (Get-Date).ToString('s')
        }))
        Write-Log ('Drive {0} is {1:N1} GB now, and the space after it is set aside for Linux.' -f $state.Drive, ($size / 1GB))
        Remove-Item -LiteralPath $TriedPath -Force -ErrorAction SilentlyContinue
        return 'shrunk'
    }
    if ($null -ne $size -and $size -ne [int64]$state.Was) {
        # Neither what it was nor what was planned: say so plainly, and leave it for a person to look at.
        Write-Log ('Drive {0} is {1:N1} GB, which is neither the size it was nor the one planned.' -f $state.Drive, ($size / 1GB))
        return "Drive $($state.Drive) changed size, but not to what hop planned. Nothing else was changed. Copy the report and send it to hop's GitHub page."
    }
    if ($said -like 'partial:*') { return "hop's shrink tool stopped part way through drive $($state.Drive). $(ConvertTo-Sentence $said.Substring(8)) Copy the report and send it to hop's GitHub page." }
    if ($said -like 'failed:*') { return "hop's shrink tool left drive $($state.Drive) as it was. $(ConvertTo-Sentence $said.Substring(7))" }
    if (-not $text) { return "This PC started Windows without hop's shrink tool saying what it did, and drive $($state.Drive) is the size it was. Secure Boot or the BIOS may have stopped the tool starting." }
    "hop's shrink tool didn't say it finished, and drive $($state.Drive) is the size it was."
}

# 'waiting' when the restart hasn't happened yet, 'done' once it has, or nothing.
function Get-ShrinkPhase {
    $state = Read-ShrinkState
    if (-not $state) { return }
    $booted = try { (Get-LastBoot).ToString('o') } catch { $null }
    if ($booted -and $booted -eq [string]$state.BootedBefore) { 'waiting' } else { 'done' }
}

# Restarts into the shrink tool that's already set up.
function Restart-IntoShrink {
    $state = Read-ShrinkState
    if (-not $state) { throw 'hop''s shrink tool isn''t set up any more. Click Make room again.' }
    [Hop.Firmware]::SetBootNext([int]$state.BootNumber)
    $Sync.RoomRestarting = $true
    try { Invoke-Shutdown '/r', '/t', '0' } catch { $Sync.RoomRestarting = $false; throw }
}

# Calls it off before the restart: nothing has changed on the drive.
function Stop-OfflineShrink {
    $state = Read-ShrinkState
    Clear-OfflineShrink
    Unregister-ResumeTask
    if (-not (Read-RoomState)) { Remove-RoomTask $RestoreTaskName }
    if ($state) { Remove-RestartCopy $state.CopyFolder }
    Remove-ShrinkState
    Write-Log 'Called off shrinking the drive from outside Windows.'
}

# What the screen lists before the restart. Throws why not, when it can't.
function Get-OfflineShrinkSteps([string]$Drive, [int64]$WantedBytes, [int64]$KeepFreeBytes = 0) {
    $room = Get-RoomDrive $Drive
    $problem = Get-OfflineShrinkProblem $room $WantedBytes $KeepFreeBytes
    if ($problem) { throw $problem }
    $c = Get-Partition -DriveLetter $room.TrimEnd(':')
    $new = Get-ShrinkTarget $c $WantedBytes
    $steps = @(
        "Puts hop's shrink tool on the EFI partition. It's Fedora Linux's signed startup files and **ntfsresize**, which GParted uses, and nothing else."
        ('Restarts into it. It shrinks drive {0} from {1:N0} GB to {2:N0} GB from outside Windows, where every file can move. That can take from a few minutes to half an hour. Don''t turn off the PC.' -f $room, ($c.Size / 1GB), ($new / 1GB))
        "Restarts into Windows, which checks drive $room as it starts. hop opens again with the space set aside for Linux."
    )
    $notes = @(
        'Save your work and back up anything important first. Losing power while a drive shrinks can damage it.'
        'If anything looks wrong before it starts, it changes nothing and goes back to Windows.'
    )
    if (Test-SecureBoot) { $notes += 'It starts with Secure Boot on.' }
    [pscustomobject]@{ Steps = $steps; Notes = $notes; Restart = $true }
}
