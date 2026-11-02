# The engine's own code, run with pwsh on Linux for tools/vm/omarchy/omarchyvm.py, so the test disk gets what hop gives a PC.
#   prepare.ps1 sizes <ISO folder>                      what goes on HOPLIVE, and both partitions' sizes, as JSON
#   prepare.ps1 boot <HOPINSTALL folder> <EFI folder>   Update-BootConfig, as Install-Linux and Register-Installer run it, then Copy-EspLoader into EFI/hop
#   prepare.ps1 boot <HOPINSTALL folder> <EFI folder> -FullDisk   the same, for replacing Windows
# Read-Iso and Copy-Installer need Windows, so the sizes use the same helpers they do, on a folder.
param([string]$Action, [string]$Path, [string]$Esp, [switch]$FullDisk)
$ErrorActionPreference = 'Stop'

$engine = Join-Path $PSScriptRoot '../../../engine'
$Sync = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Version = 'vm' })
foreach ($name in 'Common', 'Catalog', 'Iso', 'Boot') { . (Join-Path $engine "$name.ps1") }
$distro = Get-Distro 'omarchy' ''

switch ($Action) {
    'sizes' {
        $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('/')
        # Windows sees no links in an ISO, so neither does this.
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Where-Object { -not $_.LinkType })
        $live = @(); $rest = @()
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($root.Length).TrimStart('/') -replace '/', '\'
            if (Test-LiveFile $distro $relative) { $live += $file } else { $rest += $file }
        }
        $bytes = [int64]($rest | Measure-Object -Property Length -Sum).Sum
        $liveBytes = [int64]($live | Measure-Object -Property Length -Sum).Sum
        $untried = $distro.UntriedFile -and (Test-Path -LiteralPath (Join-Path $root ($distro.UntriedFile -replace '\\', '/')))
        [ordered]@{
            InstallerGB = Get-InstallerGB $bytes
            LiveGB      = Get-LiveGB $liveBytes
            Bytes       = $bytes
            LiveBytes   = $liveBytes
            LiveFiles   = @($live | ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('/') })
            TooBig      = @($rest | Where-Object Length -ge 4GB | ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('/') })
            Untried     = [bool]$untried
            BootKnown   = Test-BootConfigKnown $distro $root
            FullDiskUntried = [bool]($distro.FullDisk.UntriedFile -and (Test-Path -LiteralPath (Join-Path $root ($distro.FullDisk.UntriedFile -replace '\\', '/'))))
        } | ConvertTo-Json -Depth 3
    }
    'boot' {
        Update-BootConfig $distro $Path -FullDisk:$FullDisk
        if ($FullDisk -and -not (Test-FullDiskConfig $distro $Path)) { throw 'The menu does not ask for the copy to memory.' }
        # Register-Installer runs it again, without -FullDisk.
        Update-BootConfig $distro $Path
        Copy-EspLoader $distro (Join-Path $Path 'EFI/BOOT') (Join-Path $Esp 'EFI/hop')
        $Sync.Log | ForEach-Object { Write-Host $_ }
    }
    default { throw "Unknown action '$Action'." }
}
