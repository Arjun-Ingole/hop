BeforeAll {
    . (Join-Path $PSScriptRoot 'Load-Engine.ps1') -WithHop
    Mock Write-Log { }
    Mock Set-Status { }
}

Describe 'Partition ownership across disks' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-HopDisks { [pscustomobject]@{ Number = 0 }; [pscustomobject]@{ Number = 1 } }
        Mock Get-StateDisk { 1 }
        Mock Read-State { [pscustomobject]@{ DiskGuid = '{disk-1}'; Partitions = @([pscustomobject]@{ Offset = 1GB; Size = 8GB; Guid = '{owned}' }) } }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = [int]@($DiskNumber)[0]; Offset = 1GB; Size = 8GB; Guid = '{owned}'; DriveLetter = 'H' } }
        Mock Get-Volume { [pscustomobject]@{ FileSystemLabel = 'HOPINSTALL'; FileSystemType = 'FAT32' } }
        Mock Get-VolumeEntries { 'personal-files' }
    }
    It 'uses a creation record only on the recorded disk' {
        $found = @(Get-HopPartitions)
        $found.Count | Should -Be 1
        $found[0].Partition.DiskNumber | Should -Be 1
        $found[0].Recorded | Should -BeTrue
    }
    It 'rejects a replacement partition with identical geometry' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = [int]@($DiskNumber)[0]; Offset = 1GB; Size = 8GB; Guid = '{replacement}'; DriveLetter = 'H' } }
        @(Get-HopPartitions).Count | Should -Be 0
    }
    It 'does not trust records from a disconnected disk' {
        Mock Get-StateDisk { $null }
        @(Get-HopPartitions).Count | Should -Be 0
    }
    It 'discovers an ISO-looking volume without authorizing its deletion' {
        Mock Read-State { }
        Mock Get-VolumeEntries { 'EFI', 'Photos' }
        $found = @(Get-HopPartitions)
        $found.Count | Should -Be 2
        @($found | Where-Object Recorded).Count | Should -Be 0
    }
    It 'refuses unrecorded cleanup before changing boot entries or partitions' {
        Mock Get-HopPartitions { [pscustomobject]@{ Recorded = $false } }
        Mock Get-BcdEntries { throw 'must not run' }
        Mock Remove-PartitionAt { throw 'must not run' }
        { Invoke-Cleanup } | Should -Throw '*no matching creation record*Nothing has been removed*'
        Should -Invoke Get-BcdEntries -Times 0 -Exactly
        Should -Invoke Remove-PartitionAt -Times 0 -Exactly
    }
}

Describe 'Confirmation of all Linux partitions' {
    BeforeEach {
        Mock Get-OtherSystem { [pscustomobject]@{ Selection = 'current'; Name = 'all Linux partitions on this disk'; Entries = @(); Kept = @(); Partitions = @() } }
        Mock Remove-PartitionByGuid { }
    }
    It 'requires the selection shown in the confirmation' {
        { Remove-OtherSystem } | Should -Throw '*review the partition list*'
        { Remove-OtherSystem 'stale' } | Should -Throw '*Nothing has been removed*'
        Should -Invoke Remove-PartitionByGuid -Times 0 -Exactly
    }
    It 'changes the confirmation when another data partition appears' {
        $one = [pscustomobject]@{ Guid = '{a}'; Offset = 1GB; Size = 25GB; GptType = 'Linux' }
        $two = [pscustomobject]@{ Guid = '{b}'; Offset = 26GB; Size = 40GB; GptType = 'Linux' }
        (Get-OtherSelection '{disk}' @($one) @()) | Should -Not -Be (Get-OtherSelection '{disk}' @($one, $two) @())
        (Get-OtherSelection '{disk}' @($one) @()) | Should -Not -Be (Get-OtherSelection '{other-disk}' @($one) @())
    }
}

Describe 'Protected partition deletion' {
    It 'protects the Windows EFI partition before diskpart fallback' {
        Mock Get-Partition { [pscustomobject]@{ Guid = '{esp}'; DiskNumber = 0; PartitionNumber = 1 } }
        Mock Get-WindowsEsp { [pscustomobject]@{ Guid = '{esp}' } }
        Mock Remove-Partition { }
        Mock Invoke-Diskpart { }
        { Remove-PartitionByGuid '{esp}' 0 } | Should -Throw '*Windows needs to start*'
        Should -Invoke Remove-Partition -Times 0 -Exactly
        Should -Invoke Invoke-Diskpart -Times 0 -Exactly
    }
}

Describe 'Copy content verification' {
    AfterEach {
        Remove-PSDrive HOPSRC, HOPDST -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $source = Join-Path $TestDrive 'source'
        $destination = Join-Path $TestDrive 'destination'
        [IO.File]::WriteAllBytes($source, [byte[]](1, 2, 3, 4))
        [IO.File]::WriteAllBytes($destination, [byte[]](1, 2, 3, 4))
    }
    It 'accepts identical content' {
        { Assert-CopyMatches $source $destination } | Should -Not -Throw
    }
    It 'rejects corruption that preserves file length' {
        [IO.File]::WriteAllBytes($destination, [byte[]](1, 2, 9, 4))
        { Assert-CopyMatches $source $destination } | Should -Throw '*damaged*'
    }
    It 'checks both the installer and the second live partition' -ForEach @(@{ live = $false }, @{ live = $true }) {
        $isoRoot = Join-Path $TestDrive 'iso'
        $copyRoot = Join-Path $TestDrive 'copy'
        New-Item -ItemType Directory $isoRoot, $copyRoot -Force | Out-Null
        New-PSDrive -Name HOPSRC -PSProvider FileSystem -Root $isoRoot -Scope Global | Out-Null
        New-PSDrive -Name HOPDST -PSProvider FileSystem -Root $copyRoot -Scope Global | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $isoRoot 'image.sfs'), [byte[]](1, 2, 3, 4))
        [IO.File]::WriteAllBytes((Join-Path $copyRoot 'image.sfs'), [byte[]](1, 2, 9, 4))
        Mock Invoke-CopyWatched { }
        Mock Repair-ShortenedNames { }
        # Mounted ISOs have a drive-qualified FullName. Test PSDrives resolve FullName
        # to a filesystem path, so supply the same shape explicitly.
        $image = [pscustomobject]@{ FullName = 'HOPSRC:\image.sfs'; Name = 'image.sfs'; Length = 4 }
        $iso = [pscustomobject]@{ Letter = 'HOPSRC'; Bytes = 4; LiveBytes = 4; LiveFiles = @($image) }
        if ($live) {
            { Copy-LiveFiles $iso 'HOPDST' } | Should -Throw '*damaged*'
        } else {
            $iso.LiveFiles = @()
            # Supply mounted-drive paths to the installer enumeration too.
            Mock Get-InstallerFiles { $image }
            { Copy-Installer $iso 'HOPDST' } | Should -Throw '*damaged*'
        }
    }
}

Describe 'Cached ISO without an official checksum' {
    BeforeEach {
        $path = Join-Path $TestDrive 'cached.iso'
        Set-Content -LiteralPath $path 'old copy'
        Set-Content -LiteralPath "$path.part" 'old partial'
        $download = [pscustomobject]@{ Sha256 = $null }
        Mock Invoke-Download { }
    }
    It 'downloads fresh instead of trusting the filename or resuming an unknown partial' {
        Get-Iso $download $path
        Should -Invoke Invoke-Download -Times 1 -Exactly
        Test-Path -LiteralPath "$path.part" | Should -BeFalse
    }
    It 'keeps the existing file when the network fails' {
        Mock Invoke-Download { throw 'offline' }
        { Get-Iso $download $path } | Should -Throw 'offline'
        (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'old copy'
    }
    It 'still reuses a copy verified with an official checksum' {
        $download.Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Get-Iso $download $path
        Should -Invoke Invoke-Download -Times 0 -Exactly
    }
}

Describe 'UEFI entries above Boot00FF' {
    It 'reads the complete allocation range without accessing real firmware' {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class HopFirmwareFixture {
    public static byte[] Option;
    public static HashSet<string> Seen = new HashSet<string>();
    public static byte[] Read(string name) {
        Seen.Add(name);
        return name == "Boot0100" || name == "BootFFFF" ? Option : null;
    }
}
'@
        [HopFirmwareFixture]::Option = [Hop.Firmware]::LoadOption('Linux (hop)', 2, 2048, 4096, [guid]::NewGuid(), '\EFI\hop\BOOTX64.EFI')
        $reader = [Delegate]::CreateDelegate([Func[string, byte[]]], [HopFirmwareFixture].GetMethod('Read'))
        $method = [Hop.Firmware].GetMethod('ReadEntries', [Reflection.BindingFlags]'NonPublic,Static')
        $entries = $method.Invoke($null, @($reader))
        @($entries.Number) | Should -Be @(256, 65535)
        $entries[0].Path | Should -Be '\EFI\hop\BOOTX64.EFI'
        [HopFirmwareFixture]::Seen.Count | Should -Be 65536
    }
}
