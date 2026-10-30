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
            if (startup.Status == "ready" || startup.Status == "installed")
            {
                prepared = catalog.FirstOrDefault(d => d.Id == startup.PreparedId) ?? new Distro
                {
                    Id = "custom",
                    Name = string.IsNullOrWhiteSpace(startup.PreparedDistro) ? "Linux" : startup.PreparedDistro,
                    Color = Ink,
                };
                if (startup.Status == "installed") ShowInstalled();
                else await ShowReadyAsync();
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
    }
}
