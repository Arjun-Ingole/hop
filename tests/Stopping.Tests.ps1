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
    # On a task, because PowerShell takes that exception as a stop of whatever script it reaches, this one included.
    It 'is never mistaken for success by the engine' {
        $engine = New-Object Hop.Engine
        try {
            $invoke = [Hop.Engine].GetMethod('InvokeAsync', [Reflection.BindingFlags]'NonPublic,Instance')
            $task = $invoke.Invoke($engine, [object[]]@('Start-Sleep', @{ Seconds = 30 }))
            Start-Sleep 3
            $engine.Stop()
            for ($i = 0; $i -lt 100 -and -not $task.IsCompleted; $i++) { Start-Sleep -Milliseconds 100 }
            $task.IsCompleted | Should -BeTrue
            $task.IsFaulted | Should -BeTrue
            $task.Exception.GetBaseException().GetType().Name | Should -Be 'PipelineStoppedException'
        } finally { $engine.Dispose() }
    }
    It 'leaves a command that finishes alone' {
        $engine = New-Object Hop.Engine
        try {
            $invoke = [Hop.Engine].GetMethod('InvokeAsync', [Reflection.BindingFlags]'NonPublic,Instance')
            $task = $invoke.Invoke($engine, [object[]]@('Start-Sleep', @{ Milliseconds = 10 }))
            for ($i = 0; $i -lt 100 -and -not $task.IsCompleted; $i++) { Start-Sleep -Milliseconds 100 }
            $task.IsFaulted | Should -BeFalse
        } finally { $engine.Dispose() }
    }
}
