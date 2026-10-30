using System;
using System.Drawing;
using System.Windows.Forms;
using static Hop.Theme;

namespace Hop
{
    enum DriveMode { Edit, Progress, Static }

    /// <summary>
    /// Drive C: drawn to scale: Windows (used and free), the Linux part in the
    /// system's brand color, and the installer. In Edit mode the boundary between
    /// Windows and Linux is dragged to choose the size.
    /// </summary>
    sealed class DriveBar : DrawnControl
    {
        const float HeaderHeight = 16, HeaderGap = 12, BarHeight = 84, LegendGap = 14, LegendHeight = 16, Gap = 3;

        readonly Timer animation = new Timer { Interval = 16 };
        float shownProgress, targetProgress;
        bool dragging, handleHot;

        public string DiskName = "";
        public int WindowsGB = 1, UsedGB, InstallerGB = 8;
        public int TailFreeGB;      // free space after C:, used before C: shrinks
        public int MinLinuxGB = 25, MaxLinuxGB = 25;
        public string SystemName = "";
        public Color Brand = Ink;
        public DriveMode Mode = DriveMode.Edit;
        public string Status = "";
        int linuxGB = 60;

        public event EventHandler ValueChanged;

        public DriveBar()
        {
            MakeClickable();
            Cursor = Cursors.Default;
            Height = S(HeaderHeight + HeaderGap + BarHeight + LegendGap + LegendHeight);
            animation.Tick += (s, e) =>
            {
                shownProgress += (targetProgress - shownProgress) * 0.12f;
                if (Math.Abs(targetProgress - shownProgress) < 0.001f) { shownProgress = targetProgress; animation.Stop(); }
                Invalidate();
            };
        }

        public int LinuxGB
        {
            get => linuxGB;
            set
            {
                int clamped = Math.Max(MinLinuxGB, Math.Min(MaxLinuxGB, value));
                if (clamped == linuxGB) return;
                linuxGB = clamped;
                Invalidate();
                ValueChanged?.Invoke(this, EventArgs.Empty);
            }
        }

        /// <summary>0 to 1. Moves smoothly toward the new value.</summary>
        public float Progress
        {
            get => targetProgress;
            set
            {
                targetProgress = Math.Max(0, Math.Min(1, value));
                if (value <= 0) shownProgress = 0;
                animation.Start();
            }
        }

        // --- Geometry ----------------------------------------------------------------

        RectangleF Bar => new RectangleF(0, F(HeaderHeight + HeaderGap), Width, F(BarHeight));
        float PxPerGB => (Bar.Width - 2 * F(Gap)) / Math.Max(1, WindowsGB + TailFreeGB);
        float InstallerLeft => Bar.Right - InstallerGB * PxPerGB;
        float LinuxLeft => InstallerLeft - F(Gap) - linuxGB * PxPerGB;
        float WindowsRight => LinuxLeft - F(Gap);
        float HandleX => LinuxLeft - F(Gap) / 2;

        /// <summary>Size of C: once Linux has its space: it only shrinks by what the free space can't cover.</summary>
        int WindowsAfterGB => WindowsGB - Math.Max(0, linuxGB + InstallerGB - TailFreeGB);

        int ValueAt(float x) => (int)Math.Round((InstallerLeft - F(Gap) - x) / PxPerGB);

        // --- Input ------------------------------------------------------------------------

        bool InBar(Point p) => Bar.Contains(p);
        bool NearHandle(Point p) => Mode == DriveMode.Edit && InBar(p) && Math.Abs(p.X - HandleX) <= F(14);

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (Mode != DriveMode.Edit || e.Button != MouseButtons.Left || !InBar(e.Location)) return;
            Focus();
            dragging = true;
            if (!NearHandle(e.Location)) LinuxGB = ValueAt(e.X);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragging) LinuxGB = ValueAt(e.X);
            bool hot = dragging || NearHandle(e.Location);
            if (hot != handleHot) { handleHot = hot; Invalidate(); }
            Cursor = Mode == DriveMode.Edit && InBar(e.Location) ? Cursors.SizeWE : Cursors.Default;
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            dragging = false;
            handleHot = NearHandle(e.Location);
            Invalidate();
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (!dragging) handleHot = false;
        }

        protected override bool IsInputKey(Keys keyData) =>
            keyData == Keys.Left || keyData == Keys.Right || base.IsInputKey(keyData);

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (Mode != DriveMode.Edit) return;
            switch (e.KeyCode)
            {
                case Keys.Left: LinuxGB += 1; break;      // the handle moves left, Linux grows
                case Keys.Right: LinuxGB -= 1; break;
                case Keys.PageUp: LinuxGB += 10; break;
                case Keys.PageDown: LinuxGB -= 10; break;
                case Keys.Home: LinuxGB = MaxLinuxGB; break;
                case Keys.End: LinuxGB = MinLinuxGB; break;
                default: return;
            }
            e.Handled = true;
        }

        // --- Drawing ---------------------------------------------------------------------

        protected override void Draw(Graphics g)
        {
            var small = Font(13);
            var smallStrong = Font(13, true);
            float headerBaseline = TextKit.BaselineIn(small, 0, F(HeaderHeight));
            string size = TailFreeGB > 0 ? $"Drive C: {WindowsGB} GB + {TailFreeGB} GB free" : $"Drive C: {WindowsGB} GB";
            string header = DiskName.Length > 0 ? $"{DiskName} · {size}" : size;
            TextKit.Draw(g, header, smallStrong, Ink, 0, headerBaseline);
            string right = Mode == DriveMode.Edit ? "Drag to resize" : Status;
            var rightFont = Mode == DriveMode.Edit ? small : smallStrong;
            TextKit.Draw(g, right, rightFont, Mode == DriveMode.Edit ? Tertiary : Ink, Width - TextKit.Width(right, rightFont), headerBaseline);

            var bar = Bar;
            var saved = g.Clip;
            using (var clip = RoundedRect(bar, F(12))) g.SetClip(clip);

            float usedRight = bar.X + Math.Min(UsedGB, WindowsGB) * PxPerGB;
            using (var used = new SolidBrush(DriveUsed)) g.FillRectangle(used, bar.X, bar.Y, Math.Max(0, Math.Min(usedRight, WindowsRight) - bar.X), bar.Height);
            if (WindowsRight > usedRight)
                using (var free = new SolidBrush(DriveFree)) g.FillRectangle(free, usedRight, bar.Y, WindowsRight - usedRight, bar.Height);

            var linux = new RectangleF(LinuxLeft, bar.Y, InstallerLeft - F(Gap) - LinuxLeft, bar.Height);
            bool preparing = Mode == DriveMode.Progress;
            var linuxFill = preparing ? Mix(Color.White, Brand, 0.18f) : Brand;
            using (var brush = new SolidBrush(linuxFill)) g.FillRectangle(brush, linux);
            using (var brush = new SolidBrush(Mix(Color.White, Brand, 0.42f)))
                g.FillRectangle(brush, InstallerLeft, bar.Y, bar.Right - InstallerLeft, bar.Height);

            // Labels sit on the bottom edge; in progress mode they make room for the progress line.
            float labelBottom = bar.Bottom - F(preparing ? 26 : 14);
            DrawLabels(g, new RectangleF(bar.X + F(16), bar.Y, WindowsRight - bar.X - F(32), bar.Height), labelBottom,
                "Windows", $"{UsedGB} GB used · {Math.Max(0, WindowsAfterGB - UsedGB)} GB free", Ink, DriveUsedText);

            var onLinux = preparing ? Mix(Brand, Color.Black, 0.45f) : TextOn(Brand);
            var onLinuxSoft = preparing ? Mix(Brand, Color.Black, 0.2f) : Color.FromArgb(210, onLinux);
            DrawLabels(g, new RectangleF(linux.X + F(18), bar.Y, linux.Width - F(34), bar.Height), labelBottom,
                SystemName, $"{linuxGB} GB", onLinux, onLinuxSoft);

            if (preparing && linux.Width > F(60))
            {
                var track = new RectangleF(linux.X + F(18), bar.Bottom - F(18), linux.Width - F(34), F(4));
                FillRounded(g, Mix(Color.White, Brand, 0.35f), track, F(2));
                if (shownProgress > 0)
                    FillRounded(g, Brand, new RectangleF(track.X, track.Y, Math.Max(track.Height, track.Width * shownProgress), track.Height), F(2));
            }
            g.Clip = saved;

            if (Mode == DriveMode.Edit) DrawHandle(g, bar);

            // Legend for the installer strip.
            float legendTop = bar.Bottom + F(LegendGap);
            string legend = $"Installer · {InstallerGB} GB, removable once Linux is set up";
            float legendWidth = TextKit.Width(legend, small);
            float lx = Width - legendWidth;
            FillRounded(g, Mix(Color.White, Brand, 0.42f), new RectangleF(lx - F(16), legendTop + F(4), F(8), F(8)), F(2));
            TextKit.Draw(g, legend, small, Tertiary, lx, TextKit.BaselineIn(small, legendTop, F(LegendHeight)));
        }

        void DrawLabels(Graphics g, RectangleF area, float bottom, string title, string detail, Color titleColor, Color detailColor)
        {
            if (area.Width < F(48)) return;
            var titleFont = Font(14, true);
            var detailFont = Font(13);
            string t = TextKit.Ellipsize(title, titleFont, area.Width);
            string d = TextKit.Ellipsize(detail, detailFont, area.Width);
            float detailBaseline = bottom - TextKit.Descent(detailFont);
            TextKit.Draw(g, t, titleFont, titleColor, area.X, detailBaseline - F(18));
            TextKit.Draw(g, d, detailFont, detailColor, area.X, detailBaseline);
        }

        void DrawHandle(Graphics g, RectangleF bar)
        {
            float w = F(handleHot ? 16 : 14), h = F(handleHot ? 50 : 44);
            var handle = new RectangleF(HandleX - w / 2, bar.Y + (bar.Height - h) / 2, w, h);
            Shadow(g, handle, w / 2, 4, 60);
            FillRounded(g, Color.White, handle, w / 2);
            if (Focused && ShowFocusCues)
                StrokeRounded(g, Brand, RectangleF.Inflate(handle, F(2.5f), F(2.5f)), w / 2 + F(2.5f), F(2));
            using (var grip = new SolidBrush(Quaternary))
            {
                float gh = F(14), gy = handle.Y + (h - gh) / 2;
                g.FillRectangle(grip, HandleX - F(2.25f), gy, F(1.5f), gh);
                g.FillRectangle(grip, HandleX + F(0.75f), gy, F(1.5f), gh);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) animation.Dispose();
            base.Dispose(disposing);
        }
    }
}
