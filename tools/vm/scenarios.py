"""What gets run on the VM, by name: hopvm.py run screens stuck ...

Each scenario saves a screen at every step. What it prints goes to the job's log. Neither the job nor
a scenario finishing says hop worked: look at the screens and read the log."""
import json
import os
import time

import hopvm
from hopvm import log, OUT, FILES

HOP = r'C:\Users\hop\Downloads\hop.exe'

# Where hop's window puts things, at 96 DPI, from src/MainForm.cs and src/Sentence.cs.
LINE_ONE_Y, LINE_TWO_Y = 96 + 23, 96 + 46 + 23

UI_SCRIPT = r'''
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W { [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rr,B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); }
"@
$process = Get-Process hop -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $process) { '{"found":false}'; return }
$root = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
$r = New-Object W+R
[void][W]::GetWindowRect($process.MainWindowHandle, [ref]$r)
$controls = foreach ($e in $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
    $c = $e.Current
    if ($c.IsOffscreen -or $c.BoundingRectangle.IsEmpty) { continue }
    @{ name = $c.Name; type = $c.ControlType.ProgrammaticName; enabled = $c.IsEnabled; x = [int]$c.BoundingRectangle.X; y = [int]$c.BoundingRectangle.Y; w = [int]$c.BoundingRectangle.Width; h = [int]$c.BoundingRectangle.Height }
}
@{ found = $true; left = $r.L; top = $r.T; right = $r.Rr; bottom = $r.B; title = $process.MainWindowTitle; controls = @($controls) } | ConvertTo-Json -Depth 4 -Compress
'''

# What Make room is meant to change and put back.
FACTS_SCRIPT = r'''
"--- $(Get-Date -Format s), started $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('s'))"
$c = Get-Partition -DriveLetter C
$v = Get-Volume -DriveLetter C
"C: size {0:N1} GB, free {1:N1} GB" -f ($c.Size/1GB), ($v.SizeRemaining/1GB)
$s = Get-PartitionSupportedSize -DriveLetter C
"can shrink to {0:N1} GB, so {1:N1} GB can be released" -f ($s.SizeMin/1GB), (($c.Size-$s.SizeMin)/1GB)
"hibernation: HibernateEnabled=" + (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Power).HibernateEnabled
"hiberfil.sys: " + $(if (Test-Path C:\hiberfil.sys -PathType Leaf) { '{0:N2} GB' -f ((Get-Item C:\hiberfil.sys -Force).Length/1GB) } else { 'none' })
"PagingFiles: " + ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management').PagingFiles -join ' | ')
"pagefile.sys: " + $(if (Test-Path C:\pagefile.sys) { '{0:N2} GB' -f ((Get-Item C:\pagefile.sys -Force).Length/1GB) } else { 'none' })
"journal: " + ((fsutil usn queryjournal C: 2>&1 | Select-String 'Usn Journal ID|Maximum Size|Allocation Delta|Error') -join ' ; ')
"RunOnce: " + ((Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce -ErrorAction SilentlyContinue).hop)
"make-room.json: " + $(if (Test-Path C:\ProgramData\hop\make-room.json) { Get-Content C:\ProgramData\hop\make-room.json -Raw } else { 'none' })
"state.json: " + $(if (Test-Path C:\ProgramData\hop\state.json) { 'there' } else { 'none' })
Get-Partition -DiskNumber $c.DiskNumber | Sort-Object Offset | ForEach-Object { "  part {0} {1,-12} offset {2:N2} GB size {3:N2} GB letter [{4}] {5}" -f $_.PartitionNumber, $_.Type, ($_.Offset/1GB), ($_.Size/1GB), $_.DriveLetter, $_.GptType }
"windows of hop: " + ((Get-Process hop -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id) '$($_.MainWindowTitle)'" }) -join ', ')
Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='Microsoft-Windows-Defrag'; Id=259 } -MaxEvents 1 -ErrorAction SilentlyContinue | ForEach-Object { "last shrink blocker event, $($_.TimeCreated.ToString('s')): " + ($_.Message -replace '\s+',' ') }
'''

LOGS_SCRIPT = r'''
Get-ChildItem C:\ProgramData\hop -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
Get-ChildItem C:\ProgramData\hop\logs -File -ErrorAction SilentlyContinue | ForEach-Object { "=== $($_.Name)"; Get-Content $_.FullName -Tail 150 }
'''


class Session:
    """A running VM, and the things a person at it would do."""

    def __init__(self, vm):
        self.vm = vm

    def facts(self, why=''):
        print(f'===== {why}\n' + self.vm.ps(FACTS_SCRIPT, timeout=400), flush=True)

    def hop_log(self):
        print(self.vm.ps(LOGS_SCRIPT, timeout=60), flush=True)

    def ui(self):
        try:
            return json.loads(self.vm.ps(UI_SCRIPT, timeout=60).strip() or '{"found":false}')
        except ValueError as ex:
            log(f'ui: {ex}')
            return {'found': False}

    def controls(self):
        ui = self.ui()
        return [c for c in ui.get('controls', []) if c.get('name')] if ui.get('found') else []

    def wait_button(self, name, limit=300):
        end = time.time() + limit
        while time.time() < end:
            for c in self.controls():
                if c['name'] == name:
                    return c
            time.sleep(3)
        self.vm.shot(f'no-{name.replace(" ", "-")}')
        raise TimeoutError(f'no {name} button after {limit} seconds. There are: {[c["name"] for c in self.controls()]}')

    def press(self, name, limit=300):
        c = self.wait_button(name, limit)
        self.vm.click(c['x'] + c['w'] // 2, c['y'] + c['h'] // 2)

    def click_hop(self, x, y):
        """A place in hop's window, in the numbers src/MainForm.cs uses."""
        ui = self.ui()
        self.vm.click(ui['left'] + x, ui['top'] + y)

    def get_hop(self):
        self.vm.ps(f'New-Item -ItemType Directory -Force C:\\Users\\hop\\Downloads | Out-Null; (New-Object Net.WebClient).DownloadFile("http://10.0.2.2:{hopvm.PORT}/file/hop.exe", "{HOP}"); Get-Item {HOP} | Select-Object Length, LastWriteTime | Format-List')

    def open_hop_as_a_person(self):
        """Through the shell, not elevated, so Windows asks. The answer is typed on the prompt."""
        self.vm.ps(f'Start-Process explorer.exe "{HOP}"', timeout=30)
        time.sleep(8)
        self.vm.shot('elevation-prompt')
        self.vm.key('alt', 'y')
        self.wait_window()

    def wait_window(self, limit=180):
        end = time.time() + limit
        while time.time() < end:
            if self.ui().get('found'):
                return True
            time.sleep(3)
        self.vm.shot('no-hop-window')
        raise TimeoutError('no hop window')

    def settle(self, limit=240):
        """Until hop stops saying Checking: its first screen has at least one button."""
        end = time.time() + limit
        while time.time() < end:
            if any('Button' in c['type'] or c['name'] in ('Install', 'Make room', 'Close') for c in self.controls()):
                return
            time.sleep(3)

    def desktop(self):
        self.vm.wait_agent('user', limit=900)
        self.vm.shot('desktop')


def start(args):
    vm = hopvm.Vm(secure_boot=not args.no_secure_boot)
    live = hopvm.attach_live(vm)
    disk, vars_fd, tpm = hopvm.new_run_disks()
    vm.start(disk, vars_fd, tpm)
    return vm, Session(vm), live


def main(args):
    vm, s, live = start(args)
    failed = False
    try:
        for name in args.scenarios:
            if name == 'live':
                break
            log(f'===== scenario {name}')
            try:
                globals()[f'scenario_{name}'](vm, s)
            except Exception as ex:
                failed = True
                log(f'scenario {name} stopped: {ex!r}')
                vm.shot(f'{name}-stopped')
        if 'live' in args.scenarios and live:
            live.serve({'vm': vm, 's': s, 'time': time, 'hopvm': hopvm, 'FACTS_SCRIPT': FACTS_SCRIPT, 'scenarios': globals()})
    finally:
        if vm.running():
            try:
                vm.shot('end')
            except Exception:
                pass
        vm.stop()
    raise SystemExit(1 if failed else 0)


def scenario_hello(vm, s):
    s.desktop()
    s.facts('first look')
    print(vm.ps('Get-Disk | Format-Table Number, FriendlyName, BusType, PartitionStyle, Size -Auto; powercfg /a; Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory; Confirm-SecureBootUEFI; (Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System).EnableLUA; Get-Tpm | Select-Object TpmPresent; bcdedit /enum firmware'), flush=True)
