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

        int MaxLinuxGB => startup.UsableGB - InstallerGB - (isoPath == null ? IsoDownloadGB : 0);

        void ShowChoose()
        {
            var system = Current;
            bool enoughSpace = MaxLinuxGB >= MinLinuxGB;
            linuxGB = enoughSpace ? Math.Max(MinLinuxGB, Math.Min(MaxLinuxGB, linuxGB)) : MinLinuxGB;

            string noteText;
            if (!enoughSpace)
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
            }, noteText, enoughSpace ? Secondary : Danger, drive, 64);

            Action install = enoughSpace ? () => _ = CheckThenConfirmAsync() : (Action)null;
            if (startup.OtherGB > 0)
                Footer($"Remove {startup.OtherName} ({startup.OtherGB} GB)", ShowRemoveOther, "Install", install);
            else if (startup.TailFreeGB > 0)
                Footer($"Give the free {startup.TailFreeGB} GB to Windows", () => _ = ExpandWindowsAsync(), "Install", install);
            else
                Footer("Windows and your files stay.", null, "Install", install);
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
