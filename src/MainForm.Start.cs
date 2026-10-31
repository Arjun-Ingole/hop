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
                if (startup.RoomPhase == "continue")
                {
                    if (await engine.CompleteMakeRoomAsync())
                        roomLetter = string.IsNullOrEmpty(startup.RoomLetter) ? WindowsLetter : startup.RoomLetter;
                    startup = await engine.GetStartupInfoAsync();
                }
                else if (startup.RoomPhase == "restore")
                {
                    await engine.RestoreRoomSettingsAsync();
                }
                await ChooseFirstTargetAsync();
            }
            catch (Exception ex)
            {
                EndWork();
                ShowBlocked(Describe(ex));
                return;
            }
            EndWork();

            selected = catalog[0];
            int max = MaxLinuxGB;
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
            string text = "It left partitions or a startup entry on this PC. Clean them up to start fresh. Windows and your files stay.";
            if (startup.StateDiskMissing) text = "It was using a drive that isn't connected now. If you unplugged it, plug it back in and open hop again. Otherwise, clean up to start fresh. Windows and your files stay.";
            Arrange(new[] { new[] { Run.Gray("An earlier attempt"), Run.Black("didn't finish.") } }, text, Secondary, null, 0);
            Footer(null, null, "Clean up", () => _ = CleanupAsync(false, afterwards: null));
        }

        /// <summary>Runs the clean-up, then shows a result or goes back to choosing.</summary>
        async Task CleanupAsync(bool installerOnly, Action afterwards)
        {
            BeginWork(new[] { new[] { Run.Gray("Cleaning up"), Run.Black("hop's changes") } }, "Starting…");
            try
            {
                await engine.CleanupAsync(installerOnly);
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't clean up"), Run.Black("everything") } }, Describe(ex), Danger, null, 0);
                Footer("Copy a bug report", () => _ = CopyReportAsync(), "Try again", () => _ = CleanupAsync(installerOnly, afterwards));
                return;
            }
            // It's done now, so a problem from here on, such as what stops a new install, isn't one to retry.
            try
            {
                await ReloadAsync();
            }
            catch (Exception ex)
            {
                EndWork();
                ShowBlocked("hop's changes are removed. " + Describe(ex));
                return;
            }
            EndWork();
            if (afterwards != null) afterwards();
            else ShowChoose();
        }
    }
}
