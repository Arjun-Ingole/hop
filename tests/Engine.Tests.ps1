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

    It 'marks the systems that need Secure Boot off' {
        @($catalog | Where-Object SecureBootOff).Id | Should -Be @('pop', 'cachyos', 'arch')
    }
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
            $distro.Kind | Should -BeIn @('ubuntu', 'mint', 'pop', 'elementary', 'zorin', 'debian', 'fedora', 'ultramarine', 'cachyos', 'arch')
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
    It 'leaves out the systems whose ISO has a file FAT32 cannot hold' {
        $catalog.Id | Should -Not -Contain 'kubuntu'
        $catalog.Id | Should -Not -Contain 'omarchy'
    }
    It 'edits the boot files of the systems that need it, with the edit they cannot start without first' {
        foreach ($distro in $catalog | Where-Object BootEdits) {
            $distro.BootConfigs | Should -Not -BeNullOrEmpty
            $distro.Live | Should -Not -BeNullOrEmpty
            @($distro.BootEdits.Values)[0] | Should -Match "=$InstallerLabel(\s|$)"
        }
    }
    It 'keeps Ubuntu and its flavours exactly as they were' {
        foreach ($distro in $catalog | Where-Object Kind -in @('ubuntu', 'mint', 'pop', 'elementary', 'zorin')) {
            $distro.Live | Should -BeNullOrEmpty
            $distro.BootEdits | Should -BeNullOrEmpty
            $distro.GrubDir | Should -BeNullOrEmpty
            $distro.EspShell | Should -BeNullOrEmpty
        }
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
    It 'picks the newest Zorin OS, counting rereleases, and skips other editions' {
        Mock Get-WebText { 'href="17/" href="18/" href="public/"' } -ParameterFilter { $Url -like '*/zorinos-isos/' }
        Mock Get-WebText {
            "$('1' * 64)  Zorin-OS-18-Core-64-bit-r3.iso`n$('2' * 64)  Zorin-OS-18.1-Core-64-bit.iso`n$('3' * 64)  Zorin-OS-18.1-Core-64-bit-r1.iso`n$('4' * 64)  Zorin-OS-18.1-Education-64-bit-r9.iso`n"
        } -ParameterFilter { $Url -like '*/18/SHA256SUMS.txt' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'zorin')
        $download.Url | Should -Be 'https://mirrors.edge.kernel.org/zorinos-isos/18/Zorin-OS-18.1-Core-64-bit-r1.iso'
        $download.Sha256 | Should -Be ('3' * 64)
    }
    It 'takes the GNOME ISO from Debian''s live checksums, not the files beside it' {
        Mock Get-WebText { "$('1' * 64)  debian-live-13.7.0-amd64-cinnamon.iso`n$('2' * 64)  debian-live-13.7.0-amd64-gnome.iso.contents`n$('3' * 64)  debian-live-13.7.0-amd64-gnome.iso`n" }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'debian')
        $download.FileName | Should -Be 'debian-live-13.7.0-amd64-gnome.iso'
        $download.Sha256 | Should -Be ('3' * 64)
    }
    It 'picks the newest final Fedora Workstation for this kind of PC, not a beta' {
        Mock Invoke-RestMethod {
            , @(
                [pscustomobject]@{ version = '45 Beta'; arch = 'x86_64'; variant = 'Workstation'; link = 'https://x/beta.iso'; sha256 = 'b'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'aarch64'; variant = 'Workstation'; link = 'https://x/arm.iso'; sha256 = 'c'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'x86_64'; variant = 'KDE'; link = 'https://x/kde.iso'; sha256 = 'd'; size = '1' }
                [pscustomobject]@{ version = '9'; arch = 'x86_64'; variant = 'Workstation'; link = 'https://x/old.iso'; sha256 = 'e'; size = '1' }
                [pscustomobject]@{ version = '44'; arch = 'x86_64'; variant = 'Workstation'; link = 'https://x/44.iso'; sha256 = 'f'; size = '2851612672' }
            )
        }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'fedora')
        $download.Url | Should -Be 'https://x/44.iso'
        $download.Sha256 | Should -Be 'f'
        $download.Size | Should -Be 2851612672
    }
    It 'skips an Ultramarine version with no ISO yet, and reads its checksum file''s odd path' {
        Mock Get-WebText { 'href="../" href="44/" href="45/"' } -ParameterFilter { $Url -like '*/isos/ultramarine/' }
        Mock Get-WebText { throw 'not there' } -ParameterFilter { $Url -like '*/45/*' }
        Mock Get-WebText { "$hash  artifacts/gnome-gnome-live-anaconda-x86_64-iso/ultramarine-gnome-44-live-anaconda-x86_64.iso`n" } -ParameterFilter { $Url -like '*/44/*' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'ultramarine')
        $download.FileName | Should -Be 'ultramarine-gnome-44-live-anaconda-x86_64.iso'
        $download.Sha256 | Should -Be $hash
    }
    It 'picks the newest CachyOS build with a checksum, from the host that works on Windows 10' {
        Mock Get-WebText { '<a href="../">x</a><a href="260628/">a</a> <a href="260809/">b</a> <a href="261001/">c</a>' } -ParameterFilter { $Url -like '*/ISO/desktop/' }
        Mock Get-WebText { throw 'not yet' } -ParameterFilter { $Url -like '*/261001/*' }
        Mock Get-WebText { "$hash  cachyos-desktop-linux-260809.iso`n" } -ParameterFilter { $Url -like '*/260809/*.sha256' }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'cachyos')
        $download.Url | Should -Be 'https://cdn77.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso'
        $download.Sha256 | Should -Be $hash
    }
    It 'takes the dated Arch ISO, whose name is the same on every mirror' {
        Mock Get-WebText { "$hash  archlinux-2026.10.01-x86_64.iso`n$hash  archlinux-x86_64.iso`n$('1' * 64)  archlinux-bootstrap-2026.10.01-x86_64.tar.zst`n" }
        $download = Resolve-Download (Get-Catalog | Where-Object Id -eq 'arch')
        $download.Url | Should -Be 'https://geo.mirror.pkgbuild.com/iso/latest/archlinux-2026.10.01-x86_64.iso'
        $download.Sha256 | Should -Be $hash
    }
}

Describe 'Download helpers' {
    It 'explains common curl failures' {
        Get-CurlMessage 6 | Should -BeLike '*internet*'
        Get-CurlMessage 60 | Should -BeLike '*date and time*'
        Get-CurlMessage 23 | Should -BeLike '*free space*'
        Get-CurlMessage 22 | Should -BeLike '*server returned an error*'
        Get-CurlMessage 99 | Should -BeLike '*curl error 99*'
    }
    Context 'when the server refuses to resume' {
        BeforeEach {
            Set-Content -LiteralPath 'TestDrive:\a.iso.part' -Value 'partial'
            Mock Assert-DownloadRoom { }
            Mock Invoke-WebRequest { throw 'no' }
            Mock Invoke-Curl { 22 }
        }
        It 'keeps the partial file when the server is not answering' {
            { Invoke-Download ([pscustomobject]@{ Url = 'https://x/a.iso'; Size = 100; FileName = 'a.iso' }) 'TestDrive:\a.iso' } | Should -Throw '*server returned an error*'
            'TestDrive:\a.iso.part' | Should -Exist
        }
        It 'starts again when the server is answering' {
            Mock Test-ServerAnswers { $true }
            { Invoke-Download ([pscustomobject]@{ Url = 'https://x/a.iso'; Size = 100; FileName = 'a.iso' }) 'TestDrive:\a.iso' } | Should -Throw
            Should -Invoke Invoke-Curl -Times 2
        }
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
    It 'puts Linux last and the installer straight before it, on megabyte boundaries' {
        Mock Get-SpaceInfo { New-Space ([int64]10GB + 123456) 150 }
        $plan = Get-Plan 60 8
        $plan.InstallerOffset % 1MB | Should -Be 0
        $plan.FreeStart % 1MB | Should -Be 0
        $plan.InstallerOffset + 8GB | Should -Be $plan.FreeStart
        $plan.FreeStart + 60GB | Should -Be ([int64]211GB)
    }
    It 'keeps what is left over next to C:' {
        Mock Get-SpaceInfo { New-Space ([int64]100GB) 150 }
        (Get-Plan 60 8).InstallerOffset | Should -Be ([int64]233GB)
    }
    It 'refuses a size that does not fit, and says how much does' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 50 }
        { Get-Plan 60 8 } | Should -Throw '*42 GB or less*'
    }
    It 'refuses when too little is free for any Linux' {
        Mock Get-SpaceInfo { New-Space ([int64]0) 20 }
        { Get-Plan 25 8 } | Should -Throw '*GB more*plenty free*Make room*'
    }
}

Describe 'Get-StuckGB' {
    BeforeAll {
        function New-Space([int64]$TailFree, [int]$UsableGB) { [pscustomobject]@{ TailFree = $TailFree; UsableGB = $UsableGB } }
    }
    It 'finds free space that can not be released, as in issue 4' {
        Get-StuckGB ([int64]239GB) (New-Space ([int64]0) 0) | Should -Be 231
    }
    It 'treats a negative usable size as nothing released' {
        Get-StuckGB ([int64]239GB) (New-Space ([int64]0) -5) | Should -Be 231
    }
    It 'finds nothing stuck when Windows can release it all' {
        Get-StuckGB ([int64]100GB) (New-Space ([int64]0) 92) | Should -Be 0
    }
    It 'does not count free space after C: as released from it' {
        Get-StuckGB ([int64]100GB) (New-Space ([int64]50GB) 50) | Should -Be 92
    }
    It 'finds nothing stuck on a nearly full drive' {
        Get-StuckGB ([int64]2GB) (New-Space ([int64]0) 0) | Should -Be 0
    }
}

Describe 'Make room' {
    BeforeAll {
        $RoomPath = Join-Path $TestDrive 'make-room.json'
        $Logged = @'
A volume shrink analysis was initiated on volume Windows (C:).
 Diagnostic details:
 - The last unmovable file appears to be: \$Extend\$UsnJrnl:$J:$DATA
 - The last cluster of the file is: 0x25716c4
 To find more details please use the "fsutil volume querycluster \\?\Volume{bc7f279c} 0x25716c4" command.
'@
    }
    BeforeEach {
        Remove-Item $RoomPath -ErrorAction SilentlyContinue
        Mock Test-HibernationOn { $true }
        Mock Test-EnoughMemoryWithoutPaging { $true }
        Mock Get-PagingSettings { @('?:\pagefile.sys') }
        Mock Set-Hibernation { }
        Mock Clear-ChangeJournal { }
        Mock New-ChangeJournal { }
        Mock Set-PagingOff { }
        Mock Restore-Paging { }
        Mock Register-RunAfterRestart { }
        Mock Unregister-RunAfterRestart { }
        Mock Invoke-Shutdown { }
        Mock Invoke-Defrag { }
        Mock Get-LastBoot { [datetime]'2030-01-01' }
    }
    It 'reads the file from the message Windows logs' {
        Get-BlockerFile $Logged | Should -Be '\$Extend\$UsnJrnl:$J:$DATA'
    }
    It 'sorts blockers by what can be done about them' {
        Get-BlockerKind '\hiberfil.sys' | Should -Be 'hibernation'
        Get-BlockerKind '\pagefile.sys' | Should -Be 'paging'
        Get-BlockerKind '\swapfile.sys' | Should -Be 'paging'
        Get-BlockerKind '\System Volume Information\{a}' | Should -Be 'restore'
        Get-BlockerKind '\$Extend\$UsnJrnl:$J:$DATA' | Should -Be 'journal'
        Get-BlockerKind '\$MFT::$DATA' | Should -Be 'ntfs'
        Get-BlockerKind '\Users\a\b.txt' | Should -Be 'file'
        Get-BlockerKind '' | Should -Be 'unknown'
    }
    It 'saves what it changes before changing it, then restarts' {
        Mock Set-Hibernation { Test-Path $RoomPath | Should -BeTrue }
        Start-MakeRoom
        (Read-RoomState).Phase | Should -Be 'restarting'
        Should -Invoke Set-PagingOff -Times 1
        Should -Invoke Invoke-Shutdown -Times 1
    }
    It 'only takes paging off the system drive' {
        $files = Get-PagingWithoutSystemDrive @("$env:SystemDrive\pagefile.sys 0 0", 'Z:\pagefile.sys 0 0', '?:\pagefile.sys')
        $files | Should -Be @('Z:\pagefile.sys 0 0')
    }
    It 'gets back the exact paging settings it saved' {
        Mock Get-PagingSettings { @('Z:\pagefile.sys 0 0', '?:\pagefile.sys') }
        Start-MakeRoom
        Restore-RoomSettings
        Should -Invoke Restore-Paging -ParameterFilter { ($Saved -join '|') -eq 'Z:\pagefile.sys 0 0|?:\pagefile.sys' } -Times 1
    }
    It 'leaves the paging file on when memory is low' {
        Mock Test-EnoughMemoryWithoutPaging { $false }
        Start-MakeRoom
        Should -Invoke Set-PagingOff -Times 0
    }
    It 'puts everything back if the restart fails' {
        Mock Invoke-Shutdown { throw 'no' }
        { Start-MakeRoom } | Should -Throw 'no'
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 1
        Should -Invoke Restore-Paging -Times 1
        Test-Path $RoomPath | Should -BeFalse
    }
    It 'continues after the restart' {
        Start-MakeRoom
        Get-RoomPhase | Should -Be 'continue'
        Complete-MakeRoom
        Should -Invoke Invoke-Defrag -Times 1
        (Read-RoomState).Phase | Should -Be 'ready'
    }
    It 'restores if the restart never happened' {
        Start-MakeRoom
        Mock Get-LastBoot { [datetime]'2000-01-01' }
        Get-RoomPhase | Should -Be 'restore'
    }
    It 'restores after a crash once it had finished' {
        Start-MakeRoom
        Complete-MakeRoom
        Get-RoomPhase | Should -Be 'restore'
    }
    It 'has nothing to do when it never ran' {
        Get-RoomPhase | Should -BeNullOrEmpty
        Restore-RoomSettings
        Should -Invoke Restore-Paging -Times 0
    }
    It 'only turns hibernation back on if it was on' {
        Mock Test-HibernationOn { $false }
        Start-MakeRoom
        Restore-RoomSettings
        Should -Invoke Set-Hibernation -ParameterFilter { $On } -Times 0
    }
    It 'finishes restoring when one part fails' {
        Mock Set-Hibernation { if ($On) { throw 'no' } }
        Start-MakeRoom
        Restore-RoomSettings
        Should -Invoke Restore-Paging -Times 1
        Test-Path $RoomPath | Should -BeFalse
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
    BeforeEach { Mock Get-WindowsPartition { [pscustomobject]@{ DiskNumber = 0 } } }
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

Describe 'Get-IsoKernelPath' {
    BeforeEach {
        $iso = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$iso\boot\grub" | Out-Null
    }
    It 'skips a memory tester listed first' {
        Set-Content "$iso\boot\grub\grub.cfg" "menuentry 'a' {`n  linux /boot/memtest.efi`n}`nmenuentry 'b' {`n  linux /casper/vmlinuz quiet`n}"
        Get-IsoKernelPath $iso | Should -Be "$iso\casper\vmlinuz"
    }
    It 'says nothing without a menu' {
        Get-IsoKernelPath (Join-Path $TestDrive 'none') | Should -BeNullOrEmpty
    }
    It 'reads Fedora''s menu, which is elsewhere and writes ($root) before its paths' {
        New-Item -ItemType Directory -Path "$iso\boot\grub2" -Force | Out-Null
        Remove-Item "$iso\boot\grub" -Recurse
        Set-Content "$iso\boot\grub2\grub.cfg" "menuentry 'a' {`n`tlinux (`$root)/boot/x86_64/loader/linux quiet`n}"
        Get-IsoKernelPath $iso | Should -Be "$iso\boot\x86_64\loader\linux"
    }
}

Describe 'Boot config' {
    BeforeAll {
        function Get-CatalogEntry([string]$Id) { Get-Catalog | Where-Object Id -eq $Id }
        function Get-Edited([string]$Id, [string]$Text) { Get-EditedBootConfig (Get-CatalogEntry $Id) $Text }
    }
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$root\boot\grub2", "$root\boot\grub", "$root\loader\entries" -Force | Out-Null
    }
    It 'points Fedora at the installer partition, as in Fedora 44''s menu' {
        $text = Get-Edited 'fedora' "search --file --set=root /boot/0xf20784ad`n`tlinux (`$root)/boot/x86_64/loader/linux quiet rhgb  root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image rd.live.check`n"
        $text | Should -BeLike "*root=live:LABEL=$InstallerLabel *rd.live.image*"
        $text | Should -BeLike "search --no-floppy --label --set=root $InstallerLabel*"
        $text | Should -Not -BeLike '*CDLABEL*'
        $text | Should -Not -BeLike '*rd.live.check*'
    }
    It 'points Ultramarine at the installer partition, as in Ultramarine 44''s menu' {
        $text = Get-Edited 'ultramarine' "search --no-floppy --set=root --label 'UM-Gn-Live-Anaconda'`n`tlinux /boot/vmlinuz root=live:CDLABEL=UM-Gn-Live-Anaconda rd.live.image rd.live.check enforcing=0 quiet rhgb`n"
        $text | Should -BeLike "*root=live:LABEL=$InstallerLabel *rd.live.image enforcing=0 quiet rhgb*"
        $text | Should -BeLike "search --no-floppy --label --set=root $InstallerLabel*"
        $text | Should -Not -BeLike '*UM-Gn*'
    }
    It 'frees the installer''s drive for Anaconda without losing the desktop, as tested in Fedora 44' {
        foreach ($id in 'fedora', 'ultramarine') {
            $text = Get-Edited $id 'linux /x root=live:CDLABEL=X rd.live.image'
            # Quoted for GRUB, so that it stays one argument. Each of the others stops systemd.run replacing the normal start.
            $text | Should -BeLike '*"systemd.run=/usr/bin/umount -l /run/initramfs/live" *'
            foreach ($needed in 'systemd.run_success_action=none', 'systemd.run_failure_action=none', 'systemd.unit=graphical.target', 'systemd.wants=kernel-command-line.service') {
                $text | Should -BeLike "* $needed *"
            }
        }
    }
    It 'points CachyOS and Arch at the installer partition, and keeps their other settings' {
        Get-Edited 'cachyos' 'linux /arch/boot/x86_64/vmlinuz-linux-cachyos archisobasedir=arch archisosearchuuid=2026-08-09-15-47-03-00 cow_spacesize=10G' |
            Should -Be "linux /arch/boot/x86_64/vmlinuz-linux-cachyos archisobasedir=arch archisolabel=$InstallerLabel cow_spacesize=10G"
        Get-Edited 'arch' 'options  archisobasedir=arch archisosearchuuid=2026-10-01-14-49-03-00 ' |
            Should -Be "options  archisobasedir=arch archisolabel=$InstallerLabel "
    }
    It 'changes every Arch boot entry, and leaves the memory tester alone' {
        Set-Content "$root\loader\entries\01-archiso-linux.conf" 'options  archisobasedir=arch archisosearchuuid=2026 '
        Set-Content "$root\loader\entries\02-archiso-speech-linux.conf" 'options  archisobasedir=arch archisosearchuuid=2026 accessibility=on'
        Set-Content "$root\loader\entries\03-archiso-memtest86+x64.conf" 'efi /boot/memtest86+/memtest.efi'
        Update-BootConfig (Get-CatalogEntry 'arch') $root
        Get-Content "$root\loader\entries\01-archiso-linux.conf" | Should -BeLike "*archisolabel=$InstallerLabel*"
        Get-Content "$root\loader\entries\02-archiso-speech-linux.conf" | Should -BeLike "*archisolabel=$InstallerLabel accessibility=on"
        Get-Content "$root\loader\entries\03-archiso-memtest86+x64.conf" | Should -Be 'efi /boot/memtest86+/memtest.efi'
    }
    It 'keeps every other byte, adds no byte order mark and copes with a read-only copy' {
        $path = "$root\boot\grub2\grub.cfg"
        # A menu title in UTF-8, and Unix line endings GRUB relies on.
        $before = [Text.Encoding]::UTF8.GetBytes("menuentry 'Dévelop' {`n`troot=live:CDLABEL=X quiet`n}`n")
        [IO.File]::WriteAllBytes($path, $before)
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        Update-BootConfig (Get-CatalogEntry 'fedora') $root
        $edited = (Get-CatalogEntry 'fedora').BootEdits['root=live:CDLABEL=\S+']
        $expected = [Text.Encoding]::UTF8.GetBytes("menuentry 'Dévelop' {`n`t$edited quiet`n}`n")
        ([IO.File]::ReadAllBytes($path) -join ',') | Should -Be ($expected -join ',')
    }
    It 'touches nothing for Ubuntu' {
        $path = "$root\boot\grub\grub.cfg"
        $before = [Text.Encoding]::ASCII.GetBytes("linux /casper/vmlinuz root=live:CDLABEL=x archisosearchuuid=y --- quiet`n")
        [IO.File]::WriteAllBytes($path, $before)
        Update-BootConfig (Get-CatalogEntry 'ubuntu') $root
        ([IO.File]::ReadAllBytes($path) -join ',') | Should -Be ($before -join ',')
    }
    It 'knows a menu it can edit, and says so when a new release changes it' {
        $fedora = Get-CatalogEntry 'fedora'
        Test-BootConfigKnown $fedora $root | Should -BeFalse
        Set-Content "$root\boot\grub2\grub.cfg" 'linux /x root=UUID=abc'
        Test-BootConfigKnown $fedora $root | Should -BeFalse
        Set-Content "$root\boot\grub2\grub.cfg" 'linux /x root=live:CDLABEL=abc'
        Test-BootConfigKnown $fedora $root | Should -BeTrue
    }
    It 'has nothing to check for Ubuntu' {
        Test-BootConfigKnown (Get-CatalogEntry 'ubuntu') $root | Should -BeTrue
    }
}

Describe 'Copy-EspLoader' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $source = "$root\EFI\BOOT"
        $folder = "$root\esp\EFI\hop"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content "$source\BOOTx64.EFI" 'shim'
        Set-Content "$source\grubx64.efi" 'grub'
        Set-Content "$source\grub.cfg" 'from the iso'
    }
    It 'writes Ubuntu''s files exactly as builds before this one did' {
        Copy-EspLoader (Get-Catalog | Where-Object Id -eq 'ubuntu') $source $folder
        @(Get-ChildItem $folder | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('BOOTx64.EFI', 'grub.cfg', 'grubx64.efi')
        [IO.File]::ReadAllText("$folder\grub.cfg") | Should -BeExactly "search --no-floppy --file --set=root /.disk/info`r`nset prefix=(`$root)/boot/grub`r`nconfigfile `$prefix/grub.cfg`r`n"
    }
    It 'writes the same for a chosen ISO, Zorin OS and Debian, which have /.disk/info' {
        foreach ($distro in (Get-Distro 'custom' 'a.iso'), (Get-Catalog | Where-Object Id -eq 'zorin'), (Get-Catalog | Where-Object Id -eq 'debian')) {
            (Get-EspGrubConfig $distro) -join '|' | Should -BeExactly 'search --no-floppy --file --set=root /.disk/info|set prefix=($root)/boot/grub|configfile $prefix/grub.cfg'
        }
    }
    It 'finds the installer by label for systems without /.disk/info' {
        foreach ($case in @(@('fedora', 'boot/grub2'), @('ultramarine', 'boot/grub'), @('cachyos', 'boot/grub'))) {
            (Get-EspGrubConfig (Get-Catalog | Where-Object Id -eq $case[0])) -join '|' |
                Should -BeExactly "search --no-floppy --label --set=root $InstallerLabel|set prefix=(`$root)/$($case[1])|configfile `$prefix/grub.cfg"
        }
    }
    It 'starts Arch through the ISO''s EFI Shell, because systemd-boot cannot leave its partition' {
        $arch = Get-Catalog | Where-Object Id -eq 'arch'
        Set-Content "$root\shellx64.efi" 'shell'
        Copy-EspLoader $arch $source $folder
        (Get-Content "$folder\BOOTX64.EFI") | Should -Be 'shell'
        "$folder\grub.cfg" | Should -Not -Exist
        "$folder\grubx64.efi" | Should -Not -Exist
        $script = (Get-Content "$folder\startup.nsh") -join "`n"
        $script | Should -BeLike '*if exist fs%a:\arch\x86_64\airootfs.sfs then*'
        $script | Should -BeLike '*\EFI\BOOT\BOOTx64.EFI*'
    }
}

Describe 'Read-Iso' {
    BeforeAll {
        function New-IsoFiles([hashtable]$Files) {
            foreach ($name in $Files.Keys) {
                $path = Join-Path $isoRoot $name
                New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
                Set-Content -LiteralPath $path -Value $Files[$name]
            }
        }
    }
    BeforeEach {
        $isoRoot = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $isoRoot | Out-Null
        New-PSDrive -Name HOPISO -PSProvider FileSystem -Root $isoRoot -Scope Global | Out-Null
        Mock Mount-Iso { 'HOPISO' }
        Mock Get-SecureBootProblem { }
        Mock Set-Status { }
    }
    AfterEach { Remove-PSDrive -Name HOPISO -Scope Global }
    It 'still wants casper and /.disk/info for a chosen ISO' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'LiveOS\squashfs.img' = 'x' }
        { Read-Iso 'a.iso' (Get-Distro 'custom' 'a.iso') } | Should -Throw '*Ubuntu-style*'
    }
    It 'accepts Fedora, whose ISO has neither' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'LiveOS\squashfs.img' = 'x'; 'boot\grub2\grub.cfg' = 'linux ($root)/boot/x root=live:CDLABEL=a'; 'boot\x' = 'x' }
        (Read-Iso 'a.iso' (Get-Catalog | Where-Object Id -eq 'fedora')).Letter | Should -Be 'HOPISO'
    }
    It 'refuses the wrong file for the system picked' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'boot\grub2\grub.cfg' = 'root=live:CDLABEL=a' }
        { Read-Iso 'a.iso' (Get-Catalog | Where-Object Id -eq 'fedora') } | Should -Throw "*doesn't look like Fedora*"
    }
    It 'refuses a release that starts in a way hop cannot edit, before the disk changes' {
        New-IsoFiles @{ 'EFI\BOOT\BOOTX64.EFI' = 'x'; 'arch\x86_64\airootfs.sfs' = 'x'; 'boot\grub\grub.cfg' = 'linux /k archisodevice=/dev/x' }
        { Read-Iso 'a.iso' (Get-Catalog | Where-Object Id -eq 'cachyos') } | Should -Throw "*doesn't know yet*Nothing has been changed*"
    }
}

Describe 'Get-StateDistro' {
    It 'finds the system an install was for' {
        (Get-StateDistro ([pscustomobject]@{ DistroId = 'fedora'; Distro = 'Fedora Workstation' })).GrubDir | Should -Be 'boot/grub2'
    }
    It 'treats one no longer in the catalog as a chosen ISO, which starts as Ubuntu does' {
        $distro = Get-StateDistro ([pscustomobject]@{ DistroId = 'gone'; Distro = 'Gone' })
        $distro.Name | Should -Be 'Gone'
        $distro.GrubDir | Should -BeNullOrEmpty
    }
}

Describe 'Repair-ShortenedNames' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$root\dists\noble\main\binary-amd64", "$root\pool\main" | Out-Null
        $long = 'system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd64.deb'
    }
    It 'gives a shortened package its real name back' {
        Set-Content "$root\dists\noble\main\binary-amd64\Packages" "Package: a`nFilename: ./pool/main/$long`n"
        Set-Content "$root\pool\main\system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd6.deb" 'x'
        Repair-ShortenedNames $root
        "$root\pool\main\$long" | Should -Exist
    }
    It 'reads a compressed index' {
        $file = [IO.File]::Create("$root\dists\noble\main\binary-amd64\Packages.gz")
        $zip = New-Object IO.Compression.GZipStream($file, [IO.Compression.CompressionMode]::Compress)
        $bytes = [Text.Encoding]::ASCII.GetBytes("Filename: pool/main/$long`n")
        $zip.Write($bytes, 0, $bytes.Length)
        $zip.Dispose()
        Set-Content "$root\pool\main\system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd6.deb" 'x'
        Repair-ShortenedNames $root
        "$root\pool\main\$long" | Should -Exist
    }
    It 'never renames a file the index also lists' {
        $short = 'system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd6.deb'
        Set-Content "$root\dists\noble\main\binary-amd64\Packages" "Filename: pool/main/$long`nFilename: pool/main/$short`n"
        Set-Content "$root\pool\main\$short" 'x'
        Repair-ShortenedNames $root
        "$root\pool\main\$short" | Should -Exist
        "$root\pool\main\$long" | Should -Not -Exist
    }
    It 'does not guess between two candidates' {
        Set-Content "$root\dists\noble\main\binary-amd64\Packages" "Filename: pool/main/$long`n"
        Set-Content "$root\pool\main\system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_amd6.deb" 'x'
        Set-Content "$root\pool\main\system76-firmware-daemon_1.0.77~1784843200~24.04~0337bd4_a.deb" 'x'
        Repair-ShortenedNames $root
        "$root\pool\main\$long" | Should -Not -Exist
    }
    It 'copes with an ISO that has no package indexes' {
        { Repair-ShortenedNames (Join-Path $TestDrive 'empty') } | Should -Not -Throw
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
        Mock Get-DriveTargets { }
        Mock Get-DownloadDrives { }
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
    It 'gives space back to C: when hop shrank it' {
        Mock Test-LinuxInstalled { $false }
        Mock Get-PartitionSupportedSize { [pscustomobject]@{ SizeMax = [int64]160GB } }
        Mock Resize-Partition { }
        Invoke-Cleanup
        Should -Invoke Resize-Partition -Times 1
    }
    It 'leaves free space alone when hop never shrank C:' {
        Mock Test-LinuxInstalled { $false }
        Mock Read-State { [pscustomobject]@{ Partitions = @(); WindowsShrunk = $false } }
        Mock Get-PartitionSupportedSize { [pscustomobject]@{ SizeMax = [int64]160GB } }
        Mock Resize-Partition { }
        Invoke-Cleanup
        Should -Invoke Resize-Partition -Times 0
    }
    It 'only removes the installer when Linux turns out to be installed' {
        Mock Test-LinuxInstalled { $true }
        Invoke-Cleanup
        $script:removed | Should -Be @([int64]160GB)
    }
}

Describe 'Remove-PartitionAt' {
    BeforeEach {
        # Plain stubs for a disk whose numbers close up after a removal.
        $layout = New-Object Collections.ArrayList
        foreach ($item in @(
                @('windows', [int64]1GB, $true), @('boot', [int64]100GB, $false), @('root', [int64]101GB, $false),
                @('installer', [int64]160GB, $false), @('recovery', [int64]168GB, $false))) {
            [void]$layout.Add([pscustomobject]@{ Name = $item[0]; Offset = $item[1]; IsSystem = $false; IsBoot = $item[2] })
        }
        function Get-Partition {
            param($DiskNumber)
            $number = 0
            foreach ($item in @($layout)) {
                $number++
                $item | Add-Member -NotePropertyName PartitionNumber -NotePropertyValue $number -Force
                $item
            }
        }
        function Remove-Partition {
            param($DiskNumber, $PartitionNumber, $Confirm)
            $layout.RemoveAt([int]$PartitionNumber - 1)
        }
    }
    It 'keeps the recovery partition when numbers shift during a clean-up' {
        foreach ($offset in [int64]100GB, [int64]101GB, [int64]160GB) { Remove-PartitionAt 0 $offset }
        (@($layout | ForEach-Object { $_.Name }) -join ',') | Should -Be 'windows,recovery'
    }
    It 'does nothing when the partition has already gone' {
        Remove-PartitionAt 0 ([int64]500GB)
        $layout.Count | Should -Be 5
    }
    It 'refuses a partition Windows needs' {
        { Remove-PartitionAt 0 ([int64]1GB) } | Should -Throw '*Refusing*'
    }
}

Describe 'Secure Boot' {
    BeforeAll {
        # A minimal 64-bit EFI program, with a signature table holding the given text.
        function New-Efi([string]$Path, [string]$Signature) {
            $text = [Text.Encoding]::ASCII.GetBytes($Signature)
            $bytes = New-Object byte[] (1024 + $text.Length)
            $bytes[0] = 0x4D; $bytes[1] = 0x5A
            [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
            $header = 0x80 + 24
            [BitConverter]::GetBytes([uint16]0x20B).CopyTo($bytes, $header)
            if ($text.Length) {
                [BitConverter]::GetBytes([uint32]1024).CopyTo($bytes, $header + 112 + 32)
                [BitConverter]::GetBytes([uint32]$text.Length).CopyTo($bytes, $header + 112 + 36)
                $text.CopyTo($bytes, 1024)
            }
            [IO.File]::WriteAllBytes($Path, $bytes)
        }
        function New-Iso([string]$Loader, [string]$Kernel) {
            New-Item -ItemType Directory -Path 'TestDrive:\iso\EFI\BOOT', 'TestDrive:\iso\boot\grub', 'TestDrive:\iso\casper' -Force | Out-Null
            $root = (Resolve-Path 'TestDrive:\iso').ProviderPath
            New-Efi (Join-Path $root 'EFI\BOOT\BOOTX64.EFI') $Loader
            New-Efi (Join-Path $root 'casper\vmlinuz') $Kernel
            Set-Content -LiteralPath (Join-Path $root 'boot\grub\grub.cfg') -Value @('menuentry "Try" {', '    linux  /casper/vmlinuz  --- quiet', '}')
            $root
        }
        $ca2011 = 'Microsoft Corporation UEFI CA 2011'
    }
    BeforeEach {
        Mock Test-SecureBoot { $true }
        Mock Test-BitLockerOn { $false }
        Mock Get-SecureBootDb { "xx$ca2011 yy" }
    }
    It 'reads certificate names from a signed program, and nothing from an unsigned one' {
        $root = New-Iso $ca2011 ''
        Get-EfiSignature (Join-Path $root 'EFI\BOOT\BOOTX64.EFI') | Should -BeLike "*$ca2011*"
        Get-EfiSignature (Join-Path $root 'casper\vmlinuz') | Should -BeNullOrEmpty
    }
    It 'knows both third-party certificates, and not the Windows or option ROM ones' {
        Get-UefiAuthorities "$ca2011 Microsoft UEFI CA 2023 Microsoft Option ROM UEFI CA 2023 Windows UEFI CA 2023" |
            Should -Be @($ca2011, 'Microsoft UEFI CA 2023')
    }
    It 'has nothing to say about an ISO this PC will start' {
        Get-SecureBootProblem (New-Iso $ca2011 'Canonical') | Should -BeNullOrEmpty
    }
    It 'does not look when Secure Boot is off' {
        Mock Test-SecureBoot { $false }
        Get-SecureBootProblem (New-Iso '' '') | Should -BeNullOrEmpty
    }
    It 'does not stop an install on a list it could not make sense of' {
        Mock Get-SecureBootDb { 'unreadable bytes' }
        Get-SecureBootProblem (New-Iso $ca2011 'Canonical') | Should -BeNullOrEmpty
    }
    It 'spots a boot loader this PC does not trust, such as a PC with only the 2023 certificate' {
        Mock Get-SecureBootDb { 'Microsoft UEFI CA 2023' }
        Get-SecureBootProblem (New-Iso $ca2011 'Canonical') | Should -BeLike "*doesn't trust*"
    }
    It 'accepts a boot loader signed by two authorities when one is trusted' {
        Mock Get-SecureBootDb { 'Microsoft UEFI CA 2023' }
        Get-SecureBootProblem (New-Iso "$ca2011 Microsoft UEFI CA 2023" 'Canonical') | Should -BeNullOrEmpty
    }
    It 'does not guess when the firmware will not share its list' {
        Mock Get-SecureBootDb { $null }
        Get-SecureBootProblem (New-Iso $ca2011 'Canonical') | Should -BeNullOrEmpty
    }
    It 'spots an unsigned boot loader' {
        Get-SecureBootProblem (New-Iso '' 'Canonical') | Should -BeLike "*boot loader isn't signed*"
    }
    It 'spots an unsigned kernel, as on Pop!_OS' {
        Get-SecureBootProblem (New-Iso $ca2011 '') | Should -BeLike "*kernel isn't signed*"
    }
    It 'mentions the recovery key when BitLocker is on' {
        Mock Test-BitLockerOn { $true }
        Get-SecureBootProblem (New-Iso '' '') | Should -BeLike '*recovery key*'
    }
    It 'stops Pop!_OS before the download' {
        { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq 'pop') } | Should -Throw '*Secure Boot*'
    }
    It 'lets other systems through to the ISO check' {
        { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq 'ubuntu') } | Should -Not -Throw
    }
    It 'stops CachyOS and Arch before the download, whose loaders have no signature' {
        { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq 'cachyos') } | Should -Throw '*Secure Boot*'
        { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq 'arch') } | Should -Throw '*Secure Boot*'
    }
    It 'lets the signed systems through to the ISO check' {
        foreach ($id in 'zorin', 'debian', 'fedora', 'ultramarine') {
            { Assert-SecureBootAllows (Get-Catalog | Where-Object Id -eq $id) } | Should -Not -Throw
        }
    }
    It 'spots an unsigned kernel in a Fedora-style menu' {
        $root = (New-Iso $ca2011 'Canonical')
        Remove-Item (Join-Path $root 'boot\grub\grub.cfg')
        New-Item -ItemType Directory -Path (Join-Path $root 'boot\grub2'), (Join-Path $root 'boot\x86_64\loader') -Force | Out-Null
        Set-Content (Join-Path $root 'boot\grub2\grub.cfg') "menuentry 'a' {`n`tlinux (`$root)/boot/x86_64/loader/linux quiet`n}"
        New-Efi (Join-Path $root 'boot\x86_64\loader\linux') ''
        Get-SecureBootProblem $root | Should -BeLike "*kernel isn't signed*"
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

Describe 'Assert-EspRoom' {
    BeforeEach {
        $source = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'BOOTX64.EFI') -Value 'hop'
        $root = [IO.Path]::GetPathRoot("$TestDrive")
    }
    It 'is happy when the boot loader fits, whatever the system' {
        { Assert-EspRoom $root $source } | Should -Not -Throw
    }
    It 'counts what the Linux installer will add, and says how much is free' {
        { Assert-EspRoom $root $source 2000000000 } | Should -Throw '*too full*MB is free*'
    }
    It 'keeps room for the files Anaconda doesn''t notice failing to copy' {
        foreach ($id in 'fedora', 'ultramarine') { (Get-Catalog | Where-Object Id -eq $id).EspLinuxMB | Should -BeGreaterOrEqual 21 }
        (Get-Catalog | Where-Object Id -eq 'ubuntu').EspLinuxMB | Should -Be 0
    }
}

Describe 'Assert-EspWritable' {
    BeforeEach {
        $root = Join-Path $TestDrive 'esp'
        New-Item -ItemType Directory -Path "$root\EFI" -Force | Out-Null
    }
    It 'leaves nothing behind' {
        Assert-EspWritable $root
        @(Get-ChildItem "$root\EFI").Count | Should -Be 0
    }
    It 'names security software when a write is refused' {
        Mock Set-Content { throw 'Access denied' }
        { Assert-EspWritable $root } | Should -Throw '*Security software*'
    }
}

Describe 'Get-OtherInstallers' {
    BeforeEach {
        $usbStick = Join-Path $TestDrive 'usb\'
        $plain = Join-Path $TestDrive 'plain\'
        New-Item -ItemType Directory -Path "$usbStick.disk", $plain -Force | Out-Null
        Set-Content "$usbStick.disk\info" 'Ubuntu'
    }
    It 'finds an installer on a USB stick, and not on other drives' {
        Mock Get-Volume {
            [pscustomobject]@{ DriveType = 'Removable'; FileSystemLabel = 'Ubuntu'; Path = $usbStick; DriveLetter = 'E' }
            [pscustomobject]@{ DriveType = 'Fixed'; FileSystemLabel = 'Data'; Path = $plain; DriveLetter = 'D' }
        }
        $found = @(Get-OtherInstallers)
        $found.Count | Should -Be 1
        $found[0].Usb | Should -BeTrue
        $found[0].Name | Should -Be 'drive E:'
    }
    It 'ignores hop''s own installer and mounted ISOs' {
        Mock Get-Volume {
            [pscustomobject]@{ DriveType = 'Fixed'; FileSystemLabel = 'HOPINSTALL'; Path = $usbStick; DriveLetter = 'H' }
            [pscustomobject]@{ DriveType = 'CD-ROM'; FileSystemLabel = 'Ubuntu'; Path = $usbStick; DriveLetter = 'F' }
        }
        @(Get-OtherInstallers).Count | Should -Be 0
    }
}

Describe 'Get-Warnings' {
    BeforeEach {
        Mock Get-OtherInstallers { }
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
    It 'asks to unplug a USB installer' {
        Mock Get-OtherInstallers { [pscustomobject]@{ Name = 'drive E:'; Usb = $true } }
        Get-Warnings | Should -BeLike '*Unplug drive E:*'
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

Describe 'Get-ReturnedHelp' {
    BeforeEach {
        Mock Read-State { [pscustomobject]@{ Distro = 'Ubuntu'; BootNumber = 7 } }
        Mock Get-BootMenuKey { 'F11' }
        Mock Test-SecureBoot { $true }
        Mock Test-BootNextIgnored { $false }
        Mock Test-EntryDropped { $false }
    }
    It 'points at the boot menu when the firmware ignored the one-time start' {
        Mock Test-BootNextIgnored { $true }
        (Get-ReturnedHelp).Steps -join ' ' | Should -BeLike '*ignored*F11*'
    }
    It 'says when the firmware removed the entry, not to change Secure Boot' {
        Mock Test-EntryDropped { $true }
        $steps = (Get-ReturnedHelp).Steps -join ' '
        $steps | Should -BeLike '*Boot Order Lock*'
        $steps | Should -Not -BeLike '*Secure Boot*'
    }
    It 'points at Secure Boot when the firmware tried and it is on' {
        (Get-ReturnedHelp).Steps -join ' ' | Should -BeLike '*Secure Boot may have*'
    }
    It 'points at the boot menu when Secure Boot is off' {
        Mock Test-SecureBoot { $false }
        (Get-ReturnedHelp).Steps -join ' ' | Should -BeLike '*F11*'
    }
    It 'copes with a setup that has no startup entry yet' {
        Test-BootNextIgnored ([pscustomobject]@{ BootNumber = $null }) | Should -BeFalse
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
    It 'warns against wiping the drive, and gives the size, on every system with its own steps' {
        foreach ($distro in Get-Catalog | Where-Object Steps) {
            $steps = (Get-Steps $distro 60).Steps -join ' '
            $steps | Should -BeLike '*60 GB*'
            $steps | Should -Not -BeLike '*{GB}*'
            $steps | Should -Match "Don't (choose|change)"
        }
    }
    It 'uses the words on Fedora''s and Ultramarine''s installer screens' {
        foreach ($id in 'fedora', 'ultramarine') {
            ((Get-Steps (Get-Catalog | Where-Object Id -eq $id) 60).Steps -join ' ') | Should -BeLike '*Share disk with other operating systems*Use entire disk*'
        }
    }
    It 'needs no Terminal for Fedora and Ultramarine, and explains the warning about the EFI partition' {
        foreach ($id in 'fedora', 'ultramarine') {
            $steps = (Get-Steps (Get-Catalog | Where-Object Id -eq $id) 60).Steps -join ' '
            $steps | Should -Not -BeLike '*Terminal*'
            $steps | Should -Not -BeLike '*umount*'
            $steps | Should -BeLike '*/boot/efi*carry on*'
        }
    }
    It 'says plainly that Arch installs in a terminal' {
        $steps = (Get-Steps (Get-Catalog | Where-Object Id -eq 'arch') 60).Steps -join ' '
        $steps | Should -BeLike '*no graphical installer*archinstall*Manual Partitioning*'
    }
    It 'tells people to press Enter at Debian''s menu, which has no timeout' {
        ((Get-Steps (Get-Catalog | Where-Object Id -eq 'debian') 60).Steps -join ' ') | Should -BeLike '*press Enter on **Live system***'
    }
    It 'tells CachyOS to use GRUB, whose files fit on the EFI partition' {
        ((Get-Steps (Get-Catalog | Where-Object Id -eq 'cachyos') 60).Steps -join ' ') | Should -BeLike '*Bootloader*GRUB*'
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

Describe 'CancelGate' {
    It 'lets Cancel win before the disk stage, and stops the disk stage' {
        $gate = New-Object Hop.CancelGate
        $gate.TryCancel() | Should -BeTrue
        $gate.EnterDiskStage() | Should -BeFalse
    }
    It 'refuses Cancel once the disk is changing' {
        $gate = New-Object Hop.CancelGate
        $gate.EnterDiskStage() | Should -BeTrue
        $gate.TryCancel() | Should -BeFalse
    }
}

Describe 'Firmware after the Secure Boot check' {
    # Read only. Confirm-SecureBootUEFI turns the firmware privilege off when it finishes,
    # so hop has to ask for it again. This found a bug that stopped installs on every PC.
    It 'can still read the startup menu' {
        try { [void][Hop.Firmware]::BootOrderNumbers() } catch { Set-ItResult -Skipped -Because 'this PC has no readable firmware' }
        [void](Test-SecureBoot)
        { [void][Hop.Firmware]::BootOrderNumbers() } | Should -Not -Throw
    }
}

Describe 'Assert-FirmwareAccess' {
    It 'passes when the startup menu can be changed' {
        Mock Test-FirmwareAccess { }
        { Assert-FirmwareAccess } | Should -Not -Throw
    }
    It 'explains itself and keeps the Windows error' {
        Mock Test-FirmwareAccess { throw 'Windows error 1314: A required privilege is not held by the client' }
        { Assert-FirmwareAccess } | Should -Throw "*startup menu*Nothing has been changed*1314*"
    }
    It 'stops an install before the download' {
        Mock Test-System { }
        Mock Get-InstallStatus { 'none' }
        Mock Assert-SecureBootAllows { }
        Mock Test-FirmwareAccess { throw 'refused' }
        Mock Resolve-Download { }
        { Invoke-Install 'ubuntu' '' 40 } | Should -Throw '*startup menu*'
        Should -Invoke Resolve-Download -Times 0
    }
}

Describe 'Engine' {
    It 'writes the reason a command stopped to the log' {
        $engine = New-Object Hop.Engine
        try {
            $invoke = [Hop.Engine].GetMethod('Invoke', [Reflection.BindingFlags]'NonPublic,Instance')
            { $invoke.Invoke($engine, @('Get-NoSuchHopCommand', $null)) } | Should -Throw
            ($engine.Log -join "`n") | Should -BeLike '*Stopped:*Get-NoSuchHopCommand*'
        } finally { $engine.Dispose() }
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
