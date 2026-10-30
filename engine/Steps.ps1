# What to click in the Linux installer. The app shows Steps as a numbered list
# and Notes underneath; text between ** is shown in a heavier weight.
function Get-Steps($Distro, [int]$LinuxGB) {
    if ($Distro.Strategy -eq 'prepared') {
        $steps = @(
            "Pick your language and keyboard, then choose **$($Distro.Mode)**."
            "Click the $($LinuxGB - 1) GB partition named **$RootLabel**. Use it as Root (/) and format it as ext4."
            "Click the 1 GB partition named **$BootLabel**. Use it as Boot (/boot/efi) and format it as FAT32."
            'Leave everything else alone and click **Install**.'
        )
    } else {
        $manual = "choose **$($Distro.Manual)**, select the $LinuxGB GB of free space, click **+** and create an ext4 partition mounted at **/**."
        $steps = @('Pick your language and keyboard, then start the installer.')
        if ($Distro.Alongside) {
            $steps += "Choose **$($Distro.Alongside)**. It uses the $LinuxGB GB hop set aside."
            $steps += "If that option is missing, $manual"
        } else {
            $steps += "When asked how to install, $manual"
        }
        if ($Distro.ManualExtra) { $steps += $Distro.ManualExtra }
        $steps += "Don't choose **Erase disk**. The installer is running from this drive."
    }
    [pscustomobject]@{
        Steps = $steps
        Notes = @('If the PC starts Windows again or shows a security error, turn off Secure Boot in the BIOS, then open hop and restart again.')
    }
}
