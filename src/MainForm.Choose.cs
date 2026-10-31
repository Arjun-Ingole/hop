using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Threading.Tasks;
using System.Windows.Forms;
using static Hop.Theme;

namespace Hop
{
    sealed partial class MainForm
    {
        // --- Choose -----------------------------------------------------------------------

        const int StuckWorthExplainingGB = 20;

        bool roomMade;      // Make room has run, and its settings go back on when hop closes

        int MaxLinuxGB => startup.UsableGB - InstallerGB - (isoPath == null ? IsoDownloadGB : 0);

        void ShowChoose()
        {
            var system = Current;
            bool enoughSpace = MaxLinuxGB >= MinLinuxGB;
            bool secureBootStops = selected != null && selected.SecureBootOff && startup.SecureBoot;
            linuxGB = enoughSpace ? Math.Max(MinLinuxGB, Math.Min(MaxLinuxGB, linuxGB)) : MinLinuxGB;

            // C: has the room, but Windows can't release it. Deleting files wouldn't help.
            bool stuck = !enoughSpace && MaxLinuxGB + startup.StuckGB >= MinLinuxGB;

            string noteText;
            if (secureBootStops)
                noteText = $"{system.Name} doesn't start with Secure Boot on. Pick another system, or turn off Secure Boot in the BIOS and open hop again.";
            else if (stuck)
                noteText = StuckNote();
            else if (!enoughSpace)
                noteText = $"Drive C: needs about {MinLinuxGB - MaxLinuxGB} GB more free space. Delete some files or empty the Recycle Bin, then open hop again.";
            else if (isoPath != null)
                noteText = $"Your file, {Path.GetFileName(isoPath)}. Nothing on your disk changes until you click Install.";
            else
                noteText = $"{system.Name}{(system.Version != null ? " " + system.Version : "")}, downloaded from {system.Source}. Nothing on your disk changes until you click Install.";

            ConfigureDrive(DriveMode.Edit, system);
            Arrange(new[]
            {
                new[] { Run.Gray("Install"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected), Picker = true, Underline = system.Color } },
                new[] { Run.Gray("next to Windows, with"), Run.Black(linuxGB + " GB") },
            }, noteText, enoughSpace && !secureBootStops ? Secondary : Danger, drive, 64);

            Action install = enoughSpace && !secureBootStops ? () => _ = CheckThenConfirmAsync() : (Action)null;
            // Nothing else can happen until there's room, so this is what the button does.
            bool needRoom = stuck && !roomMade && !secureBootStops;
            string primaryText = needRoom ? "Make room" : "Install";
            Action primaryAction = needRoom ? () => _ = ShowMakeRoomAsync() : install;
            if (startup.OtherGB > 0)
                Footer($"Remove {startup.OtherName} ({startup.OtherGB} GB)", ShowRemoveOther, primaryText, primaryAction);
            else if (startup.TailFreeGB > 0)
                Footer($"Give the free {startup.TailFreeGB} GB to Windows", () => _ = ExpandWindowsAsync(), primaryText, primaryAction);
            else if (!stuck && startup.StuckGB >= StuckWorthExplainingGB && !roomMade)
                Footer("Make room", () => _ = ShowMakeRoomAsync(), primaryText, primaryAction);
            else if ((stuck || startup.StuckGB >= StuckWorthExplainingGB) && startup.BlockerKind == "restore")
                Footer("Delete restore points", ShowDeleteRestorePoints, primaryText, primaryAction);
            else
                Footer("Windows and your files stay.", null, primaryText, primaryAction);
        }

        string StuckNote()
        {
            int release = Math.Max(0, startup.UsableGB);
            if (!roomMade)
                return $"Drive C: has free space, but Windows can only release {release} GB of it, because it can't move some files. hop can clear them.";
            if (startup.BlockerKind == "restore")
                return $"Windows can release {release} GB. Restore points on drive C: are stopping it releasing more.";
            return $"hop made what room it could, and Windows can release {release} GB. It can't move {startup.Blocker ?? "some system files"}, which limits the rest.";
        }

        async Task ShowMakeRoomAsync()
        {
            InstallSteps plan;
            try { plan = await engine.GetMakeRoomStepsAsync(); }
            catch (Exception ex) { ShowBlocked(Describe(ex)); return; }

            steps.Set(plan.Steps, plan.Notes);
            Arrange(new[] { new[] { Run.Gray("Make room"), Run.Black("on drive C:") } },
                $"Drive C: has {startup.StuckGB} GB free that Windows can't release yet. hop can clear what's in the way.", Secondary, steps, 32);
            Footer("Back", ShowChoose, "Make room and restart", () => _ = MakeRoomAsync());
        }

        async Task MakeRoomAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Making"), Run.Black("room") } }, "Starting…");
            try
            {
                await engine.StartMakeRoomAsync();
                // The restart is on its way. Windows closes hop.
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't"), Run.Black("make room") } }, Describe(ex), Danger, null, 0);
                Footer("Back", ShowChoose, null, null);
            }
        }

        void ShowDeleteRestorePoints()
        {
            Arrange(new[] { new[] { Run.Gray("Delete"), Run.Black("restore points?") } },
                "They're stopping Windows releasing more of drive C:. This deletes the ones on C: for good, and can't be undone. Your files aren't touched, and Windows makes new ones later.",
                Secondary, null, 0);
            Footer("Back", ShowChoose, "Delete them", () => _ = DeleteRestorePointsAsync());
        }

        async Task DeleteRestorePointsAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Making"), Run.Black("room") } }, "Starting…");
            try
            {
                await engine.ClearRestorePointsAsync();
                startup = await engine.GetStartupInfoAsync();
                EndWork();
                ShowChoose();
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't"), Run.Black("make room") } }, Describe(ex), Danger, null, 0);
                Footer("Back", ShowChoose, null, null);
            }
        }

        void ConfigureDrive(DriveMode mode, Distro system)
        {
            drive.Mode = mode;
            drive.DiskName = startup.DiskName ?? "";
            drive.WindowsGB = Math.Max(1, startup.WindowsGB);
            drive.TailFreeGB = startup.TailFreeGB;
            drive.UsedGB = startup.UsedGB;
            drive.SystemName = system.Name;
            drive.Brand = system.Color;
            drive.MinLinuxGB = MinLinuxGB;
            drive.MaxLinuxGB = Math.Max(MinLinuxGB, MaxLinuxGB);
            drive.LinuxGB = linuxGB;
            drive.Invalidate();
        }

        void OpenPicker()
        {
            if (busy || catalog == null) return;
            var picker = new SystemPicker(catalog, selected);
            picker.Picked += d =>
            {
                selected = d;
                isoPath = null;
                ShowChoose();
            };
            picker.IsoRequested += ChooseIso;
            var anchor = sentence.PickerScreenBounds;
            picker.Show(new Point(anchor.Left - S(13), anchor.Bottom + S(8)));
        }

        void ChooseIso()
        {
            using (var dialog = new OpenFileDialog { Filter = "ISO files (*.iso)|*.iso", Title = "Choose an Ubuntu-based ISO file" })
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                isoPath = dialog.FileName;
                selected = null;
                ShowChoose();
            }
        }

        /// <summary>Anything worth checking comes first. Checked now, not at startup: the charger may have come out since.</summary>
        async Task CheckThenConfirmAsync()
        {
            primary.Enabled = false;
            string[] warnings;
            try { warnings = await engine.GetWarningsAsync(); }
            catch { warnings = new string[0]; }
            primary.Enabled = true;
            if (warnings.Length == 0) { ShowConfirm(); return; }

            steps.Set(warnings, null);
            Arrange(new[] { new[] { Run.Gray("Before you"), Run.Black("start") } },
                "hop can go ahead, but check these first.", Secondary, steps, 32);
            Footer("Back", ShowChoose, "Continue", ShowConfirm);
        }

        /// <summary>Install asks once more, in place, before touching the disk.</summary>
        void ShowConfirm()
        {
            var system = Current;
            ConfigureDrive(DriveMode.Static, system);
            Arrange(new[]
            {
                new[] { Run.Gray("Install"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
                new[] { Run.Gray("next to Windows, with"), Run.Black(linuxGB + " GB") },
            }, ConfirmNote(), Ink, drive, 64);
            Footer("Back", ShowChoose, "Start", () => _ = InstallAsync());
            primary.Focus();
        }

        string ConfirmNote()
        {
            int shrink = Math.Max(0, linuxGB + InstallerGB - startup.TailFreeGB);
            string room = shrink == 0
                ? $"hop will use {linuxGB + InstallerGB} GB of free space, so Windows keeps its size. It copies the installer there"
                : startup.TailFreeGB > 0
                    ? $"hop will use {startup.TailFreeGB} GB of free space and shrink drive C: by {shrink} GB, copy the installer there"
                    : $"hop will shrink drive C: by {shrink} GB, copy the installer there";
            return room + " and add it to the startup menu. Keep the charger connected until it finishes.";
        }
    }
}
