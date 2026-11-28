using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
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
    sealed partial class MainForm : Form
    {
        const int DesignWidth = 880, DesignHeight = 560, Gutter = 56, TitleHeight = 44;
        const int SmallestLinuxGB = 25, InstallerGB = 8, IsoDownloadGB = 8;
        const int RestoreBeforeExitMilliseconds = 15000;

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
        readonly TextBox eraseWord = new TextBox();
        readonly OptionRow removeAll, removeInstaller;
        readonly TextLink footerLink = new TextLink();
        readonly TextLink stepsLink = new TextLink();   // a second, quiet link in the footer, for the steps
        readonly PillButton primary = new PillButton("", true), secondary = new PillButton("", false);
        readonly Timer poll = new Timer { Interval = 150 };

        Engine engine;
        List<Distro> catalog;
        StartupInfo startup;
        DriveChoice target;       // where Linux goes
        string pickedDownload;    // the drive chosen for the download, if not left to hop
        Distro selected;
        string isoPath;
        int linuxGB = 60;

        /// <summary>Some installers won't start with less than hop's own least.</summary>
        int MinLinuxGB => Math.Max(SmallestLinuxGB, selected?.MinGB ?? 0);

        Distro prepared;          // what the ready screen is about
        bool busy, installing, working, cancelling, showingLog;
        bool reading;             // what's running only reads the PC, so closing can just stop it
        string closeRefused;      // why hop wouldn't close, which stays on screen during the install
        int screen;               // goes up each time a screen is drawn, so that a late answer can tell it's been replaced
        bool fullDisk;            // set only by typing the word on the last screen of replacing Windows
        string shownStatus;
        Action onPrimary, onSecondary, onLink, onEraseWord, onStepsLink;

        /// <summary>1920×1080 at 200% has less height than the window at that scale, and its buttons are at the bottom.</summary>
        public static float ScaleToFit(float dpiScale)
        {
            var room = Screen.PrimaryScreen.WorkingArea;
            return Math.Min(dpiScale, Math.Min((float)room.Width / DesignWidth, (float)room.Height / DesignHeight));
        }

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
            eraseWord.Width = S(240);
            eraseWord.BorderStyle = BorderStyle.None;
            eraseWord.BackColor = Fill;
            eraseWord.ForeColor = Ink;
            eraseWord.TextChanged += (s, e) => onEraseWord?.Invoke();
            removeAll = new OptionRow("Linux isn't installed yet",
                "Remove hop's partitions and startup entry, and free the space.", width);
            removeInstaller = new OptionRow("Linux is installed",
                "Remove only the installer and its startup entry. Linux stays.", width);
            removeAll.Chosen += (s, e) => PickUndo(removeAll);
            removeInstaller.Chosen += (s, e) => PickUndo(removeInstaller);

            sentence.PickerClicked += picker => { if (picker == 0) OpenPicker(); else OpenDrivePicker(); };
            drive.ValueChanged += (s, e) =>
            {
                if (drive.Mode != DriveMode.Edit) return;
                linuxGB = drive.LinuxGB;
                ShowChoose();
            };
            primary.Click += (s, e) => onPrimary?.Invoke();
            secondary.Click += (s, e) => onSecondary?.Invoke();
            footerLink.Click += (s, e) => onLink?.Invoke();
            stepsLink.Click += (s, e) => onStepsLink?.Invoke();

            Controls.AddRange(new Control[]
            {
                minimize, close, sentence, note, drive, steps, log, eraseWord, busyLine, removeAll, removeInstaller, footerLink, stepsLink, secondary, primary,
            });
            stepsLink.Visible = false;
            // A long body mustn't cover the footer. This leaves the order Tab goes in alone.
            foreach (var c in new Control[] { footerLink, stepsLink, secondary, primary }) c.BringToFront();
            poll.Tick += (s, e) =>
            {
                // hop's own restart is on its way, and nothing may stand in front of it.
                if (engine != null && engine.RoomRestarting) SetShutdownBlock(false);
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

        protected override void WndProc(ref Message m)
        {
            // The poll may not have seen hop's own restart begin: it asks right away, and must be let through.
            const int WM_QUERYENDSESSION = 0x11;
            if (m.Msg == WM_QUERYENDSESSION && engine != null && engine.RoomRestarting) SetShutdownBlock(false);
            base.WndProc(ref m);
        }

        /// <summary>Escape goes back, wherever the footer has a Back. Never while hop is working.</summary>
        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            const int WM_KEYDOWN = 0x0100;
            const long WasDown = 1L << 30;
            // Held down, it would go back again from the screen it went back to.
            bool fresh = msg.Msg == WM_KEYDOWN && (msg.LParam.ToInt64() & WasDown) == 0;
            if (keyData == Keys.Escape && fresh && !busy && !installing && !working && !reading)
            {
                foreach (var (control, action) in new (Control, Action)[] { (footerLink, onLink), (secondary, onSecondary), (primary, onPrimary) })
                {
                    if (control.Visible && control.Enabled && control.Text == "Back" && action != null)
                    {
                        action();
                        return true;
                    }
                }
            }
            return base.ProcessCmdKey(ref msg, keyData);
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

        /// <summary>The wheel comes here when a button has the focus and the pointer isn't over the list.</summary>
        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            if (steps.Visible) steps.Wheel(e.Delta);
        }

        static string Describe(Exception ex) => (ex is AggregateException agg ? agg.GetBaseException() : ex).Message;

        // --- Layout -----------------------------------------------------------------------

        /// <summary>Shows the sentence, a note, one body element and the footer.</summary>
        void Arrange(Run[][] lines, string noteText, Color noteColor, Control body, int bodyGap)
        {
            screen++;
            // The taskbar shows only the install; any other screen takes it off.
            if (!installing) ShowTaskbar(Native.TaskbarState.NoProgress);
            foreach (var c in new Control[] { sentence, drive, removeAll, removeInstaller }) c.Enabled = true;
            sentence.Set(lines);
            note.Set(noteText, noteColor);
            note.Location = new Point(S(Gutter), sentence.Top + S(46 * lines.Length + 18));
            note.Visible = !string.IsNullOrEmpty(noteText);

            foreach (var c in new Control[] { drive, steps, log, eraseWord, busyLine, removeAll, removeInstaller, stepsLink }) c.Visible = false;
            onStepsLink = null;
            onEraseWord = null;
            int top = (note.Visible ? note.Bottom : sentence.Bottom) + S(bodyGap);
            if (body == drive || body == log)
            {
                drive.Top = top;
                log.Bounds = new Rectangle(S(Gutter), top, drive.Width, drive.Height);
                body = installing && showingLog && body == drive ? log : body;
            }
            if (body == removeAll)
            {
                removeAll.Location = new Point(S(Gutter), top);
                removeInstaller.Location = new Point(S(Gutter), removeAll.Bottom + S(12));
                removeInstaller.Visible = true;
            }
            if (body == steps) PlaceSteps(top);
            if (body == eraseWord) eraseWord.Location = new Point(S(Gutter), top);
            if (body == busyLine) busyLine.Location = new Point(S(Gutter), top);
            if (body != null) body.Visible = true;
            drive.Left = S(Gutter);
        }

        int FooterTop => ClientSize.Height - S(48) - primary.Height / 2;

        /// <summary>The list stops short of the footer, and scrolls if that isn't room enough.</summary>
        void PlaceSteps(int top)
        {
            steps.Location = new Point(S(Gutter), top);
            steps.FitTo(FooterTop - S(12) - top);
        }

        /// <summary>A second link next to the footer's, on the screens with steps. Call after Footer.</summary>
        void FooterSecondLink(string text, Action action)
        {
            stepsLink.Set(text, action != null, action != null ? Ink : Tertiary, action != null);
            int left = footerLink.Visible && footerLink.Width > S(4) ? footerLink.Right + S(28) : S(Gutter);
            stepsLink.Location = new Point(left, ClientSize.Height - S(48) - stepsLink.Height / 2);
            stepsLink.Enabled = true;
            stepsLink.Visible = true;
            onStepsLink = action;
        }

        void Footer(string link, Action linkAction, string primaryText, Action primaryAction,
            string secondaryText = null, Action secondaryAction = null, Color? linkColor = null)
        {
            bool clickable = linkAction != null;
            footerLink.Enabled = true;
            footerLink.Set(link, clickable, linkColor ?? (clickable ? Ink : Tertiary), clickable);
            footerLink.Location = new Point(S(Gutter), ClientSize.Height - S(48) - footerLink.Height / 2);
            onLink = linkAction;

            primary.Text = primaryText ?? "";
            primary.Visible = primaryText != null;
            primary.Enabled = primaryAction != null;
            primary.Location = new Point(ClientSize.Width - S(Gutter) - primary.Width, FooterTop);
            onPrimary = primaryAction;

            secondary.Text = secondaryText ?? "";
            secondary.Visible = secondaryText != null;
            int right = primary.Visible ? primary.Left - S(10) : ClientSize.Width - S(Gutter);
            secondary.Location = new Point(right - secondary.Width, primary.Top);
            secondary.Enabled = secondaryAction != null;
            onSecondary = secondaryAction;
        }

        /// <summary>
        /// For asking the engine something on the way to the next screen: nothing on this one can start
        /// anything meanwhile, and it stays busy so that closing is handled. The next screen enables it all.
        /// </summary>
        int HoldScreen()
        {
            busy = reading = true;
            foreach (var c in new Control[] { sentence, drive, removeAll, removeInstaller, footerLink, secondary, primary }) c.Enabled = false;
            return screen;
        }

        /// <summary>False if something has drawn another screen since, whose state isn't this one's to change.</summary>
        bool ReleaseScreen(int held)
        {
            if (held != screen) return false;
            busy = reading = false;
            return true;
        }

        Image LogoFor(Distro d) => Logo(d?.Logo);

        string NameFor(Distro d) => d != null ? d.Name : TextKit.Ellipsize(Path.GetFileNameWithoutExtension(isoPath ?? ""), Theme.Font(38, true), S(380));

        Distro Current => selected ?? new Distro { Id = "custom", Name = NameFor(null), Color = Ink };

        // --- Closing -------------------------------------------------------------------------

        /// <summary>
        /// The install holds the engine until it stops, so that comes first. A stop that hangs can't
        /// keep hop open: Make room's settings then go back the next time hop opens.
        /// </summary>
        void RestoreRoomBeforeExit()
        {
            if (!roomMade) return;
            try
            {
                Task.Run(() =>
                {
                    engine.StopAndWait();
                    engine.RestoreRoomSettings();
                }).Wait(RestoreBeforeExitMilliseconds);
            }
            catch (Exception) { }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            base.OnFormClosing(e);
            // hop asked for this restart. Refusing would have Windows say hop is preventing it,
            // and Make room carries on afterwards, so nothing goes back yet.
            if (e.CloseReason == CloseReason.WindowsShutDown && engine != null && engine.RoomRestarting) return;
            if (!busy)
            {
                engine?.StopIfRunning("Get-DriveSpace");
                // Copying a bug report can be holding the engine, and this mustn't freeze the window.
                RestoreRoomBeforeExit();
                return;
            }
            if (reading || (installing && engine.TryCancel()))
            {
                StopDownload();
                RestoreRoomBeforeExit();
                Environment.Exit(0);
            }
            e.Cancel = true;
            closeRefused = "hop is changing the disk. Close it once it finishes.";
            note.Set(closeRefused, Danger);
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            SetShutdownBlock(false);
            ShowTaskbar(Native.TaskbarState.NoProgress);
            base.OnFormClosed(e);
        }
    }
}
