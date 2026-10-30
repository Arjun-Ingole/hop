# What makes hop refuse to run on this PC, each with the reason in plain words.
function Get-Blockers {
    if (-not (Test-Uefi)) {
        'This PC starts in the old "Legacy BIOS" mode. hop only works on UEFI PCs.'
        return
    }
    if ((Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture -eq 12) {
        'This PC has an ARM processor. The systems hop installs are built for Intel and AMD processors.'
        return
    }
    $c = Get-WindowsPartition
    $disk = Get-Disk -Number $c.DiskNumber
    if ($disk.PartitionStyle -ne 'GPT') { 'The Windows disk uses the old MBR layout. hop only works on GPT disks.' }
    if ($disk.BusType -in @('File Backed Virtual', 'Spaces')) { 'Windows is running from a virtual disk or Storage Spaces, which hop cannot resize.' }
    $volume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')
    if ($volume.FileSystemType -ne 'NTFS') { "Drive C: uses $($volume.FileSystemType). Windows can only shrink NTFS drives." }
    if ($volume.HealthStatus -in @('Warning', 'Unhealthy')) { 'Windows reports a problem with drive C:. Run chkdsk C: /f in an administrator terminal, restart, and open hop again.' }
}

function Test-Uefi { [Hop.Firmware]::IsUefi() }

function Test-System {
    $blockers = @(Get-Blockers)
    if ($blockers.Count) { throw $blockers[0] }
}

# Things hop can go ahead with, but that are worth checking first. ** marks emphasis.
function Get-Warnings {
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($battery -and $battery.BatteryStatus -eq 1) {
        "**Plug in the charger.** This PC is on battery ($($battery.EstimatedChargeRemaining)%), and losing power while the disk is changing could stop Windows starting."
    }
    if ((Get-Disk -Number (Get-WindowsPartition).DiskNumber).BusType -eq 'RAID') {
        '**The drive is in RAID or Intel RST mode.** Most Linux installers can''t see a drive set up this way. Windows also needs care to switch to AHCI in the BIOS, so look up the steps for this PC before continuing.'
    }
    if (Test-RestartPending) {
        '**Windows is waiting to restart for an update.** Restart and let it finish first. Otherwise it could be interrupted when the PC starts the installer.'
    }
    if (Test-BitLockerOn) {
        '**Drive C: is encrypted with BitLocker.** hop pauses it for three restarts. Make sure you have the recovery key first, at account.microsoft.com/devices/recoverykey.'
    }
    $memory = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($memory -and $memory -lt 4GB) {
        '**This PC has under 4 GB of memory.** The Linux installer may run slowly or fail. Lubuntu and Xubuntu need the least.'
    }
}

function Test-RestartPending {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Test-BitLockerOn {
    $volume = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
        -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction SilentlyContinue
    [bool]($volume -and $volume.ProtectionStatus -eq 1)
}

function Test-SecureBoot {
    try { [bool](Confirm-SecureBootUEFI) } catch { $false }
}

# The key that opens the one-time boot menu, by maker.
function Get-BootMenuKey {
    $maker = try { (Get-CimInstance Win32_ComputerSystem).Manufacturer } catch { '' }
    switch -Regex ($maker) {
        'Micro-Star|MSI' { return 'F11' }
        'ASUS' { return 'F8' }
        'Hewlett|HP' { return 'F9' }
        'Acer|Dell|Lenovo|Gigabyte|Toshiba|Razer|Dynabook' { return 'F12' }
    }
    'F12, F11, F9 or Esc'
}

function Suspend-BitLockerForSetup {
    if (Test-BitLockerOn) {
        # Changing boot entries can make BitLocker ask for the recovery key; pause it for a few restarts.
        Write-Log 'BitLocker is on; pausing it for the next 3 restarts.'
        & manage-bde.exe -protectors -disable $env:SystemDrive -RebootCount 3 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not pause BitLocker. Turn off "Device encryption" in Settings and try again.' }
        return $true
    }
    $false
}

function Resume-BitLockerAfterUndo {
    & manage-bde.exe -protectors -enable $env:SystemDrive | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Log 'Turned BitLocker back on.' } else { Write-Log 'Could not turn BitLocker back on; Windows does so itself after a few restarts.' }
}

$PowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'

function Get-FastStartup {
    (Get-ItemProperty -Path $PowerKey -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
}

function Disable-FastStartup {
    # Fast Startup leaves Windows half-asleep, which confuses Linux installers.
    Set-ItemProperty -Path $PowerKey -Name HiberbootEnabled -Value 0 -Type DWord
    Write-Log 'Turned off Windows Fast Startup.'
}

function Restore-FastStartup {
    Set-ItemProperty -Path $PowerKey -Name HiberbootEnabled -Value 1 -Type DWord
    Write-Log 'Turned Windows Fast Startup back on.'
}
