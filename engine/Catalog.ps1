# --- Catalog ------------------------------------------------------------
# Strategy 'prepared': hop creates the boot + root partitions, for
#   installers whose easy mode can't use free space (elementary, Pop!_OS).
# Strategy 'freespace': hop leaves unallocated space and the
#   installer's "alongside Windows" option uses it (Ubuntu, Mint).

function New-Entry([string]$Id, [string]$Name, [string]$Note, [string]$Source, [string]$Color, [string]$Logo, [hashtable]$More) {
    $entry = [ordered]@{
        Id = $Id; Name = $Name; Version = $null; Note = $Note; Source = $Source; Color = $Color; Logo = $Logo
        Strategy = 'freespace'; SecureBootOff = $false; Kind = $null; Base = $null; Prefix = $null; Edition = $null
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
# SecureBootOff: its kernel isn't signed, as in Pop!_OS 24.04's ISO, so it can't start with Secure Boot on.
# Kubuntu is missing on purpose: its ISO has a file over 4 GB, which FAT32 cannot hold.
function Get-Catalog {
    @(
        New-Entry 'elementary' 'elementary OS' 'Mac-like' 'elementary.io' '#3689E6' 'elementary' @{
            Kind = 'elementary'; Strategy = 'prepared'; Mode = 'Custom Install (Advanced)' }
        New-UbuntuFlavor 'ubuntu' 'Ubuntu' 'Most popular' '#E95420'
        New-MintEdition 'cinnamon' 'Linux Mint' 'Windows-like'
        New-Entry 'pop' 'Pop!_OS' 'Gaming' 'pop-os.org' '#48B9C7' 'pop' @{
            Kind = 'pop'; Version = '24.04'; Strategy = 'prepared'; Mode = 'Custom (Advanced)'; SecureBootOff = $true }
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
