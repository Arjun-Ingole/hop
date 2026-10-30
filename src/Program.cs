using System;
using System.Drawing;
using System.Windows.Forms;

namespace Hop
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var g = Graphics.FromHwnd(IntPtr.Zero))
                Theme.Scale = g.DpiX / 96f;
            Theme.LoadFonts();
            Application.Run(new MainForm());
        }
    }
}
