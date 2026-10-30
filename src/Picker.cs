using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using static Hop.Theme;

namespace Hop
{
    /// <summary>The list of systems that drops down from the sentence.</summary>
    sealed class SystemPicker : ToolStripDropDown
    {
        readonly PickerList list;

        public event Action<Distro> Picked;
        public event Action IsoRequested;

        public SystemPicker(IList<Distro> systems, Distro current)
        {
            list = new PickerList(systems, current);
            list.Picked += d => { Close(); Picked?.Invoke(d); };
            list.IsoRequested += () => { Close(); IsoRequested?.Invoke(); };
            var host = new ToolStripControlHost(list) { Margin = Padding.Empty, Padding = Padding.Empty, AutoSize = false, Size = list.Size };
            Padding = Padding.Empty;
            AutoSize = false;
            Size = list.Size;
            DropShadowEnabled = true;
            Renderer = new BorderlessRenderer();
            Items.Add(host);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.RoundCorners(Handle, small: true);
        }

        protected override void OnOpened(EventArgs e)
        {
            base.OnOpened(e);
            list.Focus();
        }

        sealed class BorderlessRenderer : ToolStripRenderer
        {
            protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { }
            protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) => e.Graphics.Clear(Background);
        }
    }

    sealed class PickerList : DrawnControl
    {
        const float Pad = 6, ItemHeight = 42, FooterHeight = 38, Width_ = 340;
        const int VisibleItems = 8;

        readonly IList<Distro> systems;
        readonly Distro current;
        int hot = -1, scroll;
        bool footerHot;

        public event Action<Distro> Picked;
        public event Action IsoRequested;

        public PickerList(IList<Distro> systems, Distro current)
        {
            MakeClickable();
            Cursor = Cursors.Default;
            this.systems = systems;
            this.current = current;
            int visible = Math.Min(VisibleItems, systems.Count);
            Size = new Size(S(Width_), S(Pad * 2 + ItemHeight * visible + 5 + FooterHeight));
            hot = Math.Max(0, systems.IndexOf(current));
            EnsureVisible(hot);
        }

        int Rows => Math.Min(VisibleItems, systems.Count);
        int MaxScroll => Math.Max(0, systems.Count - VisibleItems);
        float ListTop => F(Pad);
        float FooterTop => F(Pad + ItemHeight * Rows + 5);

        int IndexAt(Point p)
        {
            if (p.Y < ListTop || p.Y >= ListTop + F(ItemHeight) * Rows) return -1;
            return scroll + (int)((p.Y - ListTop) / F(ItemHeight));
        }

        void EnsureVisible(int index)
        {
            if (index < scroll) scroll = index;
            if (index >= scroll + VisibleItems) scroll = index - VisibleItems + 1;
            scroll = Math.Max(0, Math.Min(MaxScroll, scroll));
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int index = IndexAt(e.Location);
            bool footer = e.Y >= FooterTop;
            if (index != hot && index >= 0 || footer != footerHot)
            {
                if (index >= 0) hot = index;
                footerHot = footer;
                Invalidate();
            }
            Cursor = index >= 0 || footer ? Cursors.Hand : Cursors.Default;
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button != MouseButtons.Left) return;
            int index = IndexAt(e.Location);
            if (index >= 0 && index < systems.Count) Picked?.Invoke(systems[index]);
            else if (e.Y >= FooterTop) IsoRequested?.Invoke();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            scroll = Math.Max(0, Math.Min(MaxScroll, scroll - Math.Sign(e.Delta)));
            Invalidate();
        }

        protected override bool IsInputKey(Keys keyData) => keyData == Keys.Up || keyData == Keys.Down || base.IsInputKey(keyData);

        protected override void OnKeyDown(KeyEventArgs e)
        {
            switch (e.KeyCode)
            {
                case Keys.Up: hot = Math.Max(0, hot - 1); footerHot = false; break;
                case Keys.Down:
                    if (hot >= systems.Count - 1) footerHot = true;
                    else hot++;
                    break;
                case Keys.Enter:
                case Keys.Space:
                    if (footerHot) IsoRequested?.Invoke();
                    else if (hot >= 0) Picked?.Invoke(systems[hot]);
                    return;
                default: return;
            }
            EnsureVisible(hot);
            e.Handled = true;
            Invalidate();
        }

        protected override void Draw(Graphics g)
        {
            var name = Font(15, true);
            var note = Font(13);
            float itemH = F(ItemHeight), pad = F(Pad);

            var saved = g.Clip;
            g.SetClip(new RectangleF(0, ListTop, Width, itemH * Rows));
            for (int i = scroll; i < Math.Min(systems.Count, scroll + VisibleItems); i++)
            {
                var d = systems[i];
                var row = new RectangleF(pad, ListTop + (i - scroll) * itemH, Width - 2 * pad, itemH);
                bool selected = d.Id == current?.Id;
                if (selected) FillRounded(g, Fill, row, F(8));
                else if (i == hot && !footerHot) FillRounded(g, FillHover, row, F(8));

                float x = row.X + F(12);
                DrawImageFit(g, Theme.Logo(d.Logo), new RectangleF(x, row.Y + (itemH - F(22)) / 2, F(22), F(22)));
                x += F(22 + 12);
                float baseline = TextKit.BaselineIn(name, row.Y, itemH);
                float checkLeft = row.Right - F(12 + 16);
                float noteWidth = TextKit.Width(d.Note, note);
                TextKit.Draw(g, TextKit.Ellipsize(d.Name, name, checkLeft - F(12) - noteWidth - F(12) - x), name, Ink, x, baseline);
                TextKit.Draw(g, d.Note, note, Tertiary, checkLeft - F(12) - noteWidth, TextKit.BaselineIn(note, row.Y, itemH));
                if (selected)
                {
                    float cx = checkLeft + F(9), cy = row.Y + itemH / 2;
                    using (var pen = new Pen(Ink, F(1.8f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                        g.DrawLines(pen, new[] { new PointF(cx - F(4.5f), cy + F(0.2f)), new PointF(cx - F(1.4f), cy + F(3.2f)), new PointF(cx + F(4.5f), cy - F(3.2f)) });
                }
            }
            g.Clip = saved;

            if (MaxScroll > 0)
            {
                float trackH = itemH * Rows - F(8), thumbH = trackH * VisibleItems / systems.Count;
                float thumbY = ListTop + F(4) + (trackH - thumbH) * scroll / MaxScroll;
                FillRounded(g, Hairline, new RectangleF(Width - F(6), thumbY, F(3), thumbH), F(1.5f));
            }

            using (var pen = new Pen(DriveFree)) g.DrawLine(pen, pad, FooterTop - F(1), Width - pad, FooterTop - F(1));
            var footer = new RectangleF(pad, FooterTop, Width - 2 * pad, F(FooterHeight));
            if (footerHot) FillRounded(g, FillHover, RectangleF.Inflate(footer, 0, -F(3)), F(8));
            TextKit.Draw(g, "Use an ISO file…", Font(14, true), Ink, footer.X + F(12), TextKit.BaselineIn(Font(14, true), footer.Y, footer.Height));

            using (var border = new Pen(Color.FromArgb(28, 0, 0, 0))) g.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
        }
    }
}
