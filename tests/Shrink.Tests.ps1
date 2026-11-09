# Shrinking a drive from outside Windows: what hop checks before, what it tells the image, and what it makes of the result.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Load-Engine.ps1')
}

Describe 'The menu the shrink image starts with' {
    It 'names the partition, both sizes, the EFI partition and the attempt, as blkid has them' {
        $menu = Get-ShrinkGrubConfig '{3A5CF585-E347-4D46-A996-DA1791947F18}' 500107862016 400000000000 '{C215B42C-73AC-4794-A4D8-A5B35E54219B}' 'abc123'
        $menu[0] | Should -Be 'set timeout=0'
        $menu | Should -Contain '    linux /EFI/hop-shrink/vmlinuz hop.part=3a5cf585-e347-4d46-a996-da1791947f18 hop.was=500107862016 hop.size=400000000000 hop.esp=c215b42c-73ac-4794-a4d8-a5b35e54219b hop.id=abc123 quiet loglevel=3'
        $menu | Should -Contain '    initrd /EFI/hop-shrink/initrd.img'
    }
}

Describe 'How far the drive shrinks' {
    BeforeEach { Mock Get-TailFree { [int64]0 } }
    It 'takes what Linux needs off the end, in whole MiB' {
        $c = [pscustomobject]@{ Size = [int64]500GB + 12345 }
        Get-ShrinkTarget $c ([int64]60GB) | Should -Be ([int64]440GB)
    }
    It 'counts free space already after it' {
        Mock Get-TailFree { [int64]20GB }
        Get-ShrinkTarget ([pscustomobject]@{ Size = [int64]500GB }) ([int64]60GB) | Should -Be ([int64]460GB)
    }
    It 'leaves a drive alone that already has enough after it' {
        Mock Get-TailFree { [int64]80GB }
        Get-ShrinkTarget ([pscustomobject]@{ Size = [int64]500GB }) ([int64]60GB) | Should -Be ([int64]500GB)
    }
}

Describe 'What stops a shrink from outside Windows' {
    BeforeEach {
        Mock Test-Uefi { $true }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = [int64]1GB; Size = [int64]475GB; Guid = '{A}' } }
        Mock Get-VolumeOf { [pscustomobject]@{ FileSystemType = 'NTFS'; Size = [int64]475GB; SizeRemaining = [int64]197GB } }
        Mock Get-PartitionSignature { 'ntfs' }
        Mock Test-BitLockerChanging { $false }
        Mock Test-RestartPending { $false }
        Mock Test-VolumeDirty { $false }
        Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-TailFree { [int64]0 }
    }
    It 'lets a drive like the one in issue #6 through' {
        Get-OfflineShrinkProblem 'C:' ([int64]37GB) | Should -BeNullOrEmpty
    }
    It 'refuses <what>' -ForEach @(
        @{ what = 'legacy BIOS'; set = { Mock Test-Uefi { $false } }; says = 'legacy BIOS' }
        @{ what = 'a drive that isn''t NTFS'; set = { Mock Get-VolumeOf { [pscustomobject]@{ FileSystemType = 'ReFS'; Size = [int64]475GB; SizeRemaining = [int64]197GB } } }; says = 'isn''t NTFS' }
        @{ what = 'BitLocker'; set = { Mock Get-PartitionSignature { 'bitlocker' } }; says = 'encrypted' }
        @{ what = 'a drive still decrypting'; set = { Mock Test-BitLockerChanging { $true } }; says = 'encrypted' }
        @{ what = 'an update waiting for a restart'; set = { Mock Test-RestartPending { $true } }; says = 'waiting to restart' }
        @{ what = 'a drive Windows has marked to check'; set = { Mock Test-VolumeDirty { $true } }; says = 'marked drive C: to be checked' }
        @{ what = 'a laptop on battery'; set = { Mock Get-CimInstance { [pscustomobject]@{ BatteryStatus = 1 } } -ParameterFilter { $ClassName -eq 'Win32_Battery' } }; says = 'charger' }
        @{ what = 'more than its files leave room for'; set = { }; says = 'needs'; wanted = [int64]300GB }
    ) {
        & $set
        $wantedBytes = if ($wanted) { $wanted } else { [int64]37GB }
        Get-OfflineShrinkProblem 'C:' $wantedBytes | Should -BeLike "*$says*"
    }
    It 'keeps Windows its reserve and the download its room' {
        # 278 GB of files, 8 GB reserve, the margin, and a 6 GB download: 475 - 278 - 8 - 6 leaves under 183.
        Get-OfflineShrinkProblem 'C:' ([int64]185GB) ([int64]6GB) | Should -BeLike '*needs*'
        Get-OfflineShrinkProblem 'C:' ([int64]150GB) ([int64]6GB) | Should -BeNullOrEmpty
    }
}

Describe 'After the shrink tool has run' {
    BeforeAll {
        $ShrinkStatePath = Join-Path $TestDrive 'shrink.json'
        $AsidePath = Join-Path $TestDrive 'room-aside.json'
        $TriedPath = Join-Path $TestDrive 'room-tried.json'
    }
    BeforeEach {
        Remove-Item $ShrinkStatePath, $AsidePath, $TriedPath -ErrorAction SilentlyContinue
        Write-StateFile $ShrinkStatePath (@{ Id = 'abc'; Drive = 'C:'; DiskNumber = 0; Offset = [int64]1GB; Was = [int64]475GB; NewSize = [int64]438GB; WantedLinuxGB = 25; BootNumber = 67; CopyFolder = 'X' } | ConvertTo-Json)
        Write-StateFile $TriedPath (@{ DiskNumber = 0; Offset = [int64]1GB; Drive = 'C:' } | ConvertTo-Json)
        $script:size = [int64]438GB
        $script:result = "id abc`nok 510027366400 470298099712`n`nhop shrink, kernel 7.2"
        Mock Get-PartitionAt { [pscustomobject]@{ DiskNumber = 0; Offset = [int64]1GB; Size = $script:size } }
        Mock Read-ShrinkResult { $script:result }
        Mock Clear-OfflineShrink { }
        Mock Unregister-ResumeTask { }
        Mock Remove-RoomTask { }
        Mock Remove-RestartCopy { }
        Mock Read-RoomState { }
        Mock Test-ShrunkDrive { }
    }
    It 'sets the space aside for Linux, as Make room does, and tidies up' {
        Complete-OfflineShrink | Should -Be 'shrunk'
        $aside = Read-RoomAside
        $aside.SizeBefore | Should -Be ([int64]475GB)
        $aside.WantedLinuxGB | Should -Be 25
        Test-Path $ShrinkStatePath | Should -BeFalse
        Test-Path $TriedPath | Should -BeFalse
        Should -Invoke Clear-OfflineShrink -Times 1
        Should -Invoke Remove-RestartCopy -ParameterFilter { $Folder -eq 'X' } -Times 1
        Should -Invoke Test-ShrunkDrive -ParameterFilter { $Drive -eq 'C:' } -Times 1
    }
    It 'keeps the size from before an earlier Make room, for Undo' {
        Write-StateFile $AsidePath (@{ DiskNumber = 0; Offset = [int64]1GB; SizeBefore = [int64]480GB; Drive = 'C:'; WantedLinuxGB = 25 } | ConvertTo-Json)
        Complete-OfflineShrink | Should -Be 'shrunk'
        (Read-RoomAside).SizeBefore | Should -Be ([int64]480GB)
    }
    It 'goes by the drive''s real size, not only what the tool said' {
        $script:size = [int64]475GB
        Complete-OfflineShrink | Should -BeLike '*the size it was*'
        Test-Path $AsidePath | Should -BeFalse
    }
    It 'says why the tool refused' {
        $script:size = [int64]475GB
        $script:result = "id abc`nfailed: Windows is hibernated, not shut down"
        Complete-OfflineShrink | Should -Be "hop's shrink tool left drive C: as it was. Windows is hibernated, not shut down."
    }
    It 'doesn''t say nothing changed when it stopped part way' {
        $script:size = [int64]475GB
        $script:result = "id abc`npartial: shrinking stopped part way through. The partition is the size it was, and Windows checks the drive as it starts"
        $said = Complete-OfflineShrink
        $said | Should -BeLike "hop's shrink tool stopped part way through drive C:. Shrinking stopped*"
        $said | Should -Not -BeLike '*as it was*'
        Test-Path $AsidePath | Should -BeFalse
    }
    It 'says the PC started Windows instead when the tool wrote nothing' {
        $script:size = [int64]475GB
        $script:result = $null
        Complete-OfflineShrink | Should -BeLike '*started Windows without*'
        Should -Invoke Clear-OfflineShrink -Times 1
        Test-Path $ShrinkStatePath | Should -BeFalse
    }
    It 'doesn''t take an older attempt''s words for this one''s' {
        $script:size = [int64]475GB
        $script:result = "id other`nok 1 2"
        Complete-OfflineShrink | Should -BeLike "*didn't say it finished*"
    }
    It 'says so plainly when the drive is neither size' {
        $script:size = [int64]450GB
        Complete-OfflineShrink | Should -BeLike '*changed size, but not to what hop planned*'
        Test-Path $AsidePath | Should -BeFalse
    }
    It 'leaves Make room''s restore task while its settings are off' {
        Mock Read-RoomState { [pscustomobject]@{ Phase = 'ready' } }
        Complete-OfflineShrink | Out-Null
        Should -Invoke Remove-RoomTask -ParameterFilter { $Name -eq $RestoreTaskName } -Times 0
    }
}

Describe 'Whether the restart into the shrink tool has happened' {
    BeforeAll { $ShrinkStatePath = Join-Path $TestDrive 'shrink-phase.json' }
    It 'waits while Windows hasn''t restarted since, and is done once it has' {
        $boot = [datetime]'2026-11-09T05:00:00'
        Mock Get-LastBoot { $boot }
        Write-StateFile $ShrinkStatePath (@{ Id = 'a'; BootedBefore = $boot.ToString('o') } | ConvertTo-Json)
        Get-ShrinkPhase | Should -Be 'waiting'
        Mock Get-LastBoot { $boot.AddMinutes(9) }
        Get-ShrinkPhase | Should -Be 'done'
    }
    It 'is nothing without a record' {
        Remove-Item $ShrinkStatePath -ErrorAction SilentlyContinue
        Get-ShrinkPhase | Should -BeNullOrEmpty
    }
}

Describe 'A build without the shrink tool' {
    It 'offers nothing' {
        $ShrinkImage = [pscustomobject]@{ Url = ''; Sha256 = ''; Files = @{} }
        Mock Test-Uefi { $true }
        Test-ShrinkAvailable | Should -BeFalse
    }
}

Describe 'Make room remembering it fell short' {
    BeforeAll {
        $AsidePath = Join-Path $TestDrive 'aside-tried.json'
        $TriedPath = Join-Path $TestDrive 'tried.json'
    }
    BeforeEach {
        Remove-Item $AsidePath, $TriedPath -ErrorAction SilentlyContinue
        $script:size = [int64]475GB
        $script:tail = [int64]0
        $Sync.RoomUnfinished = $false
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = [int64]1GB; Size = $script:size } }
        Mock Get-TailFree { $script:tail }
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMin = [int64]470GB; SizeMax = $script:size } }
        Mock Get-ShrinkableBytes { [int64]0 }
        Mock Resize-Partition { }
        Mock Get-LetterOf { 'C' }
        Mock Get-PartitionAt { [pscustomobject]@{ DiskNumber = 0; Offset = [int64]1GB; Size = $script:size } }
    }
    It 'remembers the drive when Windows released too little' {
        Set-RoomAside ([pscustomobject]@{ Drive = 'C:'; WantedBytes = [int64]37GB; WantedLinuxGB = 25 }) | Should -BeFalse
        Get-RoomTriedLetter | Should -Be 'C'
    }
    It 'doesn''t when moving files was stopped part way' {
        $Sync.RoomUnfinished = $true
        Set-RoomAside ([pscustomobject]@{ Drive = 'C:'; WantedBytes = [int64]37GB; WantedLinuxGB = 25 }) | Should -BeFalse
        Get-RoomTriedLetter | Should -BeNullOrEmpty
    }
    It 'forgets it once there''s enough' {
        Set-RoomAside ([pscustomobject]@{ Drive = 'C:'; WantedBytes = [int64]37GB; WantedLinuxGB = 25 }) | Out-Null
        $script:tail = [int64]40GB
        Set-RoomAside ([pscustomobject]@{ Drive = 'C:'; WantedBytes = [int64]37GB; WantedLinuxGB = 25 }) | Should -BeTrue
        Get-RoomTriedLetter | Should -BeNullOrEmpty
    }
    It 'forgets a drive that has moved' {
        Set-RoomAside ([pscustomobject]@{ Drive = 'C:'; WantedBytes = [int64]37GB; WantedLinuxGB = 25 }) | Out-Null
        Mock Get-PartitionAt { }
        Get-RoomTriedLetter | Should -BeNullOrEmpty
        Test-Path $TriedPath | Should -BeFalse
    }
}

Describe 'Make room asking to restart' {
    It 'says only that it''s restarting' {
        Mock Register-RunAfterRestart { 'C:\ProgramData\hop\copy-1' }
        Mock Invoke-Shutdown { }
        Mock Set-Status { }
        $out = @(Request-RoomRestart)
        $out.Count | Should -Be 0
    }
}

Describe 'Windows checking a drive the tool shrank' {
    BeforeEach {
        Mock Set-Status { }
        Mock Repair-Volume { 'NoErrorsFound' } -ParameterFilter { $Scan }
        Mock Repair-Volume { 'Scheduled' } -ParameterFilter { $OfflineScanAndFix }
    }
    It 'says nothing when Windows finds nothing' {
        Test-ShrunkDrive 'C:'
        $Sync.ShrinkNote | Should -BeNullOrEmpty
        Should -Invoke Repair-Volume -ParameterFilter { $OfflineScanAndFix } -Times 0
    }
    It 'has Windows fix the drive as it next starts, and says so, when it finds something' {
        Mock Repair-Volume { 'NeedOfflineScanAndFix' } -ParameterFilter { $Scan }
        Test-ShrunkDrive 'C:'
        Should -Invoke Repair-Volume -ParameterFilter { $OfflineScanAndFix -and $DriveLetter -eq 'C' } -Times 1
        $Sync.ShrinkNote | Should -BeLike '*next time it starts*'
    }
    It 'says so too when Windows can''t scan it' {
        Mock Repair-Volume { throw 'busy' } -ParameterFilter { $Scan }
        Test-ShrunkDrive 'C:'
        $Sync.ShrinkNote | Should -BeLike '*next time it starts*'
    }
}

Describe 'A drive Windows wants to check first' {
    It 'counts only the free space after it, instead of failing' {
        Mock Resolve-Target { [pscustomobject]@{ Kind = 'volume'; IsWindows = $true; Partition = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = [int64]1GB; Size = [int64]90GB } } }
        Mock Get-SupportedSize { $ex = New-Object Exception 'Cannot shrink a partition containing a volume with errors.'; $ex.Data['ErrorId'] = 'StorageWMI 42008,Get-PartitionSupportedSize'; throw $ex }
        Mock Get-TailFree { [int64]37GB }
        Mock Get-LetterOf { 'C' }
        Mock Get-VolumeOf { [pscustomobject]@{ Size = [int64]90GB; SizeRemaining = [int64]71GB } }
        $space = Get-SpaceInfo ''
        $space.UsableGB | Should -Be 37
        $space.MinSize | Should -Be ([int64]90GB)
    }
    It 'still fails for anything else' {
        Mock Resolve-Target { [pscustomobject]@{ Kind = 'volume'; IsWindows = $true; Partition = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = [int64]1GB; Size = [int64]90GB } } }
        Mock Get-SupportedSize { throw 'Windows took too long' }
        { Get-SpaceInfo '' } | Should -Throw '*too long*'
    }
}
