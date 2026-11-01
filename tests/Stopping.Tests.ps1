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
    # In a process of its own: what's being tested stops PowerShell commands, and this mustn't stop the tests.
    It 'is never mistaken for success by the engine' {
        $exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Release\hop.exe'
        $script = Join-Path $TestDrive 'stop.ps1'
        Set-Content $script @"
[void][Reflection.Assembly]::LoadFrom('$exe')
`$engine = New-Object Hop.Engine
`$stopper = [powershell]::Create().AddScript({ param(`$e) Start-Sleep 3; `$e.Stop() }).AddArgument(`$engine)
[void]`$stopper.BeginInvoke()
`$invoke = [Hop.Engine].GetMethod('Invoke', [Reflection.BindingFlags]'NonPublic,Instance')
try {
    `$invoke.Invoke(`$engine, [object[]]@('Start-Sleep', @{ Seconds = 30 })) | Out-Null
    'came back as if it worked'
} catch { 'threw ' + `$_.Exception.GetBaseException().GetType().Name }
"@
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script 2>&1 | Out-String
        Write-Host "The engine when stopped: $output"
        $output | Should -BeLike '*threw PipelineStoppedException*'
    }
}
