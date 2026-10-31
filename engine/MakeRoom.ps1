# --- Make room ------------------------------------------------------------
# A drive can only shrink down to the last file Windows can't move, however much is free. hop
# clears what usually sits there, restarts, moves what's left, and puts it all back once
# Linux has its space. What it changed is saved first, so a crash can't leave it that way.
#
# C: is the usual case. Another drive never has hibernation's file on it, and only has a paging
# file if someone moved it there, so most of the time it doesn't need a restart at all. Each
# function takes a drive letter, and without one means C:.

$RoomPath = Join-Path $StateDir 'make-room.json'
$RunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$PagingKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$MinMemoryWithoutPaging = 8GB
$DefragLimitSeconds = 900

# Windows logs the file that limits a shrink whenever it works out the limit, so ask and read it.
function Get-ShrinkBlocker($Partition) {
    $c = if ($Partition) { $Partition } else { Get-WindowsPartition }
    $since = (Get-Date).AddSeconds(-5)
    try { [void](Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber) } catch { }
    for ($i = 0; $i -lt 3; $i++) {
        $found = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Defrag'; Id = 259; StartTime = $since } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($found) { return Get-BlockerFile $found.Message }
        Start-Sleep -Seconds 1
    }
}

# The message is translated, so this looks for the path rather than the words around it.
function Get-BlockerFile([string]$Message) {
    if ($Message -match ':\s*(\\(?!\\)[^\r\n]+)') { $Matches[1].Trim() }
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
    if (Test-Path -LiteralPath $RoomPath) {
        try { Get-Content -LiteralPath $RoomPath -Raw | ConvertFrom-Json } catch { Write-Log "Could not read what Make room changed: $($_.Exception.Message)" }
    }
}

function Save-RoomState($State) {
    $folder = Split-Path $RoomPath -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $RoomPath -Encoding UTF8
}

# 'continue' after the restart, 'restore' if something stopped before finishing, or nothing.
function Get-RoomPhase {
    $state = Read-RoomState
    if (-not $state) { return }
    if ($state.Phase -eq 'restarting' -and (Get-LastBoot) -gt [datetime]$state.Saved) { return 'continue' }
    'restore'
}

function Get-LastBoot { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }

function Test-HibernationOn {
    (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled -eq 1
}

function Set-Hibernation([bool]$On) {
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

function Get-MakeRoomSteps([string]$Drive) {
    $room = Get-RoomDrive $Drive
    if ($room -eq $env:SystemDrive) {
        $steps = @("Turns off **hibernation** and clears the **change journal** on drive $room.")
        if (Test-EnoughMemoryWithoutPaging) { $steps += "Turns off the **paging file** on drive $room." }
        $steps += 'Restarts this PC, opens again, and moves what''s left out of the way.'
        $steps += 'Turns everything back on once Linux has its space, or when you close hop.'
        return [pscustomobject]@{ Steps = $steps; Restart = $true; Notes = @('Your files aren''t touched. Save your work first, because this PC restarts straight away.') }
    }
    $steps = @("Clears the **change journal** on drive $room.")
    $restart = (Test-PagingFileOn $room) -and (Test-EnoughMemoryWithoutPaging)
    if ($restart) {
        $steps += "Turns off the **paging file** on drive $room."
        $steps += 'Restarts this PC, opens again, and moves what''s left out of the way.'
    } else {
        $steps += 'Moves files out of the way, for up to 15 minutes.'
    }
    $steps += 'Turns everything back on once Linux has its space, or when you close hop.'
    $note = if ($restart) { 'Your files aren''t touched. Save your work first, because this PC restarts straight away.' } else { 'Your files aren''t touched, and this PC doesn''t restart.' }
    [pscustomobject]@{ Steps = $steps; Restart = $restart; Notes = @($note) }
}

# Says 'restarting' when the PC is on its way down, or 'done' when another drive didn't need it to be.
function Start-MakeRoom([string]$Drive) {
    $room = Get-RoomDrive $Drive
    $isWindows = $room -eq $env:SystemDrive
    $pagingOff = (Test-EnoughMemoryWithoutPaging) -and ($isWindows -or (Test-PagingFileOn $room))
    $state = [pscustomobject]@{
        Phase = 'restarting'; Saved = (Get-Date).ToString('s'); Hibernation = $isWindows -and (Test-HibernationOn)
        Paging = @(Get-PagingSettings); PagingOff = $pagingOff; Drive = $room
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

function Register-RunAfterRestart {
    try {
        # Not every PC has this key until something needs it.
        if (-not (Test-Path $RunOnceKey)) { New-Item -Path $RunOnceKey -Force | Out-Null }
        Set-ItemProperty -Path $RunOnceKey -Name 'hop' -Value "`"$([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)`""
    } catch { Write-Log "Could not set hop to open after the restart: $($_.Exception.Message)" }
}

function Unregister-RunAfterRestart {
    Remove-ItemProperty -Path $RunOnceKey -Name 'hop' -ErrorAction SilentlyContinue
}

# After the restart: the paging file has gone, so move what can be moved.
function Complete-MakeRoom {
    Unregister-RunAfterRestart
    $state = Read-RoomState
    Invoke-Defrag $state.Drive
    if ($state) {
        $state.Phase = 'ready'
        Save-RoomState $state
    }
}

# It can run for a very long time. Whatever it moved before the limit still counts.
function Invoke-Defrag([string]$Drive) {
    $room = Get-RoomDrive $Drive
    Set-Status 'Moving files out of the way. This can take several minutes...'
    $process = Start-Process defrag.exe -ArgumentList "$room /X" -WindowStyle Hidden -PassThru
    $null = $process.Handle   # keeps ExitCode readable after the process exits
    try {
        if ($process.WaitForExit($DefragLimitSeconds * 1000)) { Write-Log "Finished moving files (code $($process.ExitCode))." }
        else { Write-Log "Stopped moving files after $DefragLimitSeconds seconds." }
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
    }
    # Windows can't work out the limit for a moment after that.
    $c = Get-Partition -DriveLetter $room.TrimEnd(':')
    for ($i = 0; $i -lt 6; $i++) {
        try { [void](Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -ErrorAction Stop); break } catch { Start-Sleep -Seconds 5 }
    }
}

function Clear-RestorePoints([string]$Drive) {
    $room = Get-RoomDrive $Drive
    Set-Status "Deleting restore points on drive $room..."
    & vssadmin.exe delete shadows "/for=$room" /all /quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Windows could not delete the restore points on drive $room." }
    Invoke-Defrag $room
}

# Puts back whatever Make room changed. One failure must not stop the rest.
function Restore-RoomSettings {
    $Sync.RoomRestarting = $false
    $state = Read-RoomState
    if (-not $state) { return }
    Unregister-RunAfterRestart
    if ($state.Hibernation) { try { Set-Hibernation $true } catch { Write-Log "Could not turn hibernation back on: $($_.Exception.Message)" } }
    if ($state.PagingOff) { try { Restore-Paging $state.Paging } catch { Write-Log "Could not turn the paging file back on: $($_.Exception.Message)" } }
    try { New-ChangeJournal $state.Drive } catch { Write-Log "Could not make a new change journal: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $RoomPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Turned hibernation and the paging file back on.'
}
