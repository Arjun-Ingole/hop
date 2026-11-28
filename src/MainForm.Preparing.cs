using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Management.Automation;
using System.Threading.Tasks;
using static Hop.Theme;

namespace Hop
{
    sealed partial class MainForm
    {
        // --- Working ------------------------------------------------------------------------

        /// <summary>
        /// Shows a long action in progress: the sentence says what is happening, a line
        /// moves underneath, the note follows the engine's status, and the buttons go away.
        /// </summary>
        void BeginWork(Run[][] lines, string firstNote) => BeginWork(lines, firstNote, readsOnly: false);

        void BeginWork(Run[][] lines, string firstNote, bool readsOnly)
        {
            busy = working = true;
            reading = readsOnly;
            // Closing is refused while the disk changes, so a shutdown should say why it's waiting.
            SetShutdownBlock(!readsOnly);
            closeRefused = null;
            Native.KeepAwake(true);
            engine?.ResetProgress();
            shownStatus = null;
            Arrange(lines, firstNote, Secondary, busyLine, 28);
            Footer(null, null, null, null);
            poll.Start();
        }

        void EndWork()
        {
            poll.Stop();
            busy = working = reading = false;
            SetShutdownBlock(false);
            Native.KeepAwake(false);
        }

        /// <summary>The same for work that only reads the PC, which closing hop can simply stop.</summary>
        void BeginReading(Run[][] lines, string firstNote) => BeginWork(lines, firstNote, readsOnly: true);

        const string ShutdownReason = "hop is changing the disk. Let it finish first.";
        bool shutdownBlocked;

        /// <summary>
        /// What Windows says about hop if a shutdown has to wait for it. Only while closing would be refused:
        /// reading, a download that can still stop, and hop's own restarts must never hold one up.
        /// </summary>
        void SetShutdownBlock(bool on)
        {
            if (on && engine != null && engine.RoomRestarting) on = false;
            if (on == shutdownBlocked || !IsHandleCreated) return;
            shutdownBlocked = on;
            if (on) Native.BlockShutdown(Handle, ShutdownReason);
            else Native.AllowShutdown(Handle);
        }

        Native.TaskbarState taskbarState = Native.TaskbarState.NoProgress;
        int taskbarPermille = -1;

        /// <summary>Only tells the taskbar what's changed: the poll asks many times a second.</summary>
        void ShowTaskbar(Native.TaskbarState state, double fraction = 0)
        {
            int permille = (int)Math.Round(fraction * 1000);
            if (state == taskbarState && (permille == taskbarPermille || state == Native.TaskbarState.NoProgress || state == Native.TaskbarState.Indeterminate)) return;
            if (!IsHandleCreated) return;
            taskbarState = state;
            taskbarPermille = permille;
            Native.TaskbarProgress(Handle, state, fraction);
        }

        void ShowWorkingStatus()
        {
            string status = engine?.Status;
            if (string.IsNullOrEmpty(status) || status == shownStatus) return;
            shownStatus = status;
            note.Set(status.Replace("...", "…"), Secondary);
            busyLine.Top = note.Bottom + S(28);
        }

        // --- Preparing -------------------------------------------------------------------

        async Task InstallAsync()
        {
            var system = Current;
            engine.Log.Clear();
            engine.ResetProgress();
            engine.ClearLastError();
            engine.Sync["CleanupProblems"] = null;
            log.Clear();
            busy = installing = true;
            closeRefused = null;
            cancelling = false;
            installStarted = DateTime.Now;
            showingLog = false;
            drive.Progress = 0;
            UpdatePreparing();
            poll.Start();
            // A download can take an hour, and a PC that sleeps through it, or through the shrink, stops it.
            Native.KeepAwake(true);
            try
            {
                var download = DownloadSpot;
                await engine.InstallAsync(selected?.Id ?? "custom", isoPath, linuxGB, target.Id, download == null || download.IsDefault ? "" : download.Letter, fullDisk);
                if (cancelling) throw new PipelineStoppedException();
                // Its last line. Whatever ended it early and silently, this says it didn't get there.
                bool finished = engine.Stage == LastStage;
                // What hop knows is from before the install, and Undo has to say what it changed.
                bool reread = false;
                try
                {
                    startup = await engine.GetStartupInfoAsync();
                    target = startup.Drives.FirstOrDefault(d => d.Id == target.Id) ?? WindowsDrive;
                    reread = true;
                }
                catch (Exception) { }
                EndPreparing();
                // The engine can end with nothing thrown, so only what's on the PC says it worked.
                if (!finished || !reread || (startup.Status != "ready" && startup.Status != "installed"))
                {
                    string what = !reread ? "hop can't tell whether it finished, so it won't say it's ready."
                        : startup.Status == "none" ? "Your disk wasn't changed."
                        : "It left some changes behind, which Clean up removes.";
                    await ShowFailureAsync($"hop stopped before {system.Name} was ready. {what} {engine.LastError}".Trim());
                    return;
                }
                prepared = system;
                await ShowReadyAsync();
            }
            catch (Exception ex)
            {
                EndPreparing();
                if (cancelling || ex is PipelineStoppedException) { ShowChoose(); return; }
                await ShowFailureAsync(Describe(ex));
            }
            finally
            {
                if (!working) Native.KeepAwake(false);
            }
        }

        void EndPreparing()
        {
            poll.Stop();
            busy = installing = false;
            SetShutdownBlock(false);
            ShowTaskbar(Native.TaskbarState.NoProgress);
            samples.Clear();
        }

        const double GB = 1024.0 * 1024 * 1024;   // as the engine counts them

        void UpdatePreparing()
        {
            var system = Current;
            int stage = Math.Min(engine.Stage, StageVerbs.Length - 1);
            long bytes = engine.Bytes, total = engine.TotalBytes;
            bool counting = total > 0 && (stage == 1 || stage == 4);
            string speed = counting ? Speed(stage, bytes, total) : null;
            if (!counting) samples.Clear();
            // From Making room on, the disk is changing and Cancel can't win, so a shutdown has to wait.
            SetShutdownBlock(!cancelling && stage >= 3);

            var weights = isoPath == null ? DownloadWeights : IsoWeights;
            float done = 0, sum = weights.Sum();
            for (int i = 0; i < stage; i++) done += weights[i];
            if (engine.Percent >= 0) done += weights[stage] * engine.Percent / 100f;
            int overall = (int)Math.Min(99, Math.Round(100 * done / sum));

            ConfigureDrive(DriveMode.Progress, system);
            drive.Status = overall + "%";
            drive.Progress = overall / 100f;
            // Nothing is known at the very start; after that the bar moves with the same total as the drive.
            if (overall == 0 && engine.Percent < 0) ShowTaskbar(Native.TaskbarState.Indeterminate);
            else ShowTaskbar(Native.TaskbarState.Normal, overall / 100.0);
            Arrange(new[]
            {
                new[] { Run.Gray("Preparing"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
                counting
                    ? new[] { Run.Gray(StageVerbs[stage] + ","), Run.Black($"{bytes / GB:0.0} of {total / GB:0.0} GB") }
                    : new[] { Run.Gray(StageVerbs[stage]) },
            }, closeRefused ?? PreparingNote(stage, counting, speed), closeRefused != null ? Danger : Secondary, drive, 64);

            SyncLog();

            // Cancel appears where Start was, so a second click on Start mustn't land on it.
            bool canCancel = stage <= 2 && !cancelling && (DateTime.Now - installStarted).TotalMilliseconds >= CancelAppearsAfterMilliseconds;
            Footer(showingLog ? "Hide details" : "Show details", ToggleLog, null, null,
                canCancel ? "Cancel" : null, canCancel ? (Action)CancelInstall : null);
        }

        /// <summary>
        /// The step, and what the engine is doing in it, so a long check never looks stuck. While bytes are
        /// counted the sentence already has them, so it's the speed instead. Always one line.
        /// </summary>
        string PreparingNote(int stage, bool counting, string speed)
        {
            string step = $"Step {stage + 1} of {StageVerbs.Length}";
            string detail = counting ? speed : Calm(engine.Status);
            // The status often only repeats the sentence: "Checking this PC...".
            if (string.IsNullOrEmpty(detail) || string.Equals(detail.TrimEnd('…', '.'), StageVerbs[stage], StringComparison.OrdinalIgnoreCase))
                return $"{step}. You can keep using your PC while this runs.";
            return TextKit.Ellipsize($"{step} · {detail}", Theme.Font(15), note.Width);
        }

        static string Calm(string status)
        {
            status = (status ?? "").Trim().Replace("...", "…");
            return status.EndsWith("…") ? status.TrimEnd('…').TrimEnd() + "…" : status;
        }

        // --- Speed ----------------------------------------------------------------------------

        const double SpeedWindowSeconds = 10, SpeedAfterSeconds = 3, EtaAfterSeconds = 6;
        readonly Queue<(double at, long bytes)> samples = new Queue<(double, long)>();
        readonly Stopwatch speedClock = Stopwatch.StartNew();
        int sampledStage = -1;
        double sampledSince;
        long sampledBytes;

        /// <summary>
        /// "12.3 MB/s · about 4 min left", from the last ten seconds, so a slow patch passes. Nothing
        /// until it has a few seconds to go on, and no time left while it's barely moving.
        /// </summary>
        string Speed(int stage, long bytes, long total)
        {
            double now = speedClock.Elapsed.TotalSeconds;
            // A new stage counts other bytes, and a retried download starts again from nothing.
            if (stage != sampledStage || samples.Count == 0 || bytes < sampledBytes)
            {
                samples.Clear();
                sampledStage = stage;
                sampledSince = now;
            }
            samples.Enqueue((now, bytes));
            sampledBytes = bytes;
            while (samples.Count > 2 && now - samples.Peek().at > SpeedWindowSeconds) samples.Dequeue();

            var first = samples.Peek();
            double span = now - first.at;
            if (now - sampledSince < SpeedAfterSeconds || span < SpeedAfterSeconds * 0.8) return null;
            double perSecond = (bytes - first.bytes) / span;
            if (perSecond < 32 * 1024) return null;

            string rate = perSecond >= 1024 * 1024 ? $"{perSecond / (1024 * 1024):0.0} MB/s" : $"{perSecond / 1024:0} KB/s";
            if (now - sampledSince < EtaAfterSeconds) return rate;
            double left = Math.Max(0, total - bytes) / perSecond;
            return $"{rate} · {TimeLeft(left)}";
        }

        static string TimeLeft(double seconds)
        {
            if (seconds < 60) return "less than a minute left";
            int minutes = (int)Math.Ceiling(seconds / 60);
            if (minutes < 60) return $"about {minutes} min left";
            int hours = minutes / 60, rest = minutes % 60 / 5 * 5;
            return rest == 0 ? $"about {hours} h left" : $"about {hours} h {rest} min left";
        }

        const int LastStage = 6;   // the engine's Set-Stage after everything has worked
        const int CancelAppearsAfterMilliseconds = 1500;
        DateTime installStarted;
        int logShown;

        void SyncLog()
        {
            if (log.TextLength == 0) logShown = 0;
            while (logShown < engine.Log.Count)
                log.AppendText(engine.Log[logShown++] + Environment.NewLine);
        }

        void ToggleLog()
        {
            showingLog = !showingLog;
            UpdatePreparing();
        }

        void CancelInstall()
        {
            // Too late if the disk is already changing, and the button goes on the next update.
            if (!engine.TryCancel()) return;
            engine.Log.Add($"{DateTime.Now:HH:mm:ss}  Cancel clicked.");
            cancelling = true;
            StopDownload();
            engine.Stop();
        }

        void StopDownload()
        {
            if (!(engine?.Sync["ChildPid"] is int pid)) return;
            try { Process.GetProcessById(pid).Kill(); } catch { }
        }

        async Task ShowFailureAsync(string message)
        {
            var system = Current;
            SyncLog();
            // Red on the taskbar for a minimized hop, until another screen replaces this one.
            ShowTaskbar(Native.TaskbarState.Error, 1);
            int held = HoldScreen();
            note.Set("That didn't work. Checking what's left on this PC…", Secondary);
            // Not being able to look isn't the same as nothing being there, and Clean up is safe either way.
            bool changed = true;
            try
            {
                await ReloadAsync();
                changed = startup.Status != "none";
            }
            catch { }
            if (!ReleaseScreen(held)) return;

            var left = engine.CleanupProblems;
            if (left.Length > 0) message += " " + string.Join(" ", left);
            Arrange(new[]
            {
                new[] { Run.Gray("Couldn't prepare"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
                new[] { Run.Red("Something went wrong.") },
            }, message, Secondary, log, 40);
            ShowTaskbar(Native.TaskbarState.Error, 1);
            // The engine undoes its own changes after a failure; if something is still left, offer to clean up.
            if (changed) Footer(ReportLink, () => _ = CopyReportAsync(), "Clean up", ShowLeftover);
            else if (startup.SecureBoot && message.Contains("Secure Boot")) Footer(ReportLink, () => _ = CopyReportAsync(), "Turn off Secure Boot", () => _ = ShowTurnOffSecureBootAsync(), "Try again", ShowChoose);
            else Footer(ReportLink, () => _ = CopyReportAsync(), "Try again", ShowChoose);
        }
    }
}
