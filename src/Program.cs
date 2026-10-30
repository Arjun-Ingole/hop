using System;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Hop
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            // Two copies changing the same disk would be a disaster.
            using (var mutex = new Mutex(true, @"Global\hop-installer", out bool first))
            {
                if (!first)
                {
                    MessageBox.Show("hop is already running.", "hop", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += (s, e) => ReportCrash(e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => ReportCrash(e.ExceptionObject as Exception);
                TaskScheduler.UnobservedTaskException += (s, e) => { LogCrash(e.Exception); e.SetObserved(); };

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (var g = Graphics.FromHwnd(IntPtr.Zero))
                    Theme.Scale = g.DpiX / 96f;
                Theme.LoadFonts();
                Application.Run(new MainForm());
            }
        }

        static void ReportCrash(Exception ex)
        {
            string path = LogCrash(ex);
            MessageBox.Show($"hop ran into a problem it didn't expect.\n\n{ex?.Message}\n\nDetails are in {path}", "hop", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        static string LogCrash(Exception ex)
        {
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "hop", "logs");
            string path = Path.Combine(folder, "crash.log");
            try
            {
                Directory.CreateDirectory(folder);
                File.AppendAllText(path, $"{DateTime.Now:s}{Environment.NewLine}{ex}{Environment.NewLine}{Environment.NewLine}");
            }
            catch { }
            return path;
        }
    }
}
