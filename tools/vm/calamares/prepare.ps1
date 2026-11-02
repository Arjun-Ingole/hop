# The engine's own code, run with pwsh on Linux for tools/vm/calamares/calamaresvm.py, so the test disk gets what hop gives a PC.
#   prepare.ps1 resolve <id>                                the ISO and its checksum, as Resolve-Download finds them, as JSON
#   prepare.ps1 sizes <id> <ISO folder>                     the installer partition's size, and Read-Iso's checks that work here, as JSON
#   prepare.ps1 boot <id> <HOPINSTALL folder> <EFI folder>  Update-BootConfig, as Install-Linux and Register-Installer run it, then Copy-EspLoader into EFI/hop
#   prepare.ps1 steps <id> <Linux GB> <installer GB> <EFI MB>   Get-Steps, as hop shows them next to Windows, as JSON
# Read-Iso and Copy-Installer need Windows, so the sizes use the same helpers they do, on a folder.
param([string]$Action, [string]$Id, [string]$Path, [string]$Esp, [string]$More)
$ErrorActionPreference = 'Stop'

$engine = Join-Path $PSScriptRoot '../../../engine'
$Sync = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Version = 'vm' })
foreach ($name in 'Common', 'Catalog', 'Iso', 'Boot', 'SecureBoot', 'Download', 'Steps') { . (Join-Path $engine "$name.ps1") }
$distro = Get-Distro $Id ''

switch ($Action) {
    'resolve' {
        $download = Resolve-Download $distro
        [ordered]@{ Url = $download.Url; Sha256 = $download.Sha256; FileName = $download.FileName } | ConvertTo-Json
    }
    'sizes' {
        $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('/')
        # Windows sees no links in an ISO, so neither does this.
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Where-Object { -not $_.LinkType })
        $bytes = [int64]($files | Measure-Object -Property Length -Sum).Sum
        $kernel = Get-IsoKernelPath $root
        [ordered]@{
            InstallerGB = Get-InstallerGB $bytes
            Bytes       = $bytes
            TooBig      = @($files | Where-Object Length -ge 4GB | ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('/') })
            LiveFound   = [bool](-not $distro.Live -or (Test-Path -LiteralPath (Join-Path $root $distro.Live)))
            BootKnown   = Test-BootConfigKnown $distro $root
            Kernel      = $kernel
            KernelFound = [bool]($kernel -and (Test-Path -LiteralPath ($kernel -replace '\\', '/')))
            Refused     = $distro.Refused
        } | ConvertTo-Json -Depth 3
    }
    'boot' {
        Update-BootConfig $distro $Path
        # Register-Installer runs it again.
        Update-BootConfig $distro $Path
        Copy-EspLoader $distro (Join-Path $Path 'EFI/BOOT') (Join-Path $Esp 'EFI/hop')
        $Sync.Log | ForEach-Object { Write-Host $_ }
    }
    'steps' {
        $linuxGB, $installerGB, $espMB = $More -split ',' | ForEach-Object { [int]$_ }
        # What Windows would say about its EFI partition, and the plan hop saves.
        $script:espSize = [int64]$espMB * 1MB
        function Get-WindowsEsp { [pscustomobject]@{ Size = $script:espSize } }
        $place = [pscustomobject]@{ OnWindowsDisk = $true; Partitions = @([pscustomobject]@{ Role = 'installer'; Size = [int64]$installerGB * 1GB }) }
        $result = Get-Steps $distro $linuxGB $place
        [ordered]@{ Steps = @($result.Steps); Notes = @($result.Notes) } | ConvertTo-Json -Depth 3
    }
    default { throw "Unknown action '$Action'." }
}
