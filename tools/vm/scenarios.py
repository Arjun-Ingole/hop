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
# Rows in the drive picker, which opens 8 under the sentence's second line, with 6 of padding.
DRIVE_ROW_Y, DRIVE_ROW_H = 96 + 46 + 49 + 8 + 6 + 21, 42

UI_SCRIPT = r'''
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W { [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rr,B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r); }
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
"hiberfil.sys: " + $(if (Test-Path C:\hiberfil.sys) { '{0:N2} GB' -f ((Get-Item C:\hiberfil.sys -Force).Length/1GB) } else { 'none' })
"PagingFiles: " + ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management').PagingFiles -join ' | ')
"pagefile.sys: " + $(if (Test-Path C:\pagefile.sys) { '{0:N2} GB' -f ((Get-Item C:\pagefile.sys -Force).Length/1GB) } else { 'none' })
"journal: " + ((fsutil usn queryjournal C: 2>&1 | Select-String 'Usn Journal ID|Maximum Size|Allocation Delta|Error') -join ' ; ')
"RunOnce: " + ((Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce -ErrorAction SilentlyContinue).hop)
"make-room.json: " + $(if (Test-Path C:\ProgramData\hop\make-room.json) { Get-Content C:\ProgramData\hop\make-room.json -Raw } else { 'none' })
"state.json: " + $(if (Test-Path C:\ProgramData\hop\state.json) { 'there' } else { 'none' })
Get-Partition -DiskNumber $c.DiskNumber | Sort-Object Offset | ForEach-Object { "  part {0} {1,-12} offset {2:N2} GB size {3:N2} GB letter [{4}]" -f $_.PartitionNumber, $_.Type, ($_.Offset/1GB), ($_.Size/1GB), $_.DriveLetter }
"hop running: " + ((Get-Process hop -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id) '$($_.MainWindowTitle)'" }) -join ', ')
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

    def names(self):
        return [c['name'] for c in self.controls()]

    def wait_button(self, name, limit=300):
        end = time.time() + limit
        while time.time() < end:
            for c in self.controls():
                if c['name'] == name:
                    return c
            time.sleep(3)
        self.vm.shot(f'no-{name.replace(" ", "-")}')
        raise TimeoutError(f'no {name} button after {limit} seconds. There are: {self.names()}')

    def press(self, name, limit=300):
        c = self.wait_button(name, limit)
        self.vm.click(c['x'] + c['w'] // 2, c['y'] + c['h'] // 2)

    def click_hop(self, x, y):
        """A place in hop's window, in the numbers src/MainForm.cs uses."""
        ui = self.ui()
        self.vm.click(ui['left'] + x, ui['top'] + y)

    def get_hop(self):
        print(self.vm.ps(f'New-Item -ItemType Directory -Force C:\\Users\\hop\\Downloads | Out-Null; (New-Object Net.WebClient).DownloadFile("http://10.0.2.2:{hopvm.PORT}/file/hop.exe", "{HOP}"); Get-Item {HOP} | Select-Object Length, LastWriteTime | Format-List'), flush=True)

    def open_as_a_person(self, name='elevation-prompt'):
        """Through the shell, not elevated, so Windows asks, and the answer goes in on the keyboard."""
        self.vm.ps(f'Start-Process explorer.exe "{HOP}"', timeout=30)
        time.sleep(8)
        self.vm.shot(name)
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

    def settle(self, limit=300):
        """Until hop has stopped saying Checking, and shows a button."""
        end = time.time() + limit
        while time.time() < end:
            if any(n in ('Install', 'Make room', 'Close', 'Clean up', 'Restart now', 'Try again', 'Remove the installer') or n.startswith('Use ') for n in self.names()):
                return
            time.sleep(3)
        raise TimeoutError('hop is still working out what to show')

    def desktop(self):
        self.vm.wait_agent('user', limit=900)
        self.vm.shot('desktop')


class Bench:
    """Starts VMs from the image, one at a time."""

    def __init__(self, secure_boot=True):
        self.secure_boot = secure_boot
        self.vm = None
        self.live = None

    def fresh(self, second_disk=False, secure_boot=None):
        """Back to Windows as it was installed, with a new VM."""
        if self.vm:
            self.vm.stop()
            self.vm.server.shutdown()
            self.vm.server.server_close()
        vm = hopvm.Vm(secure_boot=self.secure_boot if secure_boot is None else secure_boot)
        self.live = hopvm.attach_live(vm)
        if second_disk:
            path = os.path.join(hopvm.RUN, 'second.qcow2')
            os.makedirs(hopvm.RUN, exist_ok=True)
            hopvm.run('qemu-img', 'create', '-f', 'qcow2', path, '80G')
            vm.extra_disks.append(path)
        disk, vars_fd, tpm = hopvm.new_run_disks()
        vm.start(disk, vars_fd, tpm)
        self.vm = vm
        return vm, Session(vm)


def stream_output(tag):
    """Sends what's printed to the live branch once a minute, while the probe is being written."""
    import sys
    from live import Live
    live = Live.from_environment()
    if not live:
        return
    lines = []
    real = sys.stdout

    class Tee:
        def write(_, text):
            lines.append(text)
            real.write(text)

        def flush(_):
            real.flush()

    sys.stdout = Tee()

    def push():
        while True:
            time.sleep(60)
            live.push(f'log-{tag}.txt', ''.join(lines).encode())

    import threading
    threading.Thread(target=push, daemon=True).start()


def main(args):
    stream_output('-'.join(args.scenarios))
    bench = Bench(secure_boot=not args.no_secure_boot)
    failed = False
    try:
        for name in args.scenarios:
            if name == 'live':
                continue
            log(f'===== scenario {name}')
            try:
                globals()[f'scenario_{name}'](bench)
            except Exception as ex:
                failed = True
                log(f'scenario {name} stopped: {ex!r}')
                try:
                    bench.vm.shot(f'{name}-stopped')
                except Exception:
                    pass
        if 'live' in args.scenarios:
            from live import Live
            Live.from_environment().serve({'bench': bench, 'time': time, 'hopvm': hopvm, 'scenarios': globals(), 'FACTS_SCRIPT': FACTS_SCRIPT})
    finally:
        if bench.vm:
            bench.vm.stop()
    raise SystemExit(1 if failed else 0)


# --- Getting Windows into a state ---------------------------------------------------------------


def restart_and_wait(vm, limit=600):
    before = vm.agent_boot.get('user')
    vm.ps('shutdown.exe /r /t 3', timeout=30)
    vm.wait_agent('user', limit=limit, not_boot=before)


def make_second_disk(vm):
    """A GPT disk with an NTFS D: and free space after it, as Disk Management would leave it."""
    print(vm.ps(r"""
$disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Select-Object -First 1
Initialize-Disk -Number $disk.Number -PartitionStyle GPT
$p = New-Partition -DiskNumber $disk.Number -Size 40GB -DriveLetter D
Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel Data -Confirm:$false | Out-Null
Get-Disk | Format-Table Number, FriendlyName, BusType, PartitionStyle, @{n='GB';e={[int]($_.Size/1GB)}} -Auto
foreach ($d in Get-CimInstance Win32_DiskDrive) { "$($d.Index) $($d.PNPDeviceID) removal policy " + (Get-PnpDeviceProperty -InstanceId $d.PNPDeviceID -KeyName DEVPKEY_Device_RemovalPolicy).Data }
"""), flush=True)


def make_space_stuck(vm):
    """Puts hibernation's file and the paging file near the end of C:, with plenty free, as on the PCs in
    issues #4 and #6. It takes them both away, fills the disk so they can only come back at the end,
    then frees it all again. What it fills it with isn't written, so the VM's disk doesn't grow."""
    print(vm.ps(r"""
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
(Get-ItemProperty $key).PagingFiles | Set-Content C:\probe\paging-before.txt
powercfg /h off
New-ItemProperty -Path $key -Name PagingFiles -PropertyType MultiString -Value ([string[]]@()) -Force | Out-Null
"paging off, hibernation off"
"""), flush=True)
    restart_and_wait(vm)
    print(vm.ps(r"""
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$free = (Get-Volume -DriveLetter C).SizeRemaining
# Windows puts each file in the smallest gap it fits, so the big file takes the start of the big gap.
$size = [int64]($free - 14GB)
fsutil file createnew C:\probe\filler.bin $size
fsutil file setvaliddata C:\probe\filler.bin $size
powercfg /h on
New-ItemProperty -Path $key -Name PagingFiles -PropertyType MultiString -Value ([string[]]@(Get-Content C:\probe\paging-before.txt)) -Force | Out-Null
"filler {0:N1} GB, then {1:N1} GB free" -f ($size/1GB), ((Get-Volume -DriveLetter C).SizeRemaining/1GB)
"""), flush=True)
    restart_and_wait(vm)
    print(vm.ps(r"""
Remove-Item C:\probe\filler.bin -Force
Optimize-Volume -DriveLetter C -ReTrim | Out-Null
"filler gone"
""", timeout=600), flush=True)


# --- Scenarios ----------------------------------------------------------------------------------


def scenario_hello(bench):
    vm, s = bench.fresh()
    s.desktop()
    s.facts('first look')
    print(vm.ps(r"""
Get-Disk | Format-Table Number, FriendlyName, BusType, PartitionStyle, Size -Auto
powercfg /a
(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
"Secure Boot: " + (Confirm-SecureBootUEFI)
"EnableLUA: " + (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System).EnableLUA
"integrity: " + (whoami /groups | Select-String 'Mandatory Label')
bcdedit /enum firmware
"""), flush=True)


def scenario_screens(bench):
    """Every screen that doesn't need the disk to change."""
    vm, s = bench.fresh(second_disk=True)
    s.desktop()
    make_second_disk(vm)
    s.get_hop()
    s.open_as_a_person()
    vm.shot('checking')
    s.settle()
    print(s.controls(), flush=True)
    vm.shot('choose')

    # The system picker, at the sentence's first line.
    s.click_hop(236, LINE_ONE_Y)
    time.sleep(1.5)
    vm.shot('system-picker')
    for _ in range(12):
        vm.key('down', hold=40)
        time.sleep(0.1)
    time.sleep(0.5)
    vm.shot('system-picker-scrolled')
    vm.key('esc')
    time.sleep(1)

    # The drive picker, with the second disk.
    s.click_hop(150, LINE_TWO_Y)
    time.sleep(1.5)
    vm.shot('drive-picker')
    s.click_hop(250, DRIVE_ROW_Y + DRIVE_ROW_H)
    time.sleep(8)
    vm.shot('choose-second-drive')
    s.click_hop(150, LINE_TWO_Y)
    time.sleep(1.5)
    vm.shot('drive-picker-on-second')
    s.click_hop(250, DRIVE_ROW_Y)
    time.sleep(8)
    vm.shot('back-on-c')

    # Install asks once more.
    s.press('Install', limit=30)
    time.sleep(3)
    vm.shot('install-pressed')
    if 'Continue' in s.names():
        s.press('Continue')
        time.sleep(2)
        vm.shot('confirm')
    s.press('Back')
    time.sleep(2)

    # Replacing Windows is the row after the drives. Nothing starts until the word's typed.
    s.click_hop(150, LINE_TWO_Y)
    time.sleep(1.5)
    vm.shot('drive-picker-replace-row')
    drives = vm.ps(r'(Get-Partition | Where-Object DriveLetter).Count').strip()
    s.click_hop(250, DRIVE_ROW_Y + DRIVE_ROW_H * int(drives))
    time.sleep(15)
    vm.shot('replace-warning-1')
    for screen in range(2, 4):
        if 'Continue' not in s.names():
            break
        s.press('Continue')
        time.sleep(2)
        vm.shot(f'replace-warning-{screen}')
    vm.shot('erase-empty')
    vm.type('ERAS')
    time.sleep(1)
    vm.shot('erase-wrong')
    print(s.controls(), flush=True)
    vm.type('E')
    time.sleep(1)
    vm.shot('erase-typed')
    print(s.controls(), flush=True)
    s.press('Cancel')
    time.sleep(2)
    vm.shot('after-cancel')
    s.hop_log()


def scenario_stuck(bench):
    """Make room, for real. The one that had only ever been mocked."""
    vm, s = bench.fresh()
    s.desktop()
    s.facts('as installed')
    make_space_stuck(vm)
    s.facts('after moving the files to the end')
    s.get_hop()
    s.open_as_a_person('stuck-elevation-prompt')
    s.settle()
    vm.shot('stuck-choose')
    print(s.names(), flush=True)
    s.press('Make room', limit=60)
    time.sleep(4)
    vm.shot('stuck-make-room')
    before = vm.agent_boot.get('user')
    s.press('Make room and restart', limit=30)
    for second in range(0, 40, 2):
        vm.shot(f'stuck-restarting-{second:02}s')
        time.sleep(2)
    vm.wait_agent('user', limit=600, not_boot=before)
    vm.shot('stuck-signed-in-again')
    # Does hop come back by itself, and is anything asked?
    for second in range(0, 240, 10):
        vm.shot(f'stuck-after-restart-{second:03}s')
        ui = s.ui()
        print(f'{second}s: hop window: {ui.get("found")}, {[c["name"] for c in ui.get("controls", []) if c.get("name")]}', flush=True)
        if ui.get('found') and second >= 20:
            break
        time.sleep(10)
    s.facts('just after the restart')
    s.hop_log()
