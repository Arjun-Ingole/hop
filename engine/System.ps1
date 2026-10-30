function Test-System {
    if ($env:firmware_type -ne 'UEFI') {
        throw 'This PC starts in the old "Legacy BIOS" mode. hop only works on UEFI PCs.'
    }
    $c = Get-WindowsPartition
    if ((Get-Disk -Number $c.DiskNumber).PartitionStyle -ne 'GPT') {
        throw 'The Windows disk uses the old MBR layout. hop only works on GPT disks.'
    }
}

function Suspend-BitLockerForSetup {
    $volume = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
        -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction SilentlyContinue
    if ($volume -and $volume.ProtectionStatus -eq 1) {
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
