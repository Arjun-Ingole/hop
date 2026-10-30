using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using static Hop.Theme;

namespace Hop
{
    /// <summary>One piece of the sentence: plain words, or the system with its logo.</summary>
    sealed class Run
    {
        public string Text;
        public Color Color;
        public Image Logo;
        public bool Picker;        // clickable, with a chevron and an underline in Underline
        public Color Underline;

        public static Run Gray(string text) => new Run { Text = text, Color = Tertiary };
        public static Run Black(string text) => new Run { Text = text, Color = Ink };
        public static Run Red(string text) => new Run { Text = text, Color = Danger };
    }

    /// <summary>The large two-line sentence at the top of every screen.</summary>
    sealed class Sentence : DrawnControl
    {
        const float Px = 38, LineHeight = 46, WordGap = 10, LogoSize = 32, LogoGap = 12, ChevronSize = 22;
        static float Tracking => F(-0.025f * Px);

        readonly List<Run[]> lines = new List<Run[]>();
        RectangleF pickerRect = RectangleF.Empty;

        public event EventHandler PickerClicked;

        public void Set(params Run[][] newLines)
        {
            lines.Clear();
            lines.AddRange(newLines);
            Height = S(LineHeight * lines.Count + 4);
            bool hasPicker = false;
            foreach (var line in lines) foreach (var run in line) hasPicker |= run.Picker;
            SetStyle(ControlStyles.Selectable, hasPicker);
            TabStop = hasPicker;
            if (!hasPicker) pickerRect = RectangleF.Empty;
            Invalidate();
        }

        /// <summary>Where the system name sits, in screen coordinates, for placing the picker.</summary>
        public Rectangle PickerScreenBounds => RectangleToScreen(Rectangle.Round(pickerRect));

        bool OverPicker(Point p) => !pickerRect.IsEmpty && RectangleF.Inflate(pickerRect, F(6), F(2)).Contains(p);

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            bool over = OverPicker(e.Location);
            Cursor = over ? Cursors.Hand : Cursors.Default;
            if (over != pickerHot) { pickerHot = over; Invalidate(); }
        }

        bool pickerHot;

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); pickerHot = false; }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button == MouseButtons.Left && OverPicker(e.Location)) PickerClicked?.Invoke(this, EventArgs.Empty);
        }

        protected override void OnClick(EventArgs e)
        {
            // Mouse clicks are handled in OnMouseUp; this is the keyboard path from DrawnControl.
            if (!pickerRect.IsEmpty && !(e is MouseEventArgs)) PickerClicked?.Invoke(this, EventArgs.Empty);
        }

        protected override void Draw(Graphics g)
        {
            var font = Font(Px, true);
            float lineHeight = F(LineHeight);

            // Lay out first so the hover background can go behind the picker.
            var placed = new List<(Run run, float x, float top, float width)>();
            pickerRect = RectangleF.Empty;
            for (int i = 0; i < lines.Count; i++)
            {
                float x = 0, top = i * lineHeight;
                foreach (var run in lines[i])
                {
                    float start = x;
                    if (run.Logo != null) x += F(LogoSize + LogoGap);
                    x += TextKit.Width(run.Text, font, Tracking);
                    if (run.Picker) x += F(6 + ChevronSize);
                    placed.Add((run, start, top, x - start));
                    if (run.Picker) pickerRect = new RectangleF(start, top, x - start, lineHeight + F(3));
                    x += F(WordGap);
                }
            }

            if (pickerHot && !pickerRect.IsEmpty)
                FillRounded(g, FillHover, RectangleF.Inflate(pickerRect, F(8), F(2)), F(10));
            if (Focused && ShowFocusCues && !pickerRect.IsEmpty)
                StrokeRounded(g, Color.FromArgb(120, Ink), RectangleF.Inflate(pickerRect, F(8), F(2)), F(10), F(2));

            foreach (var (run, x, top, width) in placed)
            {
                float textX = x;
                if (run.Logo != null)
                {
                    DrawImageFit(g, run.Logo, new RectangleF(x, top + (lineHeight - F(LogoSize)) / 2, F(LogoSize), F(LogoSize)));
                    textX += F(LogoSize + LogoGap);
                }
                float baseline = TextKit.BaselineIn(font, top, lineHeight);
                TextKit.Draw(g, run.Text, font, run.Color, textX, baseline, Tracking);
                if (!run.Picker) continue;

                float cx = x + width - F(ChevronSize) / 2, cy = top + lineHeight / 2 + F(3);
                using (var pen = new Pen(Ink, F(2.2f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                    g.DrawLines(pen, new[] { new PointF(cx - F(5), cy - F(2.5f)), new PointF(cx, cy + F(2.5f)), new PointF(cx + F(5), cy - F(2.5f)) });
                using (var brush = new SolidBrush(run.Underline))
                    g.FillRectangle(brush, x, top + lineHeight + F(1), width, F(2));
            }
        }
    }
}
