# --- ISO -----------------------------------------------------------------

function Mount-Iso([string]$Path) {
    # Windows refuses to mount sparse files, which some download tools create.
    if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::SparseFile) {
        & fsutil.exe sparse setflag $Path 0 | Out-Null
        Write-Log 'Cleared the sparse flag on the ISO.'
    }
    try {
        $image = Get-DiskImage -ImagePath $Path
        if (-not $image.Attached) { $image = Mount-DiskImage -ImagePath $Path -PassThru }
    } catch {
        throw "Windows could not open the ISO file ($($_.Exception.Message)). It may be damaged, or stored on a network or cloud folder. Copy it to a folder on this PC and try again."
    }
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
    # The boot loader finds the installer partition by this file.
    if (-not (Test-Path -LiteralPath (Join-Path $root '.disk\info'))) {
        throw 'This ISO is not an Ubuntu-style live system. hop only supports Ubuntu-based systems (Ubuntu, Mint, elementary, Pop!_OS, Zorin...).'
    }
    $live = Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object {
        $_.Name -like 'casper*' -and (Get-ChildItem -LiteralPath $_.FullName -Filter '*.squashfs' -Force)
    }
    if (-not $live) {
        throw 'This ISO is not an Ubuntu-style live system. hop only supports Ubuntu-based systems (Ubuntu, Mint, elementary, Pop!_OS, Zorin...).'
    }
    # FAT32 can't hold links, and Windows can't see them in an ISO, so a kernel reached
    # through one wouldn't be there at startup. Checked on the catalog's ISOs: none do this.
    $kernel = Get-IsoKernelPath $root
    if ($kernel -and -not (Test-Path -LiteralPath $kernel)) {
        throw "This ISO's boot menu needs $($kernel.Substring($root.Length)), which Windows can't see in it. It probably relies on a link, which the installer partition can't hold. Try a different system."
    }
    $big = $files | Where-Object Length -ge 4GB | Select-Object -First 1
    if ($big) {
        throw "This ISO contains a file larger than 4 GB ($($big.Name)), which cannot be copied to the installer partition. Try a different system."
    }

    $stopped = Get-SecureBootProblem $root
    if ($stopped) { throw $stopped }

    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    $installerGB = [int][math]::Max([double]4, [math]::Ceiling(($bytes + 512MB) / 1GB))
    # Windows can't format a FAT32 partition larger than 32 GB.
    if ($installerGB -gt 32) { throw "This ISO is too big: its $installerGB GB won't fit on a FAT32 installer partition." }
    [pscustomobject]@{
        Letter      = $letter
        Bytes       = [int64]$bytes
        InstallerGB = $installerGB
    }
}
