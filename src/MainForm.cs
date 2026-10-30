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
    /// <summary>
    /// One window, one sentence, one drive, one button. Every state reuses the same
    /// layout: the sentence on top, a note under it, then the drive (or the install
    /// steps, or the undo options), and the footer.
    /// </summary>
    sealed class MainForm : Form
    {
        const int DesignWidth = 880, DesignHeight = 560, Gutter = 56, TitleHeight = 44;
        const int MinLinuxGB = 25, InstallerGB = 8, IsoDownloadGB = 8;

        static readonly string[] StageVerbs =
        {
            "Checking this PC", "Downloading", "Checking the download",
            "Making room on the disk", "Copying the installer", "Adding it to the startup menu",
        };
        // How much of the total time each stage takes, roughly; the download dominates.
        static readonly float[] DownloadWeights = { 2, 60, 6, 6, 24, 2 };
        static readonly float[] IsoWeights = { 3, 0, 10, 12, 70, 5 };

        readonly ChromeButton minimize = new ChromeButton(false), close = new ChromeButton(true);
        readonly Sentence sentence = new Sentence();
        readonly TextBlock note = new TextBlock();
        readonly DriveBar drive = new DriveBar();
        readonly StepsView steps = new StepsView();
        readonly BusyLine busyLine = new BusyLine();
        readonly TextBox log = new TextBox();
        readonly OptionRow removeAll, removeInstaller;
        readonly TextLink footerLink = new TextLink();
        readonly PillButton primary = new PillButton("", true), secondary = new PillButton("", false);
        readonly Timer poll = new Timer { Interval = 150 };

        Engine engine;
        List<Distro> catalog;
        StartupInfo startup;
        Distro selected;
        string isoPath;
        int linuxGB = 60;

        Distro prepared;          // what the ready screen is about
        bool busy, installing, working, cancelling, showingLog;
        string shownStatus;
        Action onPrimary, onSecondary, onLink;

        public MainForm()
        {
            Text = "hop";
            using (var stream = typeof(MainForm).Assembly.GetManifestResourceStream("Hop.Icon.ico"))
                Icon = new Icon(stream);
            FormBorderStyle = FormBorderStyle.None;
            AutoScaleMode = AutoScaleMode.None;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Background;
            DoubleBuffered = true;
            ClientSize = new Size(S(DesignWidth), S(DesignHeight));

            minimize.Location = new Point(ClientSize.Width - S(92), S(6));
            close.Location = new Point(ClientSize.Width - S(46), S(6));
            minimize.Click += (s, e) => WindowState = FormWindowState.Minimized;
            close.Click += (s, e) => Close();

            int width = S(DesignWidth - 2 * Gutter);
            sentence.Bounds = new Rectangle(S(Gutter), S(TitleHeight + 52), width, S(96));
            note.Width = width;
            drive.Width = width;
            steps.Width = width;
            log.Width = width;
            busyLine.Width = width;
            log.Multiline = true;
            log.ReadOnly = true;
            log.ScrollBars = ScrollBars.Vertical;
            log.BorderStyle = BorderStyle.None;
            log.BackColor = Fill;
            log.ForeColor = Secondary;
            log.Font = new System.Drawing.Font("Consolas", 8.5f);
            removeAll = new OptionRow("Linux isn't installed yet",
                "Remove everything hop made and give the space back to Windows.", width);
            removeInstaller = new OptionRow("Linux is installed",
                "Remove only the installer and its startup entry. Linux stays.", width);
            removeAll.Chosen += (s, e) => PickUndo(removeAll);
            removeInstaller.Chosen += (s, e) => PickUndo(removeInstaller);

            sentence.PickerClicked += (s, e) => OpenPicker();
            drive.ValueChanged += (s, e) =>
            {
                if (drive.Mode != DriveMode.Edit) return;
                linuxGB = drive.LinuxGB;
                ShowChoose();
            };
            primary.Click += (s, e) => onPrimary?.Invoke();
            secondary.Click += (s, e) => onSecondary?.Invoke();
            footerLink.Click += (s, e) => onLink?.Invoke();

            Controls.AddRange(new Control[]
            {
                minimize, close, sentence, note, drive, steps, log, busyLine, removeAll, removeInstaller, footerLink, secondary, primary,
            });
            poll.Tick += (s, e) =>
            {
                if (installing) UpdatePreparing();
                else if (working) ShowWorkingStatus();
            };
            Shown += async (s, e) => await StartAsync();
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ClassStyle |= Native.CS_DROPSHADOW;
                cp.Style |= Native.WS_MINIMIZEBOX | Native.WS_SYSMENU;   // taskbar minimize and restore
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.RoundCorners(Handle);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            Prepare(g);
            var font = Theme.Font(13, true);
            DrawImageFit(g, Theme.Logo("hop"), new RectangleF(S(Gutter), (S(TitleHeight) - S(16)) / 2f, S(16), S(16)));
            TextKit.Draw(g, "hop", font, Tertiary, S(Gutter) + S(22), TextKit.BaselineIn(font, 0, S(TitleHeight)));
            if (!Native.IsWindows11)
                using (var pen = new Pen(Hairline)) g.DrawRectangle(pen, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left) Native.BeginWindowDrag(Handle);
        }

        static string Describe(Exception ex) => (ex is AggregateException agg ? agg.GetBaseException() : ex).Message;

        // --- Layout -----------------------------------------------------------------------

        /// <summary>Shows the sentence, a note, one body element and the footer.</summary>
        void Arrange(Run[][] lines, string noteText, Color noteColor, Control body, int bodyGap)
        {
            sentence.Set(lines);
            note.Set(noteText, noteColor);
            note.Location = new Point(S(Gutter), sentence.Top + S(46 * lines.Length + 18));
            note.Visible = !string.IsNullOrEmpty(noteText);

            foreach (var c in new Control[] { drive, steps, log, busyLine, removeAll, removeInstaller }) c.Visible = false;
            int top = (note.Visible ? note.Bottom : sentence.Bottom) + S(bodyGap);
            if (body == drive || body == log)
            {
                drive.Top = top;
                log.Bounds = new Rectangle(S(Gutter), top, drive.Width, drive.Height);
                body = showingLog && body == drive ? log : body;
            }
            if (body == removeAll)
            {
                removeAll.Location = new Point(S(Gutter), top);
                removeInstaller.Location = new Point(S(Gutter), removeAll.Bottom + S(12));
                removeInstaller.Visible = true;
            }
            if (body == steps) steps.Location = new Point(S(Gutter), top);
            if (body == busyLine) busyLine.Location = new Point(S(Gutter), top);
            if (body != null) body.Visible = true;
            drive.Left = S(Gutter);
        }

        void Footer(string link, Action linkAction, string primaryText, Action primaryAction,
            string secondaryText = null, Action secondaryAction = null, Color? linkColor = null)
        {
            bool clickable = linkAction != null;
            footerLink.Set(link, clickable, linkColor ?? (clickable ? Ink : Tertiary), clickable);
            footerLink.Location = new Point(S(Gutter), ClientSize.Height - S(48) - footerLink.Height / 2);
            onLink = linkAction;

            primary.Text = primaryText ?? "";
            primary.Visible = primaryText != null;
            primary.Enabled = primaryAction != null;
            primary.Location = new Point(ClientSize.Width - S(Gutter) - primary.Width, ClientSize.Height - S(48) - primary.Height / 2);
            onPrimary = primaryAction;

            secondary.Text = secondaryText ?? "";
            secondary.Visible = secondaryText != null;
            int right = primary.Visible ? primary.Left - S(10) : ClientSize.Width - S(Gutter);
            secondary.Location = new Point(right - secondary.Width, primary.Top);
            secondary.Enabled = secondaryAction != null;
            onSecondary = secondaryAction;
        }

        Image LogoFor(Distro d) => Logo(d?.Logo);

        string NameFor(Distro d) => d != null ? d.Name : TextKit.Ellipsize(Path.GetFileNameWithoutExtension(isoPath ?? ""), Theme.Font(38, true), S(380));

        Distro Current => selected ?? new Distro { Id = "custom", Name = NameFor(null), Color = Ink, Strategy = "freespace", Note = "" };

        // --- Startup --------------------------------------------------------------------

        async Task StartAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Checking"), Run.Black("this PC") } }, "Looking at the drive and the startup menu.");
            try
            {
                engine = await Task.Run(() => new Engine());
                catalog = await Task.Run(() => engine.GetCatalog());
                startup = await engine.GetStartupInfoAsync();
            }
            catch (Exception ex)
            {
                EndWork();
                ShowBlocked(Describe(ex));
                return;
            }
            EndWork();

            selected = catalog[0];
            int max = startup.UsableGB - InstallerGB - IsoDownloadGB;
            linuxGB = Math.Max(MinLinuxGB, Math.Min(max, Math.Max(60, (max / 2) / 10 * 10)));

            await ShowStartScreenAsync();
        }

        async Task ShowStartScreenAsync()
        {
            if (startup.Status == "ready")
            {
                prepared = catalog.FirstOrDefault(d => d.Id == startup.PreparedId) ?? new Distro
                {
                    Id = "custom",
                    Name = string.IsNullOrWhiteSpace(startup.PreparedDistro) ? "Linux" : startup.PreparedDistro,
                    Color = Ink,
                };
                await ShowReadyAsync();
            }
            else if (startup.Status == "leftover") ShowLeftover();
            else ShowChoose();
        }

        // --- Leftovers ---------------------------------------------------------------------

        void ShowLeftover()
        {
            Arrange(new[] { new[] { Run.Gray("An earlier attempt"), Run.Black("didn't finish.") } },
                "It left partitions or a startup entry on this PC. Clean them up to start fresh. Windows and your files stay.",
                Secondary, null, 0);
            Footer(null, null, "Clean up", () => _ = CleanupAsync(false, afterwards: null));
        }

        /// <summary>Runs the clean-up, then shows a result or goes back to choosing.</summary>
        async Task CleanupAsync(bool installerOnly, Action afterwards)
        {
            BeginWork(new[] { new[] { Run.Gray("Cleaning up"), Run.Black("hop's changes") } }, "Starting…");
            try
            {
                await engine.CleanupAsync(installerOnly);
                startup = await engine.GetStartupInfoAsync();
                EndWork();
                if (afterwards != null) afterwards();
                else ShowChoose();
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't clean up"), Run.Black("everything") } }, Describe(ex), Danger, null, 0);
                Footer(null, null, "Try again", () => _ = CleanupAsync(installerOnly, afterwards));
            }
        }

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

            Action install = enoughSpace ? (Action)ShowConfirm : null;
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

        // --- Another Linux (Pond) ----------------------------------------------------------

        void ShowRemoveOther()
        {
            string name = startup.OtherName;
            Arrange(new[]
            {
                new[] { Run.Gray("Remove"), Run.Black(name) },
                new[] { Run.Gray("and free"), Run.Black(startup.OtherGB + " GB") },
            }, $"This deletes {name} and everything stored in it, and takes it out of the startup menu. Windows and your files stay.",
                Secondary, null, 0);
            Footer("Back", ShowChoose, "Remove " + name, () => _ = RemoveOtherAsync());
        }

        async Task RemoveOtherAsync()
        {
            string name = startup.OtherName;
            int freed = startup.OtherGB;
            BeginWork(new[] { new[] { Run.Gray("Removing"), Run.Black(name) } }, "Starting…");
            try
            {
                await engine.RemoveOtherSystemAsync();
                startup = await engine.GetStartupInfoAsync();
                EndWork();
                Arrange(new[] { new[] { Run.Black(name), Run.Gray("is gone.") } },
                    $"{freed} GB is free now. Use it for Linux, or give it back to Windows.", Secondary, null, 0);
                Footer(null, null, "Use it for Linux", ShowChoose, "Give it to Windows", () => _ = ExpandWindowsAsync());
            }
            catch (Exception ex)
            {
                EndWork();
                try { startup = await engine.GetStartupInfoAsync(); } catch { }
                Arrange(new[] { new[] { Run.Gray("Couldn't remove"), Run.Black(name) } }, Describe(ex), Danger, null, 0);
                Footer("Back", ShowChoose, "Try again", startup.OtherGB > 0 ? () => _ = RemoveOtherAsync() : (Action)null);
            }
        }

        async Task ExpandWindowsAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Giving the space to"), Run.Black("Windows") } }, "Starting…");
            try
            {
                await engine.ExpandWindowsAsync();
                startup = await engine.GetStartupInfoAsync();
                EndWork();
                Arrange(new[] { new[] { Run.Black("Windows"), Run.Gray("has the space back.") } },
                    $"Drive C: is {startup.WindowsGB} GB now.", Secondary, null, 0);
                Footer("Start over", ShowChoose, "Close", Close);
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't give the space to"), Run.Black("Windows") } }, Describe(ex), Danger, null, 0);
                Footer(null, null, "Use it for Linux", ShowChoose, "Try again", () => _ = ExpandWindowsAsync());
            }
        }

        // --- Working ------------------------------------------------------------------------

        /// <summary>
        /// Shows a long action in progress: the sentence says what is happening, a line
        /// moves underneath, the note follows the engine's status, and the buttons go away.
        /// </summary>
        void BeginWork(Run[][] lines, string firstNote)
        {
            busy = working = true;
            engine?.ResetProgress();
            shownStatus = null;
            Arrange(lines, firstNote, Secondary, busyLine, 28);
            Footer(null, null, null, null);
            poll.Start();
        }

        void EndWork()
        {
            poll.Stop();
            busy = working = false;
        }

        void ShowWorkingStatus()
        {
            string status = engine?.Status;
            if (string.IsNullOrEmpty(status) || status == shownStatus) return;
            shownStatus = status;
            note.Set(status.Replace("...", "…"), Secondary);
            busyLine.Top = note.Bottom + S(28);
        }

        // --- Preparing -------------------------------------------------------------------

        async Task InstallAsync()
        {
            var system = Current;
            engine.Log.Clear();
            engine.ResetProgress();
            log.Clear();
            busy = installing = true;
            cancelling = false;
            showingLog = false;
            drive.Progress = 0;
            UpdatePreparing();
            poll.Start();
            try
            {
                await engine.InstallAsync(selected?.Id ?? "custom", isoPath, linuxGB);
                poll.Stop();
                busy = installing = false;
                prepared = system;
                await ShowReadyAsync();
            }
            catch (Exception ex)
            {
                poll.Stop();
                busy = installing = false;
                if (cancelling || ex is PipelineStoppedException) { ShowChoose(); return; }
                await ShowFailureAsync(Describe(ex));
            }
        }

        void UpdatePreparing()
        {
            var system = Current;
            int stage = Math.Min(engine.Stage, StageVerbs.Length - 1);
            long bytes = engine.Bytes, total = engine.TotalBytes;
            bool counting = total > 0 && (stage == 1 || stage == 4);

            var weights = isoPath == null ? DownloadWeights : IsoWeights;
            float done = 0, sum = weights.Sum();
            for (int i = 0; i < stage; i++) done += weights[i];
            if (engine.Percent >= 0) done += weights[stage] * engine.Percent / 100f;
            int overall = (int)Math.Min(99, Math.Round(100 * done / sum));

            ConfigureDrive(DriveMode.Progress, system);
            drive.Status = overall + "%";
            drive.Progress = overall / 100f;
            Arrange(new[]
            {
                new[] { Run.Gray("Preparing"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
                counting
                    ? new[] { Run.Gray(StageVerbs[stage] + ","), Run.Black($"{bytes / 1e9:0.0} of {total / 1e9:0.0} GB") }
                    : new[] { Run.Gray(StageVerbs[stage]) },
            }, $"Step {stage + 1} of {StageVerbs.Length}. You can keep using your PC while this runs.", Secondary, drive, 64);

            SyncLog();

            bool canCancel = stage <= 2 && !cancelling;
            Footer(showingLog ? "Hide details" : "Show details", ToggleLog, null, null,
                canCancel ? "Cancel" : null, canCancel ? (Action)CancelInstall : null);
        }

        int logShown;

        void SyncLog()
        {
            if (log.TextLength == 0) logShown = 0;
            while (logShown < engine.Log.Count)
                log.AppendText(engine.Log[logShown++] + Environment.NewLine);
        }

        void ToggleLog()
        {
            showingLog = !showingLog;
            UpdatePreparing();
        }

        void CancelInstall()
        {
            cancelling = true;
            StopDownload();
            engine.Stop();
        }

        void StopDownload()
        {
            if (!(engine?.Sync["ChildPid"] is int pid)) return;
            try { Process.GetProcessById(pid).Kill(); } catch { }
        }

        async Task ShowFailureAsync(string message)
        {
            var system = Current;
            SyncLog();
            bool changed = false;
            try
            {
                startup = await engine.GetStartupInfoAsync();
                changed = startup.Status != "none";
            }
            catch { }

            showingLog = true;
            Arrange(new[]
            {
                new[] { Run.Gray("Couldn't prepare"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
                new[] { Run.Red("Something went wrong.") },
            }, message, Secondary, log, 40);
            // The engine undoes its own changes after a failure; if something is still left, offer to clean up.
            if (changed) Footer(null, null, "Clean up", () => _ = CleanupAsync(false, afterwards: null));
            else Footer(null, null, "Try again", ShowChoose);
        }

        // --- Ready ---------------------------------------------------------------------------

        async Task ShowReadyAsync()
        {
            InstallSteps installSteps;
            try { installSteps = await engine.GetStepsAsync(); }
            catch (Exception ex) { ShowBlocked(Describe(ex)); return; }

            steps.Set(installSteps.Steps, installSteps.Notes);
            Arrange(new[]
            {
                new[] { new Run { Text = prepared.Name, Color = Ink, Logo = Logo(prepared.Logo) }, Run.Gray("is ready.") },
            }, "Restart to open its installer. These are the choices to make there.", Secondary, steps, 40);
            Footer("Undo changes", () => ShowUndo(() => _ = ShowReadyAsync()), "Restart now", () => _ = RestartAsync(),
                "Later", Close, Secondary);
        }

        async Task RestartAsync()
        {
            primary.Enabled = false;
            try
            {
                await engine.RestartIntoInstallerAsync();
            }
            catch (Exception ex)
            {
                note.Set(Describe(ex) + " You can also restart yourself and tap F11 while the PC starts, then choose the installer.", Danger);
                primary.Enabled = true;
            }
        }

        // --- Undo ----------------------------------------------------------------------------

        void ShowUndo(Action goBack)
        {
            removeAll.Selected = removeInstaller.Selected = false;
            removeAll.Enabled = removeInstaller.Enabled = true;
            Arrange(new[] { new[] { Run.Gray("Remove"), Run.Black("hop's changes") } },
                "Choose what's true for this PC.", Secondary, removeAll, 32);
            Footer("Back", goBack, "Remove", null);
        }

        void PickUndo(OptionRow row)
        {
            removeAll.Selected = row == removeAll;
            removeInstaller.Selected = row == removeInstaller;
            bool installerOnly = row == removeInstaller;
            primary.Enabled = true;
            onPrimary = () => _ = CleanupAsync(installerOnly, () =>
            {
                Arrange(new[] { new[] { Run.Black("Changes removed.") } },
                    installerOnly ? "The installer and its startup entry are gone." : "The space is back on drive C:.", Secondary, null, 0);
                Footer("Start over", ShowChoose, "Close", Close);
            });
        }

        void ShowBlocked(string message)
        {
            Arrange(new[] { new[] { Run.Black("hop can't continue.") } }, message, Secondary, null, 0);
            Footer(null, null, "Close", Close);
        }

        // --- Closing -------------------------------------------------------------------------

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            base.OnFormClosing(e);
            if (!busy) return;
            if (installing && engine.Stage <= 2)
            {
                StopDownload();
                Environment.Exit(0);
            }
            e.Cancel = true;
            note.Set("hop is changing the disk. Close it once it finishes.", Danger);
        }
    }
}
