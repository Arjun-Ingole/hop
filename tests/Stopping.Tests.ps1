# Cancelling an install stops its PowerShell command. If that ever comes back looking like success, hop says
# the system is ready when nothing was installed, as happened on a real PC. These use hop's real engine.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Load-Engine.ps1') -WithHop
    function Stop-After($Target, [int]$Seconds) {
        $stopper = [powershell]::Create().AddScript({ param($t, $s) Start-Sleep $s; $t.Stop() }).AddArgument($Target).AddArgument($Seconds)
        [void]$stopper.BeginInvoke()
    }
}

Describe 'Stopping a command' {
    It 'records what PowerShell itself does' {
        $ps = [powershell]::Create()
        [void]$ps.AddScript('Start-Sleep 30')
        Stop-After $ps 2
        $what = try { $count = $ps.Invoke().Count; "returned $count, with state $($ps.InvocationStateInfo.State)" } catch { "threw $($_.Exception.GetBaseException().GetType().Name)" }
        Write-Host "PowerShell.Invoke when stopped: $what"
        $ps.InvocationStateInfo.State | Should -Be 'Stopped'
    }
    It 'is never mistaken for success by the engine' {
        $engine = New-Object Hop.Engine
        try {
            $invoke = [Hop.Engine].GetMethod('Invoke', [Reflection.BindingFlags]'NonPublic,Instance')
            Stop-After $engine 2
            { $invoke.Invoke($engine, @('Start-Sleep', @{ Seconds = 30 })) } | Should -Throw
        } finally { $engine.Dispose() }
    }
}
