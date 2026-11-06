# --- Make room ------------------------------------------------------------
# A drive can only shrink down to the last file Windows can't move, however much is free. hop
# clears what usually sits there, restarts, moves what's left, and puts it all back once
# Linux has its space. What it changed is saved first, so a crash can't leave it that way.
#
# C: is the usual case. Another drive never has hibernation's file on it, and only has a paging
# file if someone moved it there, so most of the time it doesn't need a restart at all. Each
# function takes a drive letter, and without one means C:.

$RoomPath = Join-Path $StateDir 'make-room.json'
$AsidePath = Join-Path $StateDir 'room-aside.json'   # the space Make room set aside, until an install takes it or Windows has it back
$RunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'   # builds before the tasks used this
$ResumeTaskName = 'hop resume'
$RestoreTaskName = 'hop restore settings'
$RestoreArgument = '--restore-room'
$PagingKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
# Windows reports less than what's fitted, because the graphics and firmware keep some: an 8 GB PC can say under 6.
$MinMemoryWithoutPaging = 5.5GB
$DefragLimitSeconds = 900
$DefragTries = 4
$DefragRetrySeconds = 30
$DefragCancelled = 1223
$RoomWaitForSignInHours = 24
$RoomRestoreTries = 8   # the task tries every 15 minutes, and each time hop opens or closes

# Windows logs the file that limits a shrink whenever it works out the limit, so ask and read it.
function Get-ShrinkBlocker($Partition) {
    $c = if ($Partition) { $Partition } else { Get-WindowsPartition }
    $since = (Get-Date).AddSeconds(-5)
    try { [void](Get-SupportedSize $c) } catch { }
    for ($i = 0; $i -lt 3; $i++) {
        $found = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Defrag'; Id = 259; StartTime = $since } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($found) { return Get-BlockerFile $found.Message }
        Start-Sleep -Seconds 1
    }
}

# The message is translated, so this looks for the path rather than the words around it.
function Get-BlockerFile([string]$Message) {
    # An ordinary file comes with its default stream's name, \pagefile.sys::$DATA, which means nothing to anyone.
    if ($Message -match ':\s*(\\(?!\\)[^\r\n]+)') { $Matches[1].Trim() -replace '::\$DATA$', '' }
}

function Get-BlockerKind([string]$File) {
    switch -Regex ($File) {
        '^$' { return 'unknown' }
        'hiberfil' { return 'hibernation' }
        'pagefile|swapfile' { return 'paging' }
        'System Volume Information' { return 'restore' }
        'UsnJrnl' { return 'journal' }
        '^\\\$' { return 'ntfs' }
    }
    'file'
}

function Read-RoomState {
    if (-not (Test-Path -LiteralPath $RoomPath)) { return }
    try {
        $state = Get-Content -LiteralPath $RoomPath -Raw | ConvertFrom-Json
        if ($state.Phase) { return $state }
        Write-Log 'Could not read what Make room changed: the file makes no sense.'
    } catch { Write-Log "Could not read what Make room changed: $($_.Exception.Message)" }
}

# It says what the settings were, and nothing else does, so it isn't replaced or removed.
function Test-RoomFileDamaged { (Test-Path -LiteralPath $RoomPath) -and -not (Read-RoomState) }

function Save-RoomState($State) {
    Write-StateFile $RoomPath ($State | ConvertTo-Json -Depth 4)
}

# 'continue' after the restart, 'restore' if something stopped before finishing, or nothing.
# Only the log knew otherwise. Shown once, the next time hop checks before an install.
function Get-RoomGaveUpWarning {
    $file = "$RoomPath.gave-up"
    if (-not (Test-Path -LiteralPath $file)) { return }
    $what = (Get-Content -LiteralPath $file -Raw).Trim()
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    "**Make room couldn't turn $what back on.** Turn it on again in Windows' settings. Your files aren't affected."
}

# What a person needs to hear about Make room as hop opens, or nothing. A damaged record can't be acted on, so the task
# that would keep reopening hop for it goes now, and the record stays until they've read this.
function Get-RoomNotice {
    if (Test-RoomFileDamaged) {
        Unregister-ResumeTask
        return "hop can't read what Make room turned off. Check that hibernation and the paging file are how you want them in Windows' settings."
    }
    $file = "$RoomPath.gave-up"
    if (Test-Path -LiteralPath $file) {
        "Make room couldn't turn $((Get-Content -LiteralPath $file -Raw).Trim()) back on. Turn it on again in Windows' settings. Your files aren't affected."
    }
}

# Once it's been read.
function Clear-RoomNotice {
    if (Test-RoomFileDamaged) {
        Unregister-RunAfterRestart
        Remove-Item -LiteralPath $RoomPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath "$RoomPath.gave-up" -Force -ErrorAction SilentlyContinue
}

function Get-RoomPhase {
    $state = Read-RoomState
    if (-not $state) { return }
    if ($state.Phase -eq 'restarting' -and (Get-LastBoot) -gt [datetime]$state.Saved) { return 'continue' }
    'restore'
}

function Get-LastBoot { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }

# A new Windows only has the default, until something changes it.
function Test-HibernationOn {
    $power = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
    if ($null -ne $power.HibernateEnabled) { return $power.HibernateEnabled -eq 1 }
    $power.HibernateEnabledDefault -eq 1
}

function Set-Hibernation([bool]$On) {
    $ErrorActionPreference = 'Continue'   # under 'Stop', its stderr would replace the check below
    & powercfg.exe /h $(if ($On) { 'on' } else { 'off' }) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log "Could not turn hibernation $(if ($On) { 'on' } else { 'off' })." }
}

function Get-RoomDrive([string]$Letter) { if ($Letter) { "$($Letter.TrimEnd(':')):" } else { $env:SystemDrive } }

function Clear-ChangeJournal([string]$Drive) {
    & fsutil.exe usn deletejournal /d (Get-RoomDrive $Drive) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log 'Could not clear the change journal.' }
}

function New-ChangeJournal([string]$Drive) {
    # Windows' own defaults.
    & fsutil.exe usn createjournal m=0x2000000 a=0x800000 (Get-RoomDrive $Drive) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log 'Could not make a new change journal; Windows makes one itself when it needs it.' }
}

# The registry value Windows reads at startup, because it can be put back exactly. Going through
# Win32_PageFileSetting moved a paging file from D: to C: when it was tested on a real Windows.
function Get-PagingSettings {
    @((Get-ItemProperty $PagingKey -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles)
}

function Set-PagingSettings([string[]]$Files) {
    New-ItemProperty -Path $PagingKey -Name PagingFiles -PropertyType MultiString -Value ([string[]]@($Files | Where-Object { $_ })) -Force | Out-Null
}

# Paging files on other drives stay: they aren't in the way, and Windows may need one.
# "?:" is Windows choosing the drive itself, which is usually C:, so it only counts for C:.
function Get-PagingWithoutSystemDrive([string[]]$Files, [string]$Drive) {
    $room = Get-RoomDrive $Drive
    $drive_ = [regex]::Escape($room)
    $pattern = if ($room -eq $env:SystemDrive) { "^($drive_|\?:)" } else { "^$drive_" }
    @($Files | Where-Object { $_ -and $_ -notmatch $pattern })
}

function Set-PagingOff([string]$Drive) {
    Set-PagingSettings (Get-PagingWithoutSystemDrive (Get-PagingSettings) $Drive)
}

# Taking it off another drive needs a restart, so only when it's really there.
function Test-PagingFileOn([string]$Drive) {
    $room = [regex]::Escape((Get-RoomDrive $Drive))
    @(Get-PagingSettings | Where-Object { $_ -match "^$room" }).Count -gt 0
}

function Restore-Paging($Saved) {
    Set-PagingSettings @($Saved)
}

function Test-EnoughMemoryWithoutPaging {
    (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory -ge $MinMemoryWithoutPaging
}

# The task that opens hop waits for the account running it. Someone who gave an administrator's
# password is signed in as themselves, so it never fires for them.
function Test-OpensAgainByItself {
    $signedIn = Get-SignedInUser
    -not $signedIn -or $signedIn -eq [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-SignedInUser {
    try { (Get-CimInstance Win32_ComputerSystem).UserName } catch { $null }
}

function Get-MakeRoomSteps([string]$Drive) {
    $room = Get-RoomDrive $Drive
    $isWindows = $room -eq $env:SystemDrive
    $pagingOff = (Test-EnoughMemoryWithoutPaging) -and ($isWindows -or (Test-PagingFileOn $room))
    $restart = $isWindows -or $pagingOff
    $steps = @(if ($isWindows) { "On drive $room turns off **hibernation** and clears the **change journal**." } else { "On drive $room clears the **change journal**." })
    if ($pagingOff) { $steps += "On drive $room turns off the **paging file**." }
    $byItself = Test-OpensAgainByItself
    $steps += if ($restart -and -not $byItself) { 'Restarts this PC. Open hop again within 20 minutes, and it moves what''s left out of the way.' } elseif ($restart) { 'Restarts this PC, opens again, and moves what''s left out of the way.' } else { 'Moves files out of the way, which can take 15 minutes or more.' }
    $steps += "Sets the space aside for Linux by shrinking drive $room, so nothing can take it back, and turns everything back on once it has. Until you install, you can give it back."

    $note = if ($restart) { 'Save your work first. Your files aren''t touched.' } else { 'Your files aren''t touched, and this PC doesn''t restart.' }
    $notes = @($note)
    if (-not $pagingOff -and $isWindows) { $notes += 'This PC has too little memory to turn off the paging file safely. If that''s what is in the way, this won''t free much.' }
    [pscustomobject]@{ Steps = $steps; Restart = $restart; Notes = $notes }
}

# Says 'restarting' when the PC is on its way down, or 'done' when another drive didn't need it to be.
# $WantedBytes is what Linux and its installer need after the drive, and $KeepFreeBytes what has to stay
# free inside it, for a download going there. Without them, nothing is set aside.
function Start-MakeRoom([string]$Drive, [int]$WantedLinuxGB = 0, [int64]$WantedBytes = 0, [int64]$KeepFreeBytes = 0) {
    # An earlier run on another drive saved its settings in the same file. They go back first, so
    # none are lost and what's saved next is what's really there.
    if (Test-RoomFileDamaged) {
        throw "hop can't read what an earlier Make room turned off, and starting again would lose it. Check hibernation and the paging file are how you want them in Windows' settings, delete $RoomPath and try again."
    }
    if (Read-RoomState) {
        Restore-RoomSettings
        if (Test-Path -LiteralPath $RoomPath) { throw "hop couldn't turn back on what an earlier Make room turned off, and starting again would lose it. Restart this PC and try again." }
    }
    $room = Get-RoomDrive $Drive
    $isWindows = $room -eq $env:SystemDrive
    $pagingOff = (Test-EnoughMemoryWithoutPaging) -and ($isWindows -or (Test-PagingFileOn $room))
    $state = [pscustomobject]@{
        Phase = 'restarting'; Saved = (Get-Date).ToString('s'); Hibernation = $isWindows -and (Test-HibernationOn)
        Paging = @(Get-PagingSettings); PagingOff = $pagingOff; Drive = $room
        WantedLinuxGB = $WantedLinuxGB; WantedBytes = $WantedBytes; KeepFreeBytes = $KeepFreeBytes
    }
    Save-RoomState $state
    try {
        if ($isWindows) {
            Set-Status 'Turning off hibernation...'
            Set-Hibernation $false
        }
        Clear-ChangeJournal $room
        if ($isWindows -or $pagingOff) {
            if ($state.PagingOff) {
                Set-Status 'Turning off the paging file...'
                Set-PagingOff $room
            }
            Request-RoomRestart
            return 'restarting'
        }
        Invoke-Defrag $room
        $state.Phase = 'ready'
        Save-RoomState $state
        if (Set-RoomAside $state) { Restore-RoomSettings }
        'done'
    } catch {
        Write-Log "Failed: $($_.Exception.Message)"
        Restore-RoomSettings
        throw
    }
}

# Windows asks every window before it restarts. RoomRestarting tells hop's that this restart is its
# own, and to let it go. Something else can still stop the restart, so the window can ask again.
function Request-RoomRestart {
    $Sync.RoomRestarting = $true
    try {
        Register-RunAfterRestart
        Set-Status 'Restarting...'
        Invoke-Shutdown '/r', '/t', '0'
    } catch {
        $Sync.RoomRestarting = $false
        throw
    }
}

# Two tasks, because a prompt at sign-in with No already chosen is a bad way to finish, and someone may
# never come back to hop at all. One opens hop when this user signs in, elevated and without asking. The
# other puts the settings back by itself if hop hasn't, from a while after Windows starts: see Program.cs.
# Both run a copy no ordinary process can replace, with fixed arguments, or they'd be a way around UAC.
# If they can't be made this throws, because restarting without them could strand the settings.
function Register-RunAfterRestart {
    $exe = Get-RestartCopy
    $state = Read-RoomState
    $earlier = @($state.CopyFolder, [Hop.RestartCopy]::OwnFolder()) | Where-Object { $_ -and $_ -ne (Split-Path $exe -Parent) } | Select-Object -Unique
    if ($state) {
        $state | Add-Member -NotePropertyName CopyFolder -NotePropertyValue (Split-Path $exe -Parent) -Force
        Save-RoomState $state
    }
    Set-RoomTasks $exe
    foreach ($name in @($ResumeTaskName, $RestoreTaskName)) {
        if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { throw "Windows didn't keep the task called $name." }
    }
    Remove-ItemProperty -Path $RunOnceKey -Name 'hop' -ErrorAction SilentlyContinue
    # Nothing starts these any more: one from asking to restart before, and the one running, if it's a copy.
    foreach ($folder in @($earlier)) { Remove-RestartCopy $folder }
}

# Always a new one. The one hop may be running from can already be set to go as Windows next starts,
# which would leave the tasks pointing at nothing, just when they're needed.
function Get-RestartCopy {
    [Hop.RestartCopy]::Create($ProgramData)
}

function Set-RoomTasks([string]$Exe) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $ResumeTaskName -Force -Settings $settings `
        -Action (New-ScheduledTaskAction -Execute $Exe) `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
        -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) | Out-Null
    # While hop is open it leaves things alone, so it keeps trying until hop has gone.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT20M'
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)).Repetition
    Register-ScheduledTask -TaskName $RestoreTaskName -Force -Settings $settings `
        -Action (New-ScheduledTaskAction -Execute $Exe -Argument $RestoreArgument) `
        -Trigger $trigger `
        -Principal (New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest) | Out-Null
}

function Remove-RoomTask([string]$Name) {
    try { Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue } catch { Write-Log "Could not remove the task $Name`: $($_.Exception.Message)" }
}

# Once hop has opened again. The other task stays until the settings are back.
function Unregister-ResumeTask {
    Remove-RoomTask $ResumeTaskName
    Remove-ItemProperty -Path $RunOnceKey -Name 'hop' -ErrorAction SilentlyContinue
}

function Unregister-RunAfterRestart {
    Unregister-ResumeTask
    Remove-RoomTask $RestoreTaskName
    Remove-RestartCopy (Read-RoomState).CopyFolder
}

# Only the folder hop made and wrote down, and never through a link someone has put there. Program.cs
# deals with the one hop is running from, because a running file can't be deleted.
function Remove-RestartCopy([string]$Folder) {
    if (-not $Folder) { return }
    if ($Folder -eq [Hop.RestartCopy]::OwnFolder()) {
        try { [Hop.RestartCopy]::RemoveAtNextStart($Folder) } catch { Write-Log "Could not set $Folder to go at the next start: $($_.Exception.Message)" }
        return
    }
    if ((Split-Path $Folder -Parent) -ne $ProgramData -or -not (Split-Path $Folder -Leaf).StartsWith([Hop.RestartCopy]::FolderPrefix)) { return }
    if (-not (Test-Path -LiteralPath $Folder)) { return }
    try {
        if ((Get-Item -LiteralPath $Folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        [IO.Directory]::Delete($Folder, $true)
    } catch { Write-Log "Could not remove $Folder`: $($_.Exception.Message)" }
}

# What the second task runs, when hop isn't open. Afterwards there's nothing left for it to do.
function Restore-RoomFromTask {
    # Someone who walked away during the restart hasn't given up on it. Nothing can need these settings
    # at the sign-in screen, so they get a day to come back before hop's work is undone.
    $state = Read-RoomState
    if ($state.Phase -eq 'restarting' -and -not (Get-SignedInUser)) {
        $saved = [datetime]::MinValue
        if ([datetime]::TryParse([string]$state.Saved, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$saved) -and ((Get-Date) - $saved).TotalHours -lt $RoomWaitForSignInHours) { return }
    }
    Write-Log 'Putting back what Make room changed, because hop did not.'
    Restore-RoomSettings
    # The file still being there means they aren't all back, so this has to run again.
    if (Test-Path -LiteralPath $RoomPath) {
        Write-Log 'Make room''s settings are not all back. This task tries again later.'
        return
    }
    Remove-RoomTask $ResumeTaskName
    Remove-RoomTask $RestoreTaskName
}

# After the restart: the paging file has gone, so move what can be moved. Says 'done', or 'failed'
# when it couldn't, for example because that drive has been unplugged. That can't be allowed to stop
# hop opening every time from now on, so the settings go back and hop carries on without the room.
function Complete-MakeRoom {
    Unregister-ResumeTask
    $state = Read-RoomState
    try { Invoke-Defrag $state.Drive } catch {
        Write-Log "Could not move files on drive $(Get-RoomDrive $state.Drive): $($_.Exception.Message)"
        Restore-RoomSettings
        return 'failed'
    }
    if ($state) {
        $state.Phase = 'ready'
        Save-RoomState $state
        # With all Linux asked for set aside, nothing is left for the settings to be off for.
        if (Set-RoomAside $state) { Restore-RoomSettings }
    }
    'done'
}

function Read-RoomAside {
    if (-not (Test-Path -LiteralPath $AsidePath)) { return }
    try { Get-Content -LiteralPath $AsidePath -Raw | ConvertFrom-Json } catch { Write-Log "Could not read what Make room set aside: $($_.Exception.Message)" }
}

function Remove-RoomAside { Remove-Item -LiteralPath $AsidePath -Force -ErrorAction SilentlyContinue }

# Moving files only counts once the drive is smaller. Until then the paging file, hibernation or a new restore
# point can take the space again, as the paging file did on the PC in issue #6 once its settings were back.
# So the drive shrinks by what Linux asked for, or as far as it now can, and the space waits after it, where
# nothing in Windows can take it. Says whether all of it is there. Not managing it only leaves things as they
# were, with the settings still off for the install's own shrink.
function Set-RoomAside($State) {
    if (-not $State -or -not [int64]$State.WantedBytes) { return $false }
    try {
        $room = Get-RoomDrive $State.Drive
        $c = Get-Partition -DriveLetter $room.TrimEnd(':')
        $missing = [int64]$State.WantedBytes - (Get-TailFree $c)
        if ($missing -gt 0) {
            $reserve = [int64]$(if ($room -eq $env:SystemDrive) { $WindowsReserve } else { $DataReserve }) + [int64]$State.KeepFreeBytes
            $shrinkable = Get-ShrinkableBytes $c (Get-SupportedSize $c) $reserve
            $take = [int64]([math]::Floor([math]::Min($missing, $shrinkable) / 1MB) * 1MB)
            if ($take -ge 1GB) {
                # Written first, so a crash straight after the shrink still knows the space is this drive's.
                $earlier = Read-RoomAside
                $before = if ($earlier -and [int64]$earlier.Offset -eq [int64]$c.Offset -and [int]$earlier.DiskNumber -eq [int]$c.DiskNumber) { [int64]$earlier.SizeBefore } else { [int64]$c.Size }
                Write-StateFile $AsidePath (ConvertTo-Json -InputObject ([pscustomobject]@{
                    DiskNumber = [int]$c.DiskNumber; Offset = [int64]$c.Offset; SizeBefore = $before; Drive = $room
                    WantedLinuxGB = [int]$State.WantedLinuxGB; Saved = (Get-Date).ToString('s')
                }))
                Set-Status ('Setting aside {0:N0} GB for Linux...' -f ($take / 1GB))
                try { Resize-Partition -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -Size ([int64]$c.Size - $take) } catch {
                    if ($before -eq [int64]$c.Size) { Remove-RoomAside }
                    throw
                }
                Write-Log ('Set aside {0:N1} GB after drive {1}.' -f ($take / 1GB), $room)
            } else {
                Write-Log ('Windows can only release {0:N1} GB of drive {1}, so nothing more was set aside.' -f ([math]::Max(0, $shrinkable) / 1GB), $room)
            }
        }
        $after = Get-TailFree (Get-Partition -DriveLetter $room.TrimEnd(':'))
        $after -ge [int64]$State.WantedBytes
    } catch {
        Write-Log "Could not set the space aside: $($_.Exception.Message)"
        $false
    }
}

# How much is set aside now, in whole GB, and what for. A record whose space has since gone, for example to
# Windows through Disk Management, is forgotten.
function Get-RoomAside {
    $aside = Read-RoomAside
    if (-not $aside) { return }
    $c = Get-Partition -DiskNumber $aside.DiskNumber -ErrorAction SilentlyContinue | Where-Object { [int64]$_.Offset -eq [int64]$aside.Offset } | Select-Object -First 1
    $tail = if ($c) { Get-TailFree $c } else { 0 }
    if ($tail -lt 1GB -or [int64]$c.Size -ge [int64]$aside.SizeBefore) { Remove-RoomAside; return }
    [pscustomobject]@{ GB = [int][math]::Floor($tail / 1GB); WantedLinuxGB = [int]$aside.WantedLinuxGB; Letter = ($aside.Drive -replace ':', '') }
}

# It can run for a very long time. Whatever it moved before the limit still counts. Says the code it finished with.
function Start-DefragRun([string]$Room, [int]$Seconds = $DefragLimitSeconds) {
    $process = Start-Process defrag.exe -ArgumentList "$Room /X" -WindowStyle Hidden -PassThru
    $null = $process.Handle   # keeps ExitCode readable after the process exits
    try {
        if ($process.WaitForExit($Seconds * 1000)) { return $process.ExitCode }
        Write-Log "Stopped moving files after $Seconds seconds."
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
    }
}

function Invoke-Defrag([string]$Drive) {
    $room = Get-RoomDrive $Drive
    Set-Status 'This can take several minutes. Whatever hop moves still counts, even if it stops early.'
    # All the tries share one limit: closing hop is refused meanwhile, and the safety net can't run.
    $deadline = (Get-Date).AddSeconds($DefragLimitSeconds)
    $cancelled = 0
    $code = $null
    # Straight after signing in it can give up at once with 1223, having moved nothing, as seen on a real Windows.
    for ($try = 1; $try -le $DefragTries; $try++) {
        $left = [int][math]::Floor(($deadline - (Get-Date)).TotalSeconds)
        if ($left -le 0) { break }
        $code = Start-DefragRun $room $left
        Write-Log "Finished moving files (code $code)."
        if ($code -ne $DefragCancelled) { break }
        $cancelled++
        if ($try -lt $DefragTries) { Start-Sleep -Seconds ([math]::Min($DefragRetrySeconds, $left)) }
    }
    if ($cancelled -eq $DefragTries) { Write-Log "Windows cancelled moving files all $DefragTries times, so nothing moved." }
    # What's left may well move, so this mustn't read as the most that could be done.
    $Sync.RoomUnfinished = $code -ne 0
    # Windows can't work out the limit for a moment after that.
    $c = Get-Partition -DriveLetter $room.TrimEnd(':')
    Wait-ShrinkLimit $c $deadline
    # With a system file out of the way, the next thing in the way may be something defrag can move.
    # Defrag can use all of its time on a big drive, and these take moments. So they get time of their own,
    # and $Mft::$BITMAP isn't left in the way just because defrag ran out.
    if (Move-SystemFiles $room $c (Get-Date).AddMinutes(5)) {
        $left = [int][math]::Floor(($deadline - (Get-Date)).TotalSeconds)
        if ($left -gt 0) { Write-Log "Finished moving files (code $(Start-DefragRun $room $left))." }
        Wait-ShrinkLimit $c $deadline
    }
}

function Wait-ShrinkLimit($Partition, [datetime]$Deadline) {
    for ($i = 0; $i -lt 6; $i++) {
        try { [void](Get-SupportedSize $Partition); break } catch {
            if ((Get-Date) -ge $Deadline) { break }
            Start-Sleep -Seconds 5
        }
    }
}

# The system files Microsoft lists as movable, as Windows names them when one limits a shrink.
function Test-MovableSystemFile([string]$File) {
    $File -and (Get-BlockerKind $File) -eq 'ntfs' -and $File -match '^\\\$(mft|attrdef|secure|upcase|extend)(?![a-z])'
}

# An ordinary file in the way, such as a game's big data file, which defrag leaves where it is. Moving it is what defrag
# itself does with it, and it stays the same file, in the same folder. The paging, hibernation and restore point files
# have ways of their own.
function Test-MovableFile([string]$File) {
    (Test-MovableSystemFile $File) -or ($File -and (Get-BlockerKind $File) -eq 'file')
}

# defrag can leave one of these near the end of a drive, $Mft::$BITMAP most of all. Moves whichever
# Windows names, until it names something else. Says whether any moved. A failure here costs nothing:
# NTFS turns down a move it won't make, and hop carries on with the room it has.
function Move-SystemFiles([string]$Room, $Partition, [datetime]$Deadline = [datetime]::MaxValue) {
    $moved = @{}
    $volume = Get-VolumeOf $Partition
    # Only what's past where the drive could end up matters. A big file's other parts can stay.
    $above = if ($volume -and $volume.Size) { [math]::Min(1, ($volume.Size - $volume.SizeRemaining + $WindowsReserve) / $volume.Size) } else { 0 }
    for ($i = 0; $i -lt 6; $i++) {
        if ((Get-Date) -ge $Deadline) { break }
        $file = Get-ShrinkBlocker $Partition
        if (-not (Test-MovableFile $file) -or $moved[$file]) { break }
        # Not Split-Path, which reads $Mft::$BITMAP as a drive.
        Set-Status "Moving $($file.Substring($file.LastIndexOf('\') + 1)) out of the way..."
        $seconds = [int][math]::Max([double]1, [math]::Min([double]600, [double]($Deadline - (Get-Date)).TotalSeconds))
        try { $clusters = [Hop.NtfsMove]::MoveDown($Room, $file, $above, $seconds) } catch {
            Write-Log "Could not move $file`: $($_.Exception.Message)"
            break
        }
        Write-Log "Moved $clusters clusters of $file."
        if ($clusters -le 0) { break }
        $moved[$file] = $true
    }
    $moved.Count -gt 0
}

function Clear-RestorePoints([string]$Drive) {
    $room = Get-RoomDrive $Drive
    Set-Status "Deleting restore points on drive $room..."
    $ErrorActionPreference = 'Continue'   # under 'Stop', its stderr would replace the check below
    & vssadmin.exe delete shadows "/for=$room" /all /quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Windows could not delete the restore points on drive $room." }
    Invoke-Defrag $room
}

# Puts back whatever Make room changed. One failure must not stop the rest. The file and the safety
# net only go once it's all back, in that order, so being stopped part way loses nothing. What didn't
# go back is tried again by the task or the next time hop opens, a limited number of times, since
# something like a full disk mustn't keep this going for ever.
function Restore-RoomSettings {
    $Sync.RoomRestarting = $false
    $state = Read-RoomState
    if (-not $state) { return }
    $back = @()
    $failed = @()
    if ($state.Hibernation) {
        try { Set-Hibernation $true } catch { Write-Log "Could not turn hibernation back on: $($_.Exception.Message)" }
        if (Test-HibernationOn) { $back += 'hibernation' } else { $failed += 'hibernation' }
    }
    if ($state.PagingOff) {
        try { Restore-Paging $state.Paging; $back += 'the paging file' } catch {
            Write-Log "Could not turn the paging file back on: $($_.Exception.Message)"
            $failed += 'the paging file'
        }
    }
    try { New-ChangeJournal $state.Drive } catch { Write-Log "Could not make a new change journal: $($_.Exception.Message)" }
    if ($back.Count) { Write-Log "Turned $($back -join ' and ') back on." }
    if ($failed.Count) {
        $tries = [int]$state.RestoreTries + 1
        if ($tries -lt $RoomRestoreTries) {
            Write-Log "Could not turn $($failed -join ' and ') back on. hop will try again ($tries of $RoomRestoreTries)."
            # Not 'restarting', or the next time hop opens it would carry on with Make room. Only what's left gets tried again.
            $state.Phase = 'restore'
            $state.Hibernation = $failed -contains 'hibernation'
            $state.PagingOff = $failed -contains 'the paging file'
            $state | Add-Member -NotePropertyName RestoreTries -NotePropertyValue $tries -Force
            try { Save-RoomState $state } catch { Write-Log "Could not save that: $($_.Exception.Message)" }
            return
        }
        Write-Log "Gave up turning $($failed -join ' and ') back on after $tries tries. Turn it on in Windows' settings."
        try { Write-StateFile "$RoomPath.gave-up" ($failed -join ' and ') } catch { Write-Log "Could not save that: $($_.Exception.Message)" }
    }
    Unregister-RunAfterRestart
    Remove-Item -LiteralPath $RoomPath -Force -ErrorAction SilentlyContinue
}
