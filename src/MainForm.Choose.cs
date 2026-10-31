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

        const string WindowsLetter = "C";

        string roomLetter;  // Make room has run on this drive, and its settings go back on when hop closes

        bool roomMade => roomLetter != null;

        bool RoomMadeHere => roomLetter != null && roomLetter == target.Letter;

        /// <summary>Linux's room on the chosen drive, less the download if that's going there too.</summary>
        int MaxLinuxGB => MaxLinuxGBOn(target);

        int MaxLinuxGBOn(DriveChoice drive)
        {
            var download = DownloadSpotFor(drive);
            bool downloadHere = isoPath == null && (download != null ? download.Letter == drive.Letter : drive.IsWindows);
            return drive.UsableGB - InstallerGB - (downloadHere ? IsoDownloadGB : 0);
        }

        DownloadDrive DownloadSpot => DownloadSpotFor(target);

        /// <summary>
        /// The Downloads folder as ever, unless it's short of room, or filling it would leave
        /// too little for Linux. Then whichever other drive has the most free.
        /// </summary>
        DownloadDrive DownloadSpotFor(DriveChoice drive)
        {
            var drives = startup.DownloadDrives;
            if (isoPath != null || drives == null || drives.Count == 0) return null;
            var picked = drives.FirstOrDefault(d => d.Letter == pickedDownload);
            if (picked != null) return picked;

            int room = IsoDownloadGB + 1;
            var usual = drives.FirstOrDefault(d => d.IsDefault);
            var other = drives.Where(d => d.Letter != drive.Letter && d.FreeGB >= room).OrderByDescending(d => d.FreeGB).FirstOrDefault();
            bool squeezes = usual != null && usual.Letter == drive.Letter && drive.UsableGB - InstallerGB - IsoDownloadGB < MinLinuxGB;
            if (usual != null && usual.FreeGB >= room && !(squeezes && other != null)) return usual;
            return other ?? usual;
        }

        /// <summary>What hop can fall back on if it can't list the drives: the same C: as ever.</summary>
        DriveChoice WindowsDrive => startup.Drives.FirstOrDefault(d => d.IsWindows) ?? new DriveChoice
        {
            Id = "", Kind = "volume", Letter = WindowsLetter, Title = "Drive C:", DiskName = startup.DiskName, OnWindowsDisk = true,
            SizeGB = startup.WindowsGB, UsedGB = startup.UsedGB, TailFreeGB = startup.TailFreeGB, UsableGB = startup.UsableGB,
            StuckGB = startup.StuckGB, ShrinkBlocker = startup.Blocker, BlockerKind = startup.BlockerKind,
        };

        /// <summary>C: as ever, unless Make room is part way through elsewhere, or C: can't be used at all.</summary>
        async Task ChooseFirstTargetAsync()
        {
            target = startup.Drives.FirstOrDefault(d => !string.IsNullOrEmpty(startup.RoomLetter) && d.Letter == startup.RoomLetter) ?? WindowsDrive;
            if (target.Blocker != null)
                target = startup.Drives.FirstOrDefault(d => d.Blocker == null) ?? target;
            await MeasureTargetAsync();
        }

        /// <summary>Windows is only asked how far a drive really shrinks once it has been chosen, because that can take a while.</summary>
        async Task MeasureTargetAsync()
        {
            if (target.Estimated && target.Blocker == null)
                target = await engine.GetDriveSpaceAsync(target.Id);
        }

        /// <summary>Reads the PC again and keeps the same drive chosen, if it's still there.</summary>
        async Task ReloadAsync()
        {
            startup = await engine.GetStartupInfoAsync();
            target = startup.Drives.FirstOrDefault(d => d.Id == target?.Id) ?? WindowsDrive;
            await MeasureTargetAsync();
        }

        /// <summary>Another drive with room for Linux, for when this one hasn't any.</summary>
        DriveChoice BetterDrive => startup.Drives
            .Where(d => d.Id != target.Id && d.Blocker == null && MaxLinuxGBOn(d) >= MinLinuxGB)
            .OrderByDescending(d => d.UsableGB).FirstOrDefault();

        bool HasDriveChoice => startup.Drives.Count > 1 || (isoPath == null && startup.DownloadDrives.Count(d => d.FreeGB > IsoDownloadGB) > 1);

        Run[] WhereLine(bool picker, Color brand)
        {
            if (!HasDriveChoice)
                return new[] { Run.Gray("next to Windows, with"), Run.Black(linuxGB + " GB") };
            return new[]
            {
                Run.Gray("on"),
                new Run { Text = target.Kind == "disk" ? target.Title : target.Title.ToLowerInvariant(), Color = Ink, Picker = picker, Underline = brand },
                Run.Gray("with"),
                Run.Black(linuxGB + " GB"),
            };
        }

        void ShowChoose()
        {
            var system = Current;
            bool usable = target.Blocker == null;
            bool enoughSpace = usable && MaxLinuxGB >= MinLinuxGB;
            bool secureBootStops = selected != null && selected.SecureBootOff && startup.SecureBoot;
            linuxGB = enoughSpace ? Math.Max(MinLinuxGB, Math.Min(MaxLinuxGB, linuxGB)) : MinLinuxGB;

            // The drive has the room, but Windows can't release it. Deleting files wouldn't help.
            bool stuck = usable && !enoughSpace && !target.IsFreeSpace && MaxLinuxGB + target.StuckGB >= MinLinuxGB;
            var better = enoughSpace ? null : BetterDrive;

            string noteText;
            if (!usable)
                noteText = target.Blocker;
            else if (secureBootStops)
                noteText = $"{system.Name} doesn't start with Secure Boot on. Pick another system, or turn off Secure Boot in the BIOS and open hop again.";
            else if (!enoughSpace && better != null)
                noteText = $"{target.Title} doesn't have room for Linux. {better.Title} on {better.DiskName} has {(better.Estimated ? "about " : "")}{better.UsableGB} GB to spare.";
            else if (stuck)
                noteText = StuckNote();
            else if (!enoughSpace && target.IsFreeSpace)
                noteText = $"This free space is about {MinLinuxGB - MaxLinuxGB} GB too small. Choose another drive.";
            else if (!enoughSpace)
                noteText = $"{target.Title} needs about {MinLinuxGB - MaxLinuxGB} GB more free space. Delete some files or empty the Recycle Bin, then open hop again.";
            else if (isoPath != null)
                noteText = $"Your file, {Path.GetFileName(isoPath)}. Nothing on your disk changes until you click Install.";
            else
            {
                var download = DownloadSpot;
                string saved = download != null && !download.IsDefault ? $" to drive {download.Letter}:" : "";
                noteText = $"{system.Name}{(system.Version != null ? " " + system.Version : "")}, downloaded from {system.Source}{saved}. Nothing on your disk changes until you click Install.";
            }

            ConfigureDrive(DriveMode.Edit, system);
            Arrange(new[]
            {
                new[] { Run.Gray("Install"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected), Picker = true, Underline = system.Color } },
                WhereLine(true, Hairline),
            }, noteText, enoughSpace && !secureBootStops ? Secondary : Danger, usable ? drive : null, 64);

            Action install = enoughSpace && !secureBootStops ? () => _ = CheckThenConfirmAsync() : (Action)null;
            string primaryText = "Install";
            Action primaryAction = install;
            // Nothing else can happen until there's room, so this is what the button does.
            bool needRoom = stuck && !RoomMadeHere && !secureBootStops;
            if (better != null && !secureBootStops)
            {
                primaryText = $"Use {better.Title.ToLowerInvariant()}";
                primaryAction = () => _ = UseDriveAsync(better);
            }
            else if (needRoom)
            {
                primaryText = "Make room";
                primaryAction = () => _ = ShowMakeRoomAsync();
            }

            if (startup.OtherGB > 0)
                Footer($"Remove {startup.OtherName} ({startup.OtherGB} GB)", ShowRemoveOther, primaryText, primaryAction);
            else if (!usable)
                Footer("Choose another drive", OpenDrivePicker, primaryText, primaryAction);
            else if (needRoom && better != null)
                Footer("Make room", () => _ = ShowMakeRoomAsync(), primaryText, primaryAction);
            else if (target.TailFreeGB > 0 && !target.IsFreeSpace)
                Footer($"Give the free {target.TailFreeGB} GB to {(target.IsWindows ? "Windows" : target.Title.ToLowerInvariant())}", () => _ = ExpandWindowsAsync(), primaryText, primaryAction);
            else if (!stuck && target.StuckGB >= StuckWorthExplainingGB && !RoomMadeHere)
                Footer("Make room", () => _ = ShowMakeRoomAsync(), primaryText, primaryAction);
            else if ((stuck || target.StuckGB >= StuckWorthExplainingGB) && target.BlockerKind == "restore")
                Footer("Delete restore points", ShowDeleteRestorePoints, primaryText, primaryAction);
            else
                Footer("Windows and your files stay.", null, primaryText, primaryAction);
        }

        string StuckNote()
        {
            int release = Math.Max(0, target.UsableGB);
            if (!RoomMadeHere)
                return $"{target.Title} has free space, but Windows can only release {release} GB of it, because it can't move some files. hop can clear them.";
            if (target.BlockerKind == "restore")
                return $"Windows can release {release} GB. Restore points on {target.Title.ToLowerInvariant()} are stopping it releasing more.";
            return $"hop made what room it could, and Windows can release {release} GB. It can't move {target.ShrinkBlocker ?? "some system files"}, which limits the rest.";
        }

        // --- Choosing a drive -------------------------------------------------------------

        void OpenDrivePicker()
        {
            if (busy) return;
            var rows = startup.Drives;
            if (rows.Count == 0) return;
            var items = rows.Select(d => new PickerItem
            {
                Name = d.Title,
                Note = d.Blocker != null ? (d.Kind == "disk" ? "Can't be used" : $"{d.DiskName} · Can't be used")
                    : $"{d.DiskName} · {(d.Estimated ? "about " : "")}{d.UsableGB} GB to spare",
                Dimmed = d.Blocker != null,
            }).ToList();
            var downloads = isoPath == null ? startup.DownloadDrives.Where(d => d.FreeGB > IsoDownloadGB).ToList() : new List<DownloadDrive>();
            var spot = DownloadSpot;
            string footer = downloads.Count > 1 && spot != null ? $"Save the download on drive {spot.Letter}:…" : null;
            var picker = new ListPicker(items, rows.FindIndex(d => d.Id == target.Id), footer, 460);
            picker.Picked += i => _ = UseDriveAsync(rows[i]);
            picker.FooterClicked += () => OpenDownloadPicker(downloads);
            var anchor = sentence.PickerScreenBounds(1);
            picker.Show(new Point(anchor.Left - S(13), anchor.Bottom + S(8)));
        }

        void OpenDownloadPicker(List<DownloadDrive> downloads)
        {
            var items = downloads.Select(d => new PickerItem
            {
                Name = $"Drive {d.Letter}:",
                Note = (d.IsDefault ? "Your Downloads folder · " : "") + $"{d.FreeGB} GB free",
            }).ToList();
            var picker = new ListPicker(items, downloads.FindIndex(d => d.Letter == DownloadSpot?.Letter), null, 400);
            picker.Picked += i =>
            {
                pickedDownload = downloads[i].Letter;
                ShowChoose();
            };
            var anchor = sentence.PickerScreenBounds(1);
            picker.Show(new Point(anchor.Left - S(13), anchor.Bottom + S(8)));
        }

        async Task UseDriveAsync(DriveChoice choice)
        {
            if (choice.Blocker != null || !choice.Estimated)
            {
                target = choice;
                ShowChoose();
                return;
            }
            BeginWork(new[] { new[] { Run.Gray("Checking"), Run.Black(choice.Title.ToLowerInvariant()) } }, "Asking Windows how much room it can give up. This can take a minute on a big drive.");
            try
            {
                target = await engine.GetDriveSpaceAsync(choice.Id);
                EndWork();
                ShowChoose();
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't check"), Run.Black(choice.Title.ToLowerInvariant()) } }, Describe(ex), Danger, null, 0);
                Footer("Back", ShowChoose, null, null);
            }
        }

        async Task ShowMakeRoomAsync()
        {
            InstallSteps plan;
            try { plan = await engine.GetMakeRoomStepsAsync(target.Letter); }
            catch (Exception ex) { ShowBlocked(Describe(ex)); return; }

            steps.Set(plan.Steps, plan.Notes);
            Arrange(new[] { new[] { Run.Gray("Make room"), Run.Black("on " + target.Title.ToLowerInvariant()) } },
                $"{target.Title} has {target.StuckGB} GB free that Windows can't release yet. hop can clear what's in the way.", Secondary, steps, 32);
            Footer("Back", ShowChoose, plan.Restart ? "Make room and restart" : "Make room", () => _ = MakeRoomAsync());
        }

        async Task MakeRoomAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Making"), Run.Black("room") } }, "Starting…");
            try
            {
                // The restart is on its way, and Windows closes hop. Only another drive gets past this.
                if (await engine.StartMakeRoomAsync(target.Letter)) return;
                roomLetter = target.Letter;
                await ReloadAsync();
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

        void ShowDeleteRestorePoints()
        {
            Arrange(new[] { new[] { Run.Gray("Delete"), Run.Black("restore points?") } },
                $"They're stopping Windows releasing more of {target.Title.ToLowerInvariant()}. This deletes the ones on {target.Letter}: for good, and can't be undone. Your files aren't touched, and Windows makes new ones later.",
                Secondary, null, 0);
            Footer("Back", ShowChoose, "Delete them", () => _ = DeleteRestorePointsAsync());
        }

        async Task DeleteRestorePointsAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Making"), Run.Black("room") } }, "Starting…");
            try
            {
                await engine.ClearRestorePointsAsync(target.Letter);
                await ReloadAsync();
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
            drive.DiskName = target.DiskName ?? "";
            drive.DriveTitle = target.Title;
            drive.DriveLabel = target.IsWindows ? "Windows" : target.Title;
            drive.IsFreeSpace = target.IsFreeSpace;
            drive.WindowsGB = target.IsFreeSpace ? 0 : Math.Max(1, target.SizeGB);
            drive.TailFreeGB = target.TailFreeGB;
            drive.UsedGB = target.UsedGB;
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
            var items = catalog.Select(d => new PickerItem { Name = d.Name, Note = d.Note, Logo = d.Logo }).ToList();
            var picker = new ListPicker(items, catalog.IndexOf(selected), "Use an ISO file…");
            picker.Picked += i =>
            {
                selected = catalog[i];
                isoPath = null;
                ShowChoose();
            };
            picker.FooterClicked += ChooseIso;
            var anchor = sentence.PickerScreenBounds(0);
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
            try { warnings = await engine.GetWarningsAsync(target.Id); }
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
                WhereLine(false, Background),
            }, ConfirmNote(), Ink, drive, 64);
            Footer("Back", ShowChoose, "Start", () => _ = InstallAsync());
            primary.Focus();
        }

        string ConfirmNote()
        {
            int shrink = Math.Max(0, linuxGB + InstallerGB - target.TailFreeGB);
            string title = target.Title.ToLowerInvariant();
            string keeps = target.IsFreeSpace ? "nothing on this drive shrinks" : target.IsWindows ? "Windows keeps its size" : $"{title} keeps its size";
            string room = shrink == 0
                ? $"hop will use {linuxGB + InstallerGB} GB of free space, so {keeps}. It copies the installer there"
                : target.TailFreeGB > 0
                    ? $"hop will use {target.TailFreeGB} GB of free space and shrink {title} by {shrink} GB, copy the installer there"
                    : $"hop will shrink {title} by {shrink} GB, copy the installer there";
            return room + " and add it to the startup menu. Keep the charger connected until it finishes.";
        }
    }
}
