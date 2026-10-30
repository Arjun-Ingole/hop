using System;
using System.Drawing;
using System.Windows.Forms;
using static Hop.Theme;

namespace Hop
{
    /// <summary>Base for owner-drawn controls: double buffered on a white background.</summary>
    abstract class DrawnControl : Control
    {
        protected bool Hovered, Pressed;

        protected DrawnControl()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Background;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            Prepare(e.Graphics);
            Draw(e.Graphics);
        }

        protected abstract void Draw(Graphics g);

        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); Hovered = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); Hovered = Pressed = false; Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { Pressed = true; Invalidate(); } }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); Pressed = false; Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }

        /// <summary>Makes a control act on Enter and Space like a button.</summary>
        protected void MakeClickable()
        {
            SetStyle(ControlStyles.Selectable, true);
            TabStop = true;
            Cursor = Cursors.Hand;
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (GetStyle(ControlStyles.Selectable) && (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space))
            {
                e.Handled = true;
                OnClick(EventArgs.Empty);
            }
        }

        protected void DrawFocusRing(Graphics g, RectangleF r, float radius)
        {
            if (Focused && ShowFocusCues)
                StrokeRounded(g, Color.FromArgb(120, Ink), RectangleF.Inflate(r, -1, -1), radius, F(2));
        }
    }

    /// <summary>The design's 42 px buttons: black primary, outlined secondary.</summary>
    sealed class PillButton : DrawnControl
    {
        readonly bool primary;

        public PillButton(string text, bool primary)
        {
            MakeClickable();
            this.primary = primary;
            Text = text;
            Height = S(42);
        }

        protected override void OnTextChanged(EventArgs e)
        {
            base.OnTextChanged(e);
            Width = (int)Math.Ceiling(Text.Length == 0 ? 0 : TextKit.Width(Text, Font(15, true)) + F(52));
            Invalidate();
        }

        protected override void OnClick(EventArgs e) { if (Enabled) base.OnClick(e); }

        protected override void Draw(Graphics g)
        {
            var r = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
            Color text;
            if (primary)
            {
                var fill = !Enabled ? Hairline : Pressed ? Color.Black : Hovered ? PrimaryHover : Ink;
                FillRounded(g, fill, r, F(10));
                text = Color.White;
            }
            else
            {
                FillRounded(g, Pressed ? Fill : Hovered && Enabled ? FillHover : Background, r, F(10));
                StrokeRounded(g, Hairline, r, F(10));
                text = Enabled ? Ink : Quaternary;
            }
            DrawFocusRing(g, r, F(10));
            var font = Font(15, true);
            float x = (Width - TextKit.Width(Text, font)) / 2;
            TextKit.Draw(g, Text, font, text, x, TextKit.BaselineIn(font, 0, Height));
        }
    }

    /// <summary>A line of footer text; clickable ones underline on hover.</summary>
    sealed class TextLink : DrawnControl
    {
        bool clickable;
        Color color = Secondary;

        public TextLink() => Height = S(24);

        public void Set(string text, bool isClickable, Color textColor, bool strong = false)
        {
            clickable = isClickable;
            color = textColor;
            Strong = strong;
            SetStyle(ControlStyles.Selectable, clickable);
            TabStop = clickable;
            Cursor = clickable ? Cursors.Hand : Cursors.Default;
            Text = text;
            Width = (int)Math.Ceiling(TextKit.Width(text, Font(14, strong))) + S(4);
            Visible = !string.IsNullOrEmpty(text);
            Invalidate();
        }

        bool Strong { get; set; }

        protected override void OnClick(EventArgs e) { if (clickable) base.OnClick(e); }

        protected override void Draw(Graphics g)
        {
            var font = Font(14, Strong);
            float baseline = TextKit.BaselineIn(font, 0, Height);
            var c = clickable && Hovered ? Ink : color;
            TextKit.Draw(g, Text, font, c, 0, baseline);
            if (clickable && (Hovered || (Focused && ShowFocusCues)))
                using (var pen = new Pen(Color.FromArgb(90, c), F(1)))
                    g.DrawLine(pen, 0, baseline + F(4), TextKit.Width(Text, font), baseline + F(4));
        }
    }

    /// <summary>Minimize and close, drawn like Windows 11's caption buttons.</summary>
    sealed class ChromeButton : DrawnControl
    {
        readonly bool close;

        public ChromeButton(bool close)
        {
            this.close = close;
            Size = new Size(S(46), S(32));
            TabStop = false;
        }

        protected override void Draw(Graphics g)
        {
            if (Hovered)
                using (var brush = new SolidBrush(close ? (Pressed ? Mix(CloseHover, Color.White, 0.15f) : CloseHover) : (Pressed ? Hairline : Fill)))
                    g.FillRectangle(brush, ClientRectangle);
            var color = close && Hovered ? Color.White : Ink;
            float cx = Width / 2f, cy = Height / 2f, h = F(5);
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
            using (var pen = new Pen(color, Math.Max(1, F(1))))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                if (close)
                {
                    g.DrawLine(pen, cx - h, cy - h, cx + h, cy + h);
                    g.DrawLine(pen, cx + h, cy - h, cx - h, cy + h);
                }
                else
                {
                    g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
                    g.DrawLine(pen, cx - h, cy, cx + h, cy);
                }
            }
        }
    }

    /// <summary>Wrapped body text with ** emphasis. Height follows the content.</summary>
    sealed class TextBlock : DrawnControl
    {
        string markup = "";
        float px = 15, lineHeight = 22;
        Color color = Secondary;
        Paragraph paragraph;

        public void Set(string text, Color textColor, float sizePx = 15, float lineHeightPx = 22)
        {
            markup = text ?? "";
            color = textColor;
            px = sizePx;
            lineHeight = lineHeightPx;
            Relayout();
        }

        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            if (paragraph == null || Math.Abs(Width - lastWidth) > 0.5f) Relayout();
        }

        float lastWidth;

        void Relayout()
        {
            lastWidth = Width;
            paragraph = markup.Length == 0 ? null : Paragraph.Layout(markup, px, lineHeight, Width);
            int height = paragraph == null ? 0 : (int)Math.Ceiling(paragraph.Height);
            if (Height != height) Height = height;
            Invalidate();
        }

        protected override void Draw(Graphics g) => paragraph?.Draw(g, 0, 0, color);
    }

    /// <summary>The numbered list of choices to make in the Linux installer.</summary>
    sealed class StepsView : DrawnControl
    {
        string[] steps = new string[0];
        string[] notes = new string[0];
        Paragraph[] stepLayouts = new Paragraph[0];
        Paragraph[] noteLayouts = new Paragraph[0];

        public void Set(string[] stepTexts, string[] noteTexts)
        {
            steps = stepTexts ?? new string[0];
            notes = noteTexts ?? new string[0];
            Relayout();
        }

        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Relayout(); }

        bool relayingOut;

        void Relayout()
        {
            if (relayingOut) return;
            relayingOut = true;
            float textWidth = Width - F(28);
            stepLayouts = Array.ConvertAll(steps, s => Paragraph.Layout(s, 15, 22, textWidth));
            noteLayouts = Array.ConvertAll(notes, s => Paragraph.Layout(s, 13, 18, Width));
            float h = 0;
            foreach (var p in stepLayouts) h += p.Height + F(14);
            if (noteLayouts.Length > 0) h += F(10);
            foreach (var p in noteLayouts) h += p.Height + F(6);
            Height = (int)Math.Ceiling(h);
            relayingOut = false;
            Invalidate();
        }

        protected override void Draw(Graphics g)
        {
            float y = 0;
            var number = Font(15, true);
            for (int i = 0; i < stepLayouts.Length; i++)
            {
                TextKit.Draw(g, (i + 1).ToString(), number, Tertiary, 0, TextKit.BaselineIn(number, y, F(22)));
                stepLayouts[i].Draw(g, F(28), y, Ink);
                y += stepLayouts[i].Height + F(14);
            }
            if (noteLayouts.Length > 0) y += F(10);
            foreach (var p in noteLayouts)
            {
                p.Draw(g, 0, y, Tertiary);
                y += p.Height + F(6);
            }
        }
    }

    /// <summary>A selectable row with a radio mark, used on the undo screen.</summary>
    sealed class OptionRow : DrawnControl
    {
        readonly string title, description;
        bool selected;

        public event EventHandler Chosen;

        public OptionRow(string title, string description, int width)
        {
            MakeClickable();
            this.title = title;
            this.description = description;
            Size = new Size(width, S(68));
        }

        public bool Selected
        {
            get => selected;
            set { selected = value; Invalidate(); }
        }

        protected override void OnClick(EventArgs e)
        {
            base.OnClick(e);
            if (!Enabled) return;
            Focus();
            Chosen?.Invoke(this, EventArgs.Empty);
        }

        protected override void Draw(Graphics g)
        {
            var r = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
            FillRounded(g, selected ? Fill : Hovered && Enabled ? FillHover : Background, r, F(12));
            StrokeRounded(g, selected ? Ink : Hairline, r, F(12), selected ? F(1.5f) : 1);
            DrawFocusRing(g, r, F(12));

            float d = F(18), cx = F(20);
            var radio = new RectangleF(cx, (Height - d) / 2, d, d);
            using (var pen = new Pen(selected ? Ink : Quaternary, F(1.5f))) g.DrawEllipse(pen, radio);
            if (selected)
                using (var dot = new SolidBrush(Ink)) g.FillEllipse(dot, RectangleF.Inflate(radio, -F(4.5f), -F(4.5f)));

            float x = F(54);
            var titleFont = Font(15, true);
            var bodyFont = Font(14);
            TextKit.Draw(g, title, titleFont, Enabled ? Ink : Tertiary, x, F(28));
            TextKit.Draw(g, TextKit.Ellipsize(description, bodyFont, Width - x - F(20)), bodyFont, Secondary, x, F(49));
        }
    }

    /// <summary>A thin line with a segment gliding across it, for work without a percentage.</summary>
    sealed class BusyLine : DrawnControl
    {
        readonly Timer animation = new Timer { Interval = 16 };
        readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();

        public BusyLine()
        {
            Height = S(3);
            animation.Tick += (s, e) => Invalidate();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            animation.Enabled = Visible;
        }

        protected override void Draw(Graphics g)
        {
            var track = new RectangleF(0, 0, Width, Height);
            FillRounded(g, Fill, track, Height / 2f);
            // One pass every 1.6 s, eased so the segment speeds up in the middle.
            double t = clock.Elapsed.TotalSeconds % 1.6 / 1.6;
            float eased = (float)(0.5 - Math.Cos(t * Math.PI) / 2);
            float segment = Width * 0.28f;
            float x = -segment + (Width + segment) * eased;
            var bar = RectangleF.Intersect(track, new RectangleF(x, 0, segment, Height));
            if (bar.Width > 0) FillRounded(g, Ink, bar, Height / 2f);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) animation.Dispose();
            base.Dispose(disposing);
        }
    }
}
