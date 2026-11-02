using System;
using System.Linq;
using System.Threading.Tasks;
using static Hop.Theme;

namespace Hop
{
    sealed partial class MainForm
    {
        // --- Startup --------------------------------------------------------------------

        async Task StartAsync()
        {
            BeginReading(new[] { new[] { Run.Gray("Checking"), Run.Black("this PC") } }, "Looking at the drive and the startup menu.");
            try
            {
                engine = await Task.Run(() => new Engine());
                catalog = await Task.Run(() => engine.GetCatalog());
                startup = await engine.GetStartupInfoAsync();
                if (startup.RoomPhase == "continue")
                {
                    BeginWork(new[] { new[] { Run.Black("Moving files"), Run.Gray("out of the way") } }, "Starting…");
                    Footer("You can keep using your PC while this runs.", null, null, null);
                    if (await engine.CompleteMakeRoomAsync())
                        roomLetter = string.IsNullOrEmpty(startup.RoomLetter) ? WindowsLetter : startup.RoomLetter;
                    else
                        roomFailed = true;
                    startup = await engine.GetStartupInfoAsync();
                }
                else if (startup.RoomPhase == "restore")
                {
                    reading = false;
                    await engine.RestoreRoomSettingsAsync();
                }
                if (startup.RoomNotice != null)
                {
                    EndWork();
                    Arrange(new[] { new[] { Run.Gray("Make room"), Run.Black("needs a look.") } }, startup.RoomNotice, Secondary, null, 0);
                    Footer(null, null, "Continue", () => _ = AfterRoomNoticeAsync());
                    return;
                }
                reading = true;
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

        async Task AfterRoomNoticeAsync()
        {
            BeginReading(new[] { new[] { Run.Gray("Checking"), Run.Black("this PC") } }, "Looking at the drive and the startup menu.");
            try
            {
                await engine.ClearRoomNoticeAsync();
                await ChooseFirstTargetAsync();
            }
            catch (Exception ex)
            {
                EndWork();
                ShowBlocked(Describe(ex));
            }
        }

        async Task ShowStartScreenAsync()
        {
            if (startup.Status == "ready" || startup.Status == "installed" || startup.Status == "unsure")
            {
                prepared = catalog.FirstOrDefault(d => d.Id == startup.PreparedId) ?? new Distro
                {
                    Name = string.IsNullOrWhiteSpace(startup.PreparedDistro) ? "Linux" : startup.PreparedDistro,
                };
                if (startup.Status == "installed") ShowInstalled();
                else if (startup.Status == "unsure") ShowUnsure();
                else await ShowReadyAsync();
            }
            else if (startup.Status == "leftover") ShowLeftover();
            else ShowChoose();
        }

        // --- Leftovers ---------------------------------------------------------------------

        void ShowLeftover()
        {
            string text = "Clean up deletes these, and everything on them, to start fresh. Windows and your other files stay.";
            if (startup.StateDiskMissing) text = "It was using a drive that isn't connected now. If you unplugged it, plug it back in and open hop again. Otherwise, clean up deletes these to start fresh.";
            var items = startup.Leftovers ?? new string[0];
            if (items.Length > 0) steps.Set(items, null);
            Arrange(new[] { new[] { Run.Gray("An earlier attempt"), Run.Black("left something behind.") } }, text, Secondary, items.Length > 0 ? steps : null, 24);
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
                Footer(ReportLink, () => _ = CopyReportAsync(), "Try again", () => _ = CleanupAsync(installerOnly, afterwards));
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
            // Only the PC says it all went. With Linux staying, its partitions are meant to.
            var problems = engine.CleanupProblems.ToList();
            if (startup.Status != "none" && !installerOnly) problems.AddRange(startup.Leftovers ?? new string[0]);
            if (problems.Count > 0)
            {
                steps.Set(problems.ToArray(), null);
                Arrange(new[] { new[] { Run.Gray("Couldn't clean up"), Run.Black("everything") } }, "These are still here. Everything else is gone.", Danger, steps, 24);
                Footer(ReportLink, () => _ = CopyReportAsync(), "Try again", () => _ = CleanupAsync(installerOnly, afterwards), "Close", Close);
                return;
            }
            if (afterwards != null) afterwards();
            else ShowChoose();
        }
    }
}
