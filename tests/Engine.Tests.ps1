# Unit tests for the engine, run by CI on Windows PowerShell 5.1 (Pester 5).
# Everything that touches the disk, the firmware or the network is mocked: these must be
# safe to run on any PC. Build first, because they load hop.exe for its C# types.
#
#   dotnet build -c Release
#   Invoke-Pester tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $Sync = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Version = 'test' })
    . (Join-Path $root 'engine\Common.ps1')
    foreach ($module in Get-ChildItem (Join-Path $root 'engine\*.ps1') | Where-Object Name -ne 'Common.ps1') { . $module.FullName }
    # Add-Type refuses .exe files.
    [void][Reflection.Assembly]::LoadFrom((Join-Path $root 'bin\Release\hop.exe'))
    Mock Write-Log { }
}

Describe 'Catalog' {
    BeforeAll { $catalog = @(Get-Catalog) }

    It 'has unique ids' {
        ($catalog.Id | Sort-Object -Unique).Count | Should -Be $catalog.Count
    }
    It 'gives every system what the app needs' {
        foreach ($distro in $catalog) {
            $distro.Name | Should -Not -BeNullOrEmpty
            $distro.Source | Should -Not -BeNullOrEmpty
            $distro.Note | Should -Not -BeNullOrEmpty
            $distro.Color | Should -Match '^#[0-9A-Fa-f]{6}$'
            $distro.Strategy | Should -BeIn @('freespace', 'prepared')
            $distro.Kind | Should -BeIn @('ubuntu', 'mint', 'pop', 'elementary')
        }
    }
    It 'has a logo file for every system' {
        foreach ($distro in $catalog) {
            Join-Path $root "assets\logos\$($distro.Logo).png" | Should -Exist
        }
    }
    It 'tells people what to click, whichever installer it is' {
        foreach ($distro in $catalog) {
            if ($distro.Strategy -eq 'prepared') { $distro.Mode | Should -Not -BeNullOrEmpty }
            else { $distro.Manual | Should -Not -BeNullOrEmpty }
        }
    }
    It 'makes an entry for a custom ISO from its file name' {
        (Get-Distro 'custom' 'C:\isos\zorin-17.iso').Name | Should -Be 'zorin-17'
    }
}

Describe 'Resolve-Download' {
    BeforeAll { $hash = 'a' * 64 }

    It 'picks the newest point release of an Ubuntu flavour' {
        Mock Get-WebText { "$hash *ubuntu-26.04-desktop-amd64.iso`n$hash *ubuntu-26.04.1-desktop-amd64.iso`n$hash *ubuntu-26.04-live-server-amd64.iso`n" }
        $distro = Get-Catalog | Where-Object Id -eq 'ubuntu'
        $download = Resolve-Download $distro
        $download.FileName | Should -Be 'ubuntu-26.04.1-desktop-amd64.iso'
        $download.Sha256 | Should -Be $hash
    }
    It 'fails clearly when the ISO is not listed' {
        Mock Get-WebText { "$hash *other.iso`n" }
        { Resolve-Download (Get-Catalog | Where-Object Id -eq 'ubuntu') } | Should -Throw '*Could not find*'
    }
    It 'skips a Mint version that has no ISO yet' {
        Mock Get-WebText { 'href="22.3/" href="23/"' } -ParameterFilter { $Url -like '*/stable/' }
        Mock Get-WebText { throw 'not there' } -ParameterFilter { $Url -like '*/23/*' }
        Mock Get-WebText { "$hash *linuxmint-22.3-cinnamon-64bit.iso`n" } -ParameterFilter { $Url -like '*/22.3/*' }
        (Resolve-Download (Get-Catalog | Where-Object Id -eq 'mint-cinnamon')).FileName | Should -Be 'linuxmint-22.3-cinnamon-64bit.iso'
    }
    It 'reads the elementary link from the site, with no checksum' {
        Mock Get-WebText { '<a href="https://dl.elementaryos.org/release/8.0/elementaryos-8.0-stable-amd64.20250101.iso?token=x">' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'elementary')
        $download.Url | Should -BeLike 'https://dl.elementaryos.org/*'
        $download.Sha256 | Should -BeNullOrEmpty
    }
}

Describe 'Download helpers' {
    It 'explains common curl failures' {
        Get-CurlMessage 6 | Should -BeLike '*internet*'
        Get-CurlMessage 60 | Should -BeLike '*date and time*'
        Get-CurlMessage 23 | Should -BeLike '*free space*'
        Get-CurlMessage 99 | Should -BeLike '*curl error 99*'
    }
    It 'compares versions numerically' {
        (ConvertTo-Version '26') | Should -BeLessThan (ConvertTo-Version '26.04')
        (ConvertTo-Version '9.1') | Should -BeLessThan (ConvertTo-Version '22')
    }
}

Describe 'Get-Plan' {
    BeforeAll {
        function New-Space([int64]$TailFree, [int]$UsableGB) {
            [pscustomobject]@{
                Partition = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = [int64]1GB; Size = [int64]200GB }
                TailFree = $TailFree; UsableGB = $UsableGB
            }
        }
    }
    It 'leaves C: alone when the free space after it is enough' {
        Mock Get-SpaceInfo { New-Space ([int64]100GB) 150 }
        $plan = Get-Plan 60 8
        $plan.Shrink | Should -BeFalse
        $plan.NewWindowsSize | Should -Be ([int64]200GB)
    }
    It 'shrinks C: by only what the free space cannot cover' {
        Mock Get-SpaceInfo { New-Space ([int64]10GB) 150 }
        $plan = Get-Plan 60 8
        $plan.Shrink | Should -BeTrue
        $plan.NewWindowsSize | Should -Be ([int64]142GB)
    }
    It 'puts the installer last and Linux straight before it, on megabyte boundaries' {
        Mock Get-SpaceInfo { New-Space ([int64]10GB + 123456) 150 }
        $plan = Get-Plan 60 8
        $plan.InstallerOffset % 1MB | Should -Be 0
        $plan.FreeStart % 1MB | Should -Be 0
        $plan.FreeStart + 60GB | Should -Be $plan.InstallerOffset
    }
    It 'refuses a size that does not fit, and says how much does' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 50 }
        { Get-Plan 60 8 } | Should -Throw '*42 GB or less*'
    }
    It 'refuses when too little is free for any Linux' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 20 }
        { Get-Plan 25 8 } | Should -Throw '*Free up at least*'
    }
}

Describe 'Get-InstallStatus' {
    BeforeAll {
        $installer = [pscustomobject]@{ Partition = $null; Label = 'HOPINSTALL'; Letter = 'H' }
    }
    BeforeEach {
        Mock Read-State { $null }
        Mock Get-HopPartitions { }
        Mock Get-FirmwareEntries { }
        Mock Get-BcdEntries { }
        Mock Test-LinuxInstalled { $false }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*BOOTX64.EFI' }
    }
    It 'is none on a clean PC' {
        Get-InstallStatus | Should -Be 'none'
    }
    It 'is ready once the copy has finished, even with no startup entry' {
        Mock Read-State { [pscustomobject]@{ Copied = $true; BootNumber = $null } }
        Mock Get-HopPartitions { $installer }
        Get-InstallStatus | Should -Be 'ready'
    }
    It 'keeps a setup made by an older build ready' {
        Mock Read-State { [pscustomobject]@{ BootNumber = 5 } }
        Mock Get-HopPartitions { [pscustomobject]@{ Partition = $null; Label = 'LINUXHOP'; Letter = 'H' } }
        Get-InstallStatus | Should -Be 'ready'
    }
    It 'gets the drive letter back instead of calling it a failed attempt' {
        Mock Read-State { [pscustomobject]@{ Copied = $true } }
        Mock Get-HopPartitions { [pscustomobject]@{ Partition = $null; Label = 'HOPINSTALL'; Letter = $null } }
        Mock Get-DriveLetter { 'H' }
        Get-InstallStatus | Should -Be 'ready'
    }
    It 'is installed when a new Linux boot loader appeared' {
        Mock Read-State { [pscustomobject]@{ Copied = $true } }
        Mock Get-HopPartitions { $installer }
        Mock Test-LinuxInstalled { $true }
        Get-InstallStatus | Should -Be 'installed'
    }
    It 'is leftover when the copy never finished' {
        Mock Read-State { [pscustomobject]@{ Copied = $false; BootNumber = $null } }
        Mock Get-HopPartitions { $installer }
        Get-InstallStatus | Should -Be 'leftover'
    }
    It 'is leftover when only a startup entry remains' {
        Mock Get-FirmwareEntries { 7 }
        Get-InstallStatus | Should -Be 'leftover'
    }
}

Describe 'Test-LinuxInstalled' {
    It 'does not guess for a setup made before this was recorded' {
        Mock Get-LinuxLoaders { [pscustomobject]@{ Path = '\EFI\ubuntu\shimx64.efi' } }
        Test-LinuxInstalled ([pscustomobject]@{ Copied = $true }) | Should -BeFalse
    }
    It 'ignores a boot loader that was already there' {
        Mock Get-LinuxLoaders { [pscustomobject]@{ Path = '\EFI\pond\shimx64.efi' } }
        Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @('\EFI\pond\shimx64.efi') }) | Should -BeFalse
    }
    It 'notices a new one' {
        Mock Get-LinuxLoaders { [pscustomobject]@{ Path = '\EFI\ubuntu\shimx64.efi' } }
        Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @() }) | Should -BeTrue
    }
    Context 'when the firmware has dropped the startup entry' {
        BeforeEach {
            Mock Get-LinuxLoaders { }
            Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
            Mock Get-Partition { }
            Mock Get-LinuxPartitions { [pscustomobject]@{ Guid = '{new}' } }
        }
        It 'notices a new Linux partition' {
            Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @(); LinuxBefore = @('{old}') }) | Should -BeTrue
        }
        It 'ignores a partition that was already there' {
            Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @(); LinuxBefore = @('{new}') }) | Should -BeFalse
        }
        It 'does not guess for a setup made before partitions were recorded' {
            Test-LinuxInstalled ([pscustomobject]@{ LoadersBefore = @() }) | Should -BeFalse
        }
    }
}

Describe 'Test-LinuxSignature' {
    It 'never picks a system or boot partition' {
        Test-LinuxSignature ([pscustomobject]@{ IsSystem = $true; IsBoot = $false; DiskNumber = 0; Offset = 0 }) | Should -BeFalse
        Test-LinuxSignature ([pscustomobject]@{ IsSystem = $false; IsBoot = $true; DiskNumber = 0; Offset = 0 }) | Should -BeFalse
    }
}

Describe 'Get-RecordedPartitions' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Partition {
            [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4; Offset = [int64]500GB; Size = [int64]8GB; IsSystem = $false; IsBoot = $false }
            [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 5; Offset = [int64]400GB; Size = [int64]60GB; IsSystem = $false; IsBoot = $false }
        }
        Mock Test-LinuxSignature { $false }
        Mock Get-Volume { $null }
    }
    It 'finds a recorded partition that was never formatted' {
        $state = [pscustomobject]@{ Partitions = @([pscustomobject]@{ Role = 'installer'; Offset = [int64]500GB; Size = [int64]8GB }) }
        @(Get-RecordedPartitions $state @('installer')).PartitionNumber | Should -Be 4
    }
    It 'only looks at the roles asked for' {
        $state = [pscustomobject]@{ Partitions = @([pscustomobject]@{ Role = 'root'; Offset = [int64]400GB; Size = [int64]60GB }) }
        @(Get-RecordedPartitions $state @('installer')).Count | Should -Be 0
    }
    It 'leaves it alone once Linux has been installed there' {
        Mock Test-LinuxSignature { $true }
        $state = [pscustomobject]@{ Partitions = @([pscustomobject]@{ Role = 'root'; Offset = [int64]400GB; Size = [int64]60GB }) }
        @(Get-RecordedPartitions $state @('root')).Count | Should -Be 0
    }
    It 'copes with no state' {
        @(Get-RecordedPartitions $null @('installer')).Count | Should -Be 0
    }
}

Describe 'Firmware' {
    It 'can tell how this PC started' {
        [Hop.Firmware]::IsUefi() | Should -BeOfType [bool]
    }
}

Describe 'Get-StartupInfo' {
    BeforeEach {
        Mock Test-System { throw 'blocked' }
        Mock Read-State { $null }
        Mock Test-CameBack { $false }
        Mock Test-SecureBoot { $false }
        Mock Get-BootMenuKey { 'F12' }
        Mock Get-OtherSystem { $null }
        Mock Get-SpaceInfo { [pscustomobject]@{ UsableGB = 100; TailFree = 0; Partition = [pscustomobject]@{ DiskNumber = 0; Size = [int64]200GB } } }
        Mock Get-Volume { [pscustomobject]@{ Size = [int64]200GB; SizeRemaining = [int64]100GB } }
        Mock Get-Disk { [pscustomobject]@{ FriendlyName = 'Disk' } }
    }
    It 'stops a new install on a PC with a blocker' {
        Mock Get-InstallStatus { 'none' }
        { Get-StartupInfo } | Should -Throw 'blocked'
    }
    It 'still lets someone undo on that PC' {
        Mock Get-InstallStatus { 'leftover' }
        (Get-StartupInfo).Status | Should -Be 'leftover'
    }
}

Describe 'Get-WindowsEsp' {
    BeforeEach {
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 1 } }
        Mock Get-Partition {
            [pscustomobject]@{ Guid = '{other}'; DiskNumber = 1; GptType = $EspType; IsSystem = $false }
            [pscustomobject]@{ Guid = '{first}'; DiskNumber = 0; GptType = $EspType; IsSystem = $true }
            [pscustomobject]@{ Guid = '{data}'; DiskNumber = 1; GptType = $BasicDataType; IsSystem = $false }
        }
    }
    It 'finds the one Windows starts from, even on another disk' {
        (Get-WindowsEsp).Guid | Should -Be '{first}'
    }
    It 'falls back to the Windows disk' {
        Mock Get-Partition { [pscustomobject]@{ Guid = '{other}'; DiskNumber = 1; GptType = $EspType; IsSystem = $false } }
        (Get-WindowsEsp).Guid | Should -Be '{other}'
    }
    It 'says so when there is none' {
        Mock Get-Partition { }
        { Get-WindowsEsp } | Should -Throw '*EFI system partition*'
    }
}

Describe 'Invoke-Cleanup' {
    BeforeEach {
        $script:removed = @()
        $state = [pscustomobject]@{ Partitions = @(); WindowsShrunk = $true; FastStartupWasOn = $false; BitLockerPaused = $false }
        Mock Read-State { $state }
        Mock Get-BcdEntries { }
        Mock Get-FirmwareEntries { }
        Mock Use-Esp { }
        Mock Get-RecordedPartitions { }
        Mock Remove-PartitionAt { $script:removed += $Offset }
        Mock Get-HopPartitions {
            [pscustomobject]@{ Label = 'LINUXBOOT'; Partition = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]100GB } }
            [pscustomobject]@{ Label = 'HOPINSTALL'; Partition = [pscustomobject]@{ DiskNumber = 0; Offset = [int64]160GB } }
        }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Size = [int64]100GB } }
        Mock Get-PartitionSupportedSize { [pscustomobject]@{ SizeMax = [int64]100GB } }
    }
    It 'removes every partition hop made when Linux is not installed' {
        Mock Test-LinuxInstalled { $false }
        Invoke-Cleanup
        $script:removed | Should -Be @([int64]100GB, [int64]160GB)
    }
    It 'only removes the installer when Linux turns out to be installed' {
        Mock Test-LinuxInstalled { $true }
        Invoke-Cleanup
        $script:removed | Should -Be @([int64]160GB)
    }
}

Describe 'Remove-PartitionAt' {
    BeforeEach {
        # Behaves like a disk whose numbers close up after a removal.
        $script:disk = @(
            [pscustomobject]@{ Name = 'windows'; Offset = [int64]1GB; IsSystem = $false; IsBoot = $true }
            [pscustomobject]@{ Name = 'boot'; Offset = [int64]100GB; IsSystem = $false; IsBoot = $false }
            [pscustomobject]@{ Name = 'root'; Offset = [int64]101GB; IsSystem = $false; IsBoot = $false }
            [pscustomobject]@{ Name = 'installer'; Offset = [int64]160GB; IsSystem = $false; IsBoot = $false }
            [pscustomobject]@{ Name = 'recovery'; Offset = [int64]168GB; IsSystem = $false; IsBoot = $false }
        )
        Mock Get-Partition {
            $number = 0
            foreach ($item in $script:disk) {
                $number++
                $item | Add-Member -NotePropertyName PartitionNumber -NotePropertyValue $number -Force
                $item | Add-Member -NotePropertyName DiskNumber -NotePropertyValue 0 -Force
                $item
            }
        }
        Mock Remove-Partition {
            $gone = $PartitionNumber
            $script:disk = @($script:disk | Where-Object { $_.PartitionNumber -ne $gone })
        }
    }
    It 'keeps the recovery partition when numbers shift during a clean-up' {
        foreach ($offset in [int64]100GB, [int64]101GB, [int64]160GB) { Remove-PartitionAt 0 $offset }
        ($script:disk.Name -join ',') | Should -Be 'windows,recovery'
    }
    It 'does nothing when the partition has already gone' {
        Remove-PartitionAt 0 ([int64]500GB)
        @($script:disk).Count | Should -Be 5
    }
    It 'refuses a partition Windows needs' {
        { Remove-PartitionAt 0 ([int64]1GB) } | Should -Throw '*Refusing*'
    }
}

Describe 'Get-Blockers' {
    BeforeEach {
        Mock Test-Uefi { $true }
        Mock Get-CimInstance { [pscustomobject]@{ Architecture = 9 } } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ PartitionStyle = 'GPT'; BusType = 'NVMe' } }
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Healthy' } }
    }
    It 'has nothing to say on a normal PC' {
        @(Get-Blockers).Count | Should -Be 0
    }
    It 'stops on Legacy BIOS' {
        Mock Test-Uefi { $false }
        Get-Blockers | Should -BeLike '*Legacy BIOS*'
    }
    It 'stops on ARM' {
        Mock Get-CimInstance { [pscustomobject]@{ Architecture = 12 } } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Get-Blockers | Should -BeLike '*ARM*'
    }
    It 'stops on an MBR disk' {
        Mock Get-Disk { [pscustomobject]@{ PartitionStyle = 'MBR'; BusType = 'SATA' } }
        Get-Blockers | Should -BeLike '*MBR*'
    }
    It 'stops on a damaged volume' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'NTFS'; HealthStatus = 'Unhealthy' } }
        Get-Blockers | Should -BeLike '*chkdsk*'
    }
}

Describe 'Get-Warnings' {
    BeforeEach {
        Mock Get-CimInstance { $null } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CimInstance { [pscustomobject]@{ TotalPhysicalMemory = [int64]16GB } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ BusType = 'NVMe' } }
        Mock Test-RestartPending { $false }
        Mock Test-BitLockerOn { $false }
    }
    It 'has nothing to say on a normal PC' {
        @(Get-Warnings).Count | Should -Be 0
    }
    It 'asks for the charger on battery' {
        Mock Get-CimInstance { [pscustomobject]@{ BatteryStatus = 1; EstimatedChargeRemaining = 40 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Get-Warnings | Should -BeLike '*charger*40%*'
    }
    It 'does not mind a battery on AC power' {
        Mock Get-CimInstance { [pscustomobject]@{ BatteryStatus = 2; EstimatedChargeRemaining = 0 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        @(Get-Warnings).Count | Should -Be 0
    }
    It 'warns about RAID mode' {
        Mock Get-Disk { [pscustomobject]@{ BusType = 'RAID' } }
        Get-Warnings | Should -BeLike '*RAID*'
    }
    It 'warns about a pending update and BitLocker' {
        Mock Test-RestartPending { $true }
        Mock Test-BitLockerOn { $true }
        @(Get-Warnings).Count | Should -Be 2
    }
}

Describe 'Suspend-BitLockerForRestart' {
    BeforeEach {
        Mock Suspend-BitLockerForSetup { $true }
        Mock Test-BitLockerOn { $false }
    }
    It 'pauses BitLocker that has come back on, and remembers' {
        Mock Test-BitLockerOn { $true }
        $state = [pscustomobject]@{ BitLockerPaused = $false }
        Suspend-BitLockerForRestart $state
        Should -Invoke Suspend-BitLockerForSetup -Times 1
        $state.BitLockerPaused | Should -BeTrue
    }
    It 'leaves a PC without BitLocker alone' {
        Suspend-BitLockerForRestart ([pscustomobject]@{ BitLockerPaused = $false })
        Should -Invoke Suspend-BitLockerForSetup -Times 0
    }
}

Describe 'Get-BootMenuKey' {
    It 'knows MSI, the laptop this was built on' {
        Mock Get-CimInstance { [pscustomobject]@{ Manufacturer = 'Micro-Star International Co., Ltd.' } }
        Get-BootMenuKey | Should -Be 'F11'
    }
    It 'lists the usual keys for an unknown maker' {
        Mock Get-CimInstance { [pscustomobject]@{ Manufacturer = 'Someone Else' } }
        Get-BootMenuKey | Should -BeLike '*F12*'
    }
}

Describe 'Get-Steps' {
    It 'names the partitions hop made for a prepared system' {
        $steps = (Get-Steps (Get-Catalog | Where-Object Id -eq 'elementary') 60).Steps -join ' '
        $steps | Should -BeLike "*$RootLabel*"
        $steps | Should -BeLike "*$BootLabel*"
        $steps | Should -BeLike '*59 GB*'
    }
    It 'warns against Erase disk for a free space system' {
        ((Get-Steps (Get-Catalog | Where-Object Id -eq 'ubuntu') 60).Steps -join ' ') | Should -BeLike '*Erase disk*'
    }
}

Describe 'Remove-PersonalNames' {
    It 'takes out the user and computer names' {
        $text = "C:\Users\$env:USERNAME\Downloads on $env:COMPUTERNAME"
        (Remove-PersonalNames $text) | Should -Not -BeLike "*$env:USERNAME*"
        (Remove-PersonalNames $text) | Should -Not -BeLike "*$env:COMPUTERNAME*"
    }
}

Describe 'DiskProbe' {
    BeforeAll {
        function New-Head([int]$Offset, [byte[]]$Bytes) {
            $head = New-Object byte[] (128KB)
            [Array]::Copy($Bytes, 0, $head, $Offset, $Bytes.Length)
            , $head
        }
        function Get-Ascii([string]$Text) { , [Text.Encoding]::ASCII.GetBytes($Text) }
    }
    It 'recognises <name>' -ForEach @(
        @{ name = 'btrfs'; offset = 65600; text = '_BHRfS_M' }
        @{ name = 'xfs'; offset = 0; text = 'XFSB' }
        @{ name = 'lvm'; offset = 512; text = 'LABELONE' }
        @{ name = 'swap'; offset = 4086; text = 'SWAPSPACE2' }
        @{ name = 'bitlocker'; offset = 3; text = '-FVE-FS-' }
    ) {
        [Hop.DiskProbe]::Identify((New-Head $offset (Get-Ascii $text))) | Should -Be $name
    }
    It 'recognises LUKS' {
        [Hop.DiskProbe]::Identify((New-Head 0 ([byte[]](0x4C, 0x55, 0x4B, 0x53, 0xBA, 0xBE)))) | Should -Be 'luks'
    }
    It 'recognises ext by its magic number and a sensible superblock' {
        $head = New-Head 1080 ([byte[]](0x53, 0xEF))
        [BitConverter]::GetBytes([uint32]1000).CopyTo($head, 1024)
        [Hop.DiskProbe]::Identify($head) | Should -Be 'ext'
    }
    It 'is not fooled by the ext magic number alone' {
        [Hop.DiskProbe]::Identify((New-Head 1080 ([byte[]](0x53, 0xEF)))) | Should -BeNullOrEmpty
    }
    It 'says nothing about an empty partition' {
        [Hop.DiskProbe]::Identify((New-Object byte[] (128KB))) | Should -BeNullOrEmpty
    }
    It 'does not count BitLocker as Linux' {
        $LinuxSignatures | Should -Not -Contain 'bitlocker'
    }
}

Describe 'Firmware load option' {
    It 'lays the entry out the way UEFI expects' {
        $guid = [guid]'11111111-2222-3333-4444-555555555555'
        $option = [Hop.Firmware]::LoadOption('A', 1, 2048, 4096, $guid, '\EFI\hop\BOOTX64.EFI')

        [BitConverter]::ToUInt32($option, 0) | Should -Be 1                # LOAD_OPTION_ACTIVE
        [Text.Encoding]::Unicode.GetString($option, 6, 2) | Should -Be 'A' # description
        $path = 10                                                         # after attributes, length, "A\0"
        $option[$path] | Should -Be 4                                      # media device path
        $option[$path + 1] | Should -Be 1                                  # hard drive
        [BitConverter]::ToUInt16($option, $path + 2) | Should -Be 42
        [BitConverter]::ToUInt32($option, $path + 4) | Should -Be 1        # partition number
        [BitConverter]::ToUInt64($option, $path + 8) | Should -Be 2048     # start
        [BitConverter]::ToUInt64($option, $path + 16) | Should -Be 4096    # size
        $option[$path + 40] | Should -Be 2                                 # GPT
        $option[$path + 41] | Should -Be 2                                 # GUID signature

        $file = $path + 42
        $option[$file + 1] | Should -Be 4                                  # file path node
        $option[($option.Length - 4)..($option.Length - 1)] -join ',' | Should -Be '127,255,4,0'   # end node
        [BitConverter]::ToUInt16($option, 4) | Should -Be ($option.Length - $path)                 # path length
    }
}
