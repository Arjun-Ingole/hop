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
