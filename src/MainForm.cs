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
    sealed partial class MainForm : Form
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

        // --- Closing -------------------------------------------------------------------------

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            base.OnFormClosing(e);
            if (!busy) return;
            if (installing && engine.TryCancel())
            {
                StopDownload();
                Environment.Exit(0);
            }
            e.Cancel = true;
            note.Set("hop is changing the disk. Close it once it finishes.", Danger);
        }
    }
}
