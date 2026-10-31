# --- Make room ------------------------------------------------------------
# C: can only shrink down to the last file Windows can't move, however much is free. hop
# clears what usually sits there, restarts, moves what's left, and puts it all back once
# Linux has its space. What it changed is saved first, so a crash can't leave it that way.

$RoomPath = Join-Path $StateDir 'make-room.json'
$RunOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$PagingKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$MinMemoryWithoutPaging = 8GB
$DefragLimitSeconds = 900

# Windows logs the file that limits a shrink whenever it works out the limit, so ask and read it.
function Get-ShrinkBlocker {
    $c = Get-WindowsPartition
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

function Clear-ChangeJournal {
    & fsutil.exe usn deletejournal /d $env:SystemDrive 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log 'Could not clear the change journal.' }
}

function New-ChangeJournal {
    # Windows' own defaults.
    & fsutil.exe usn createjournal m=0x2000000 a=0x800000 $env:SystemDrive 2>&1 | Out-Null
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
# "?:" is Windows choosing the drive itself, which is usually C:.
function Get-PagingWithoutSystemDrive([string[]]$Files) {
    $drive = [regex]::Escape($env:SystemDrive)
    @($Files | Where-Object { $_ -and $_ -notmatch "^($drive|\?:)" })
}

function Set-PagingOff {
    Set-PagingSettings (Get-PagingWithoutSystemDrive (Get-PagingSettings))
}

function Restore-Paging($Saved) {
    Set-PagingSettings @($Saved)
}

function Test-EnoughMemoryWithoutPaging {
    (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory -ge $MinMemoryWithoutPaging
}

function Get-MakeRoomSteps {
    $steps = @('Turns off **hibernation** and clears the **change journal** on drive C:.')
    if (Test-EnoughMemoryWithoutPaging) { $steps += 'Turns off the **paging file** on drive C:.' }
    $steps += 'Restarts this PC, opens again, and moves what''s left out of the way.'
    $steps += 'Turns everything back on once Linux has its space, or when you close hop.'
    [pscustomobject]@{ Steps = $steps; Notes = @('Your files aren''t touched. Save your work first, because this PC restarts straight away.') }
}

function Start-MakeRoom {
    $state = [pscustomobject]@{
        Phase = 'restarting'; Saved = (Get-Date).ToString('s'); Hibernation = Test-HibernationOn
        Paging = @(Get-PagingSettings); PagingOff = Test-EnoughMemoryWithoutPaging
    }
    Save-RoomState $state
    try {
        Set-Status 'Turning off hibernation...'
        Set-Hibernation $false
        Clear-ChangeJournal
        if ($state.PagingOff) {
            Set-Status 'Turning off the paging file...'
            Set-PagingOff
        }
        Register-RunAfterRestart
        Set-Status 'Restarting...'
        Invoke-Shutdown '/r', '/t', '0'
    } catch {
        Write-Log "Failed: $($_.Exception.Message)"
        Restore-RoomSettings
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
    Invoke-Defrag
    $state = Read-RoomState
    if ($state) {
        $state.Phase = 'ready'
        Save-RoomState $state
    }
}

# It can run for a very long time. Whatever it moved before the limit still counts.
function Invoke-Defrag {
    Set-Status 'Moving files out of the way. This can take several minutes...'
    $process = Start-Process defrag.exe -ArgumentList "$env:SystemDrive /X" -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit($DefragLimitSeconds * 1000)) { Write-Log "Stopped moving files after $DefragLimitSeconds seconds." }
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
    }
    # Windows can't work out the limit for a moment after that.
    $c = Get-WindowsPartition
    for ($i = 0; $i -lt 6; $i++) {
        try { [void](Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -ErrorAction Stop); break } catch { Start-Sleep -Seconds 5 }
    }
}

function Clear-RestorePoints {
    Set-Status 'Deleting restore points on drive C:...'
    & vssadmin.exe delete shadows "/for=$env:SystemDrive" /all /quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Windows could not delete the restore points on drive C:.' }
    Invoke-Defrag
}

# Puts back whatever Make room changed. One failure must not stop the rest.
function Restore-RoomSettings {
    $state = Read-RoomState
    if (-not $state) { return }
    Unregister-RunAfterRestart
    if ($state.Hibernation) { try { Set-Hibernation $true } catch { Write-Log "Could not turn hibernation back on: $($_.Exception.Message)" } }
    if ($state.PagingOff) { try { Restore-Paging $state.Paging } catch { Write-Log "Could not turn the paging file back on: $($_.Exception.Message)" } }
    try { New-ChangeJournal } catch { Write-Log "Could not make a new change journal: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $RoomPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Turned hibernation and the paging file back on.'
}
