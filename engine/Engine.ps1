<#
    hop engine. Loaded into an in-process PowerShell runspace by hop.exe,
    which passes $Sync (a synchronized hashtable) for progress: Status, Percent,
    Stage and Log.

    How it works (what a USB installer does, but on the internal disk):
      1. Download the official ISO and check its checksum.
      2. Shrink C: and make room for Linux plus a small FAT32 "HOPINSTALL" partition.
      3. Copy the ISO's files onto HOPINSTALL.
      4. Add a UEFI boot entry for HOPINSTALL and boot it once on the next restart.
    The Linux installer then runs from HOPINSTALL and installs into the room made.

    Only Ubuntu-style ("casper") live ISOs work, and no file in the ISO may be
    4 GB or larger (FAT32 limit). Both are checked before the disk is touched.
#>

$ErrorActionPreference = 'Stop'

# This app used to be called LinuxHop. What those builds left on a PC is still
# recognised, so it can be used or undone; only the new names are ever written.
$StateDir = Join-Path $env:ProgramData 'hop'
$StatePath = Join-Path $StateDir 'state.json'
$LegacyStatePath = Join-Path $env:ProgramData 'LinuxHop\state.json'
$InstallerLabel = 'HOPINSTALL'
$InstallerLabels = @($InstallerLabel, 'LINUXHOP')
$BootLabel = 'LINUXBOOT'
$RootLabel = 'LINUXROOT'
$EspFolder = 'EFI\hop'   # on Windows' EFI partition
$EspFolders = @($EspFolder, 'EFI\linuxhop')
$EntryMarker = '(hop)'
$EntryMarkers = @($EntryMarker, '(LinuxHop)')
$EntryPattern = '\((hop|LinuxHop)\)'
$WindowsReserve = 8GB    # free space Windows keeps on top of what it already uses
$MinLinuxGB = 25

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Progress reporting -------------------------------------------------
# Stages match the checklist in the app: 0 check PC, 1 download, 2 check
# download, 3 make room, 4 copy installer, 5 startup menu.

function Write-Log([string]$Message) {
    [void]$Sync.Log.Add(('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message))
}

function Set-Status([string]$Message, [int]$Percent = -1) {
    $Sync.Status = $Message
    $Sync.Percent = $Percent
    Write-Log $Message
}

function Set-Stage([int]$Stage) {
    $Sync.Stage = $Stage
    $Sync.Percent = -1
    $Sync.Bytes = 0
    $Sync.TotalBytes = 0
}

function Set-ByteProgress([int64]$Done, [int64]$Total) {
    $Sync.Bytes = $Done
    $Sync.TotalBytes = $Total
    $Sync.Percent = if ($Total -gt 0) { [int][math]::Min([double]100, 100.0 * $Done / $Total) } else { -1 }
}

# --- Catalog ------------------------------------------------------------
# Strategy 'prepared': hop creates the boot + root partitions, for
#   installers whose easy mode can't use free space (elementary, Pop!_OS).
# Strategy 'freespace': hop leaves unallocated space and the
#   installer's "alongside Windows" option uses it (Ubuntu, Mint).

function New-Entry([string]$Id, [string]$Name, [string]$Note, [string]$Source, [string]$Color, [string]$Logo, [hashtable]$More) {
    $entry = [ordered]@{
        Id = $Id; Name = $Name; Version = $null; Note = $Note; Source = $Source; Color = $Color; Logo = $Logo
        Strategy = 'freespace'; Kind = $null; Base = $null; Prefix = $null; Edition = $null
        Mode = $null; Alongside = $null; Manual = $null; ManualExtra = $null
    }
    foreach ($key in $More.Keys) { $entry[$key] = $More[$key] }
    [pscustomobject]$entry
}

# Official Ubuntu flavours of 26.04 LTS, all published with SHA256SUMS on ubuntu.com.
function New-UbuntuFlavor([string]$Id, [string]$Name, [string]$Note, [string]$Color, [hashtable]$More = @{}) {
    $base = if ($Id -eq 'ubuntu') { 'https://releases.ubuntu.com/26.04/' } else { "https://cdimage.ubuntu.com/$Id/releases/26.04/release/" }
    $settings = @{ Kind = 'ubuntu'; Version = '26.04 LTS'; Base = $base; Prefix = $Id; Alongside = "Install $Name alongside Windows"; Manual = 'Manual installation' }
    foreach ($key in $More.Keys) { $settings[$key] = $More[$key] }
    New-Entry $Id $Name $Note ([uri]$base).Host $Color $Id $settings
}

function New-MintEdition([string]$Edition, [string]$Name, [string]$Note) {
    New-Entry "mint-$Edition" $Name $Note 'the Linux Mint mirror at kernel.org' '#69B53F' 'mint' @{
        Kind = 'mint'; Edition = $Edition; Alongside = 'Install Linux Mint alongside Windows Boot Manager'; Manual = 'Something else' }
}

# Color is the project's brand color, used for its part of the drive in the app.
# Logo names an embedded image (assets/logos/<Logo>.png).
# Kubuntu is missing on purpose: its ISO has a file over 4 GB, which FAT32 cannot hold.
function Get-Catalog {
    @(
        New-Entry 'elementary' 'elementary OS' 'Mac-like' 'elementary.io' '#3689E6' 'elementary' @{
            Kind = 'elementary'; Strategy = 'prepared'; Mode = 'Custom Install (Advanced)' }
        New-UbuntuFlavor 'ubuntu' 'Ubuntu' 'Most popular' '#E95420'
        New-MintEdition 'cinnamon' 'Linux Mint' 'Windows-like'
        New-Entry 'pop' 'Pop!_OS' 'Gaming' 'pop-os.org' '#48B9C7' 'pop' @{
            Kind = 'pop'; Version = '24.04'; Strategy = 'prepared'; Mode = 'Custom (Advanced)' }
        New-UbuntuFlavor 'ubuntu-budgie' 'Ubuntu Budgie' 'Dock at the bottom' '#404552'
        New-UbuntuFlavor 'xubuntu' 'Xubuntu' 'Lightweight' '#0044AA'
        New-UbuntuFlavor 'lubuntu' 'Lubuntu' 'Lightest' '#0068C8' @{
            Alongside = $null; Manual = 'Manual partitioning'
            ManualExtra = 'Also click the existing **EFI System Partition**, choose Edit, set the mount point to **/boot/efi** and keep it unformatted.' }
        New-UbuntuFlavor 'ubuntucinnamon' 'Ubuntu Cinnamon' 'Windows-like layout' '#DD682A'
        New-UbuntuFlavor 'ubuntu-unity' 'Ubuntu Unity' 'Classic Ubuntu' '#5A06C3'
        New-MintEdition 'xfce' 'Linux Mint Xfce' 'Lighter Mint'
        New-MintEdition 'mate' 'Linux Mint MATE' 'Traditional'
        New-UbuntuFlavor 'edubuntu' 'Edubuntu' 'For students' '#A30B00'
        New-UbuntuFlavor 'ubuntustudio' 'Ubuntu Studio' 'For creators' '#009BF9'
    )
}

function Get-Distro([string]$Id, [string]$IsoPath) {
    if ($Id -eq 'custom') {
        return New-Entry 'custom' ([IO.Path]::GetFileNameWithoutExtension($IsoPath)) '' '' '#1D1D1F' '' @{
            Alongside = 'Install ... alongside Windows'; Manual = 'Manual installation' }
    }
    Get-Catalog | Where-Object Id -eq $Id
}

# --- Official download sources -----------------------------------------

function Get-WebText([string]$Url) {
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    $content
}

function ConvertTo-Version([string]$Text) {
    if ($Text -notmatch '\.') { $Text += '.0' }
    [version]$Text
}

function New-Download([string]$Url, [string]$Sha256, [int64]$Size) {
    [pscustomobject]@{ Url = $Url; Sha256 = $Sha256; Size = $Size; FileName = ([uri]$Url).Segments[-1] }
}

function Resolve-Download($Distro) {
    switch ($Distro.Kind) {
        'ubuntu' {
            # SHA256SUMS lists every point release; take the newest desktop ISO.
            $sums = Get-WebText ($Distro.Base + 'SHA256SUMS')
            $pattern = '(?m)^([0-9a-f]{64}) \*?(' + [regex]::Escape($Distro.Prefix) + '-([\d.]+)-desktop-amd64\.iso)\s*$'
            $best = $null
            foreach ($m in [regex]::Matches($sums, $pattern)) {
                $v = ConvertTo-Version $m.Groups[3].Value
                if (-not $best -or $v -gt $best.Version) { $best = @{ Version = $v; Sha = $m.Groups[1].Value; File = $m.Groups[2].Value } }
            }
            if (-not $best) { throw "Could not find the $($Distro.Name) ISO on $($Distro.Source)." }
            return New-Download ($Distro.Base + $best.File) $best.Sha 0
        }
        'mint' {
            $base = 'https://mirrors.edge.kernel.org/linuxmint/stable/'
            $versions = [regex]::Matches((Get-WebText $base), 'href="(\d+(?:\.\d+)?)/"') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object { ConvertTo-Version $_ } -Descending
            foreach ($v in $versions) {
                try { $sums = Get-WebText "$base$v/sha256sum.txt" } catch { continue }
                $m = [regex]::Match($sums, "(?m)^([0-9a-f]{64}) \*?(linuxmint-[\d.]+-$($Distro.Edition)-64bit\.iso)")
                if ($m.Success) { return New-Download "$base$v/$($m.Groups[2].Value)" $m.Groups[1].Value 0 }
            }
            throw 'Could not find the Linux Mint ISO on the mirror.'
        }
        'pop' {
            $build = Invoke-RestMethod -Uri 'https://api.pop-os.org/builds/24.04/generic' -UseBasicParsing -TimeoutSec 60
            return New-Download $build.url $build.sha_sum ([int64]$build.size)
        }
        'elementary' {
            # The link carries an expiring token, so read it from the site each time.
            # elementary does not publish a checksum; the download is HTTPS from their server.
            $m = [regex]::Match((Get-WebText 'https://elementary.io/'), 'https://dl\.elementaryos\.org/[^"''\s<>]+-amd64[^"''\s<>]*\.iso')
            if (-not $m.Success) { throw 'Could not find the download link on elementary.io.' }
            return New-Download $m.Value $null 0
        }
    }
    throw "Unknown system '$($Distro.Id)'."
}

# --- Download ------------------------------------------------------------

function Test-Sha256([string]$Path, [string]$Expected) {
    Set-Stage 2
    Set-Status 'Checking the download is genuine (takes a minute)...'
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected.ToUpperInvariant()
}

function Invoke-Download($Download, [string]$Path) {
    Set-Stage 1
    $part = "$Path.part"
    $total = $Download.Size
    if (-not $total) {
        try {
            $head = Invoke-WebRequest -Uri $Download.Url -Method Head -UseBasicParsing -TimeoutSec 60
            $total = [int64]($head.Headers['Content-Length'] | Select-Object -First 1)
        } catch { $total = 0 }
    }
    if ($total -and (Test-Path -LiteralPath $part) -and (Get-Item -LiteralPath $part).Length -ge $total) {
        Write-Log 'Download already complete.'
    } else {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (-not (Test-Path $curl)) {
            Set-Status "Downloading $($Download.FileName)..."
            Start-BitsTransfer -Source $Download.Url -Destination $part
        } else {
            # -C - resumes a half-finished download if Install is clicked again.
            $curlArgs = @('-L', '--fail', '--silent', '--show-error', '--retry', '5', '--retry-delay', '5',
                '-C', '-', '-o', "`"$part`"", "`"$($Download.Url)`"")
            $proc = Start-Process -FilePath $curl -ArgumentList $curlArgs -PassThru -WindowStyle Hidden
            $null = $proc.Handle   # keeps ExitCode readable after the process exits
            $Sync.ChildPid = $proc.Id   # lets the app stop the download if it is closed
            Set-Status "Downloading $($Download.FileName)..."
            while (-not $proc.HasExited) {
                if ($total -and (Test-Path -LiteralPath $part)) {
                    $done = (Get-Item -LiteralPath $part).Length
                    $Sync.Status = 'Downloading {0}... {1:N1} of {2:N1} GB' -f $Download.FileName, ($done / 1GB), ($total / 1GB)
                    Set-ByteProgress $done $total
                }
                Start-Sleep -Milliseconds 700
            }
            if ($proc.ExitCode -ne 0) {
                throw "The download stopped (curl error $($proc.ExitCode)). Check the internet connection and click Install again; it will pick up where it left off."
            }
        }
    }
    Move-Item -LiteralPath $part -Destination $Path -Force
}

function Get-Iso($Download, [string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (-not $Download.Sha256 -or (Test-Sha256 $Path $Download.Sha256)) {
            Write-Log "Using the copy already in $Path"
            return
        }
        Write-Log 'The file already downloaded is damaged; downloading it again.'
        Remove-Item -LiteralPath $Path -Force
    }
    Invoke-Download $Download $Path
    if ($Download.Sha256) {
        if (-not (Test-Sha256 $Path $Download.Sha256)) {
            Remove-Item -LiteralPath $Path -Force
            throw 'The downloaded file is damaged (checksum does not match). Click Install to download it again.'
        }
        Write-Log 'Checksum matches the official one.'
    } else {
        Write-Log 'This project does not publish a checksum. The file came over a secure HTTPS connection from its official server.'
    }
}

# --- ISO -----------------------------------------------------------------

function Mount-Iso([string]$Path) {
    $image = Get-DiskImage -ImagePath $Path
    if (-not $image.Attached) { $image = Mount-DiskImage -ImagePath $Path -PassThru }
    for ($i = 0; $i -lt 20; $i++) {
        $letter = ($image | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
        if ($letter) { return [string]$letter }
        Start-Sleep -Milliseconds 500
    }
    throw 'Windows could not open the ISO file.'
}

function Read-Iso([string]$Path) {
    Set-Status 'Checking the ISO file...'
    $letter = Mount-Iso $Path
    $root = "$letter`:\"
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)

    if (-not (Test-Path -LiteralPath (Join-Path $root 'EFI\BOOT\BOOTX64.EFI'))) {
        throw 'This ISO cannot start on a modern (UEFI) PC.'
    }
    $live = Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object {
        $_.Name -like 'casper*' -and (Get-ChildItem -LiteralPath $_.FullName -Filter '*.squashfs' -Force)
    }
    if (-not $live) {
        throw 'This ISO is not an Ubuntu-style live system. hop only supports Ubuntu-based systems (Ubuntu, Mint, elementary, Pop!_OS, Zorin...).'
    }
    $big = $files | Where-Object Length -ge 4GB | Select-Object -First 1
    if ($big) {
        throw "This ISO contains a file larger than 4 GB ($($big.Name)), which cannot be copied to the installer partition. Try a different system."
    }

    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    [pscustomobject]@{
        Letter      = $letter
        Bytes       = [int64]$bytes
        InstallerGB = [int][math]::Max([double]4, [math]::Ceiling(($bytes + 512MB) / 1GB))
    }
}

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

function Test-System {
    if ($env:firmware_type -ne 'UEFI') {
        throw 'This PC starts in the old "Legacy BIOS" mode. hop only works on UEFI PCs.'
    }
    $c = Get-WindowsPartition
    if ((Get-Disk -Number $c.DiskNumber).PartitionStyle -ne 'GPT') {
        throw 'The Windows disk uses the old MBR layout. hop only works on GPT disks.'
    }
}

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
$EspType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$BasicDataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

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

function Suspend-BitLockerForSetup {
    $volume = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
        -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction SilentlyContinue
    if ($volume -and $volume.ProtectionStatus -eq 1) {
        # Changing boot entries can make BitLocker ask for the recovery key; pause it for a few restarts.
        Write-Log 'BitLocker is on; pausing it for the next 3 restarts.'
        & manage-bde.exe -protectors -disable $env:SystemDrive -RebootCount 3 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not pause BitLocker. Turn off "Device encryption" in Settings and try again.' }
    }
}

function Disable-FastStartup {
    # Fast Startup leaves Windows half-asleep, which confuses Linux installers.
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
    Write-Log 'Turned off Windows Fast Startup.'
}

function Save-State($State) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Read-State {
    $path = @($StatePath, $LegacyStatePath) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}

function Get-Plan([int]$LinuxGB, [int]$InstallerGB) {
    $space = Get-SpaceInfo
    $maxLinux = $space.UsableGB - $InstallerGB
    if ($LinuxGB -gt $maxLinux) {
        if ($maxLinux -lt $MinLinuxGB) { throw "Not enough free space on C:. Free up at least $($MinLinuxGB - $maxLinux) GB and try again." }
        throw "Not enough free space for $LinuxGB GB. Lower the Linux size to $maxLinux GB or less and click Install again."
    }
    # Linux and the installer go at the end of C: and the free space after it, so any
    # space left over stays next to C:. C: only shrinks when the free space isn't enough.
    $c = $space.Partition
    $windowsEnd = [int64]($c.Offset + $c.Size)
    $regionEnd = [int64]([math]::Floor(($windowsEnd + $space.TailFree) / 1MB) * 1MB)
    $installerOffset = [int64]($regionEnd - [int64]$InstallerGB * 1GB)
    $linuxStart = [int64]($installerOffset - [int64]$LinuxGB * 1GB)
    $shrink = $linuxStart -lt $windowsEnd
    [pscustomobject]@{
        DiskNumber      = $c.DiskNumber
        PartitionNumber = $c.PartitionNumber
        Shrink          = $shrink
        NewWindowsSize  = if ($shrink) { [int64]($linuxStart - $c.Offset) } else { [int64]$c.Size }
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
        Start-Sleep -Milliseconds 500
    }
    throw 'Windows did not give the new partition a drive letter.'
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
            throw "Windows could not shrink C: that far ($($_.Exception.Message)). Try a smaller Linux size."
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
    # Windows sometimes assigns a letter by itself; asking again then fails harmlessly.
    try { Add-PartitionAccessPath -DiskNumber $installer.DiskNumber -PartitionNumber $installer.PartitionNumber -AssignDriveLetter } catch { }
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
}

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
    & mountvol.exe "$($letter):" /s | Out-Null
    if (-not (Test-Path "$($letter):\EFI")) { throw 'Could not open the EFI system partition.' }
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
    if (-not $installer -or -not $installer.Letter -or -not (Test-Path -LiteralPath "$($installer.Letter):\EFI\BOOT\BOOTX64.EFI")) {
        throw 'The installer partition is missing or incomplete. Undo the changes and install again.'
    }
    $source = "$($installer.Letter):\EFI\BOOT"
    Use-Esp {
        param($root)
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

# What to click in the Linux installer. The app shows Steps as a numbered list
# and Notes underneath; text between ** is shown in a heavier weight.
function Get-Steps($Distro, [int]$LinuxGB) {
    if ($Distro.Strategy -eq 'prepared') {
        $steps = @(
            "Pick your language and keyboard, then choose **$($Distro.Mode)**."
            "Click the $($LinuxGB - 1) GB partition named **$RootLabel**. Use it as Root (/) and format it as ext4."
            "Click the 1 GB partition named **$BootLabel**. Use it as Boot (/boot/efi) and format it as FAT32."
            'Leave everything else alone and click **Install**.'
        )
    } else {
        $manual = "choose **$($Distro.Manual)**, select the $LinuxGB GB of free space, click **+** and create an ext4 partition mounted at **/**."
        $steps = @('Pick your language and keyboard, then start the installer.')
        if ($Distro.Alongside) {
            $steps += "Choose **$($Distro.Alongside)**. It uses the $LinuxGB GB hop set aside."
            $steps += "If that option is missing, $manual"
        } else {
            $steps += "When asked how to install, $manual"
        }
        if ($Distro.ManualExtra) { $steps += $Distro.ManualExtra }
        $steps += "Don't choose **Erase disk**. The installer is running from this drive."
    }
    [pscustomobject]@{
        Steps = $steps
        Notes = @('If the PC starts Windows again or shows a security error, turn off Secure Boot in the BIOS, then open hop and restart again.')
    }
}
