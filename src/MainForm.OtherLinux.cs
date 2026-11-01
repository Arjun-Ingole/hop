using System;
using System.Linq;
using System.Threading.Tasks;
using static Hop.Theme;

namespace Hop
{
    sealed partial class MainForm
    {
        // --- Another Linux (Pond) ----------------------------------------------------------

        /// <summary>The startup entries left alone, because they may be how another system starts.</summary>
        static string KeptNote(string[] kept) => kept != null && kept.Length > 0
            ? $" hop can't tell whether {string.Join(", ", kept)} in the startup menu belongs to this Linux, so that stays. If it's left over, it may stop at a prompt when chosen."
            : "";

        void ShowRemoveOther()
        {
            string name = startup.OtherName;
            string[] partitions = startup.OtherPartitions ?? new string[0];
            steps.Set(partitions, new[] { "Back up anything on them that you want to keep." });
            Arrange(new[]
            {
                new[] { Run.Gray("Remove"), Run.Black(name) },
                new[] { Run.Gray("and free"), Run.Black(startup.OtherGB + " GB") },
            }, $"This deletes every Linux partition on this disk, and everything stored on them, even if another system or your files are there. It also takes {name} out of the startup menu. Windows stays.{KeptNote(startup.OtherKept)}",
                Secondary, steps, 12);
            Footer("Back", ShowChoose, partitions.Length > 1 ? $"Delete {partitions.Length} partitions" : "Remove " + name, () => _ = RemoveOtherAsync());
        }

        async Task RemoveOtherAsync()
        {
            string name = startup.OtherName, selection = startup.OtherSelection;
            int freed = startup.OtherGB;
            bool onWindowsDisk = startup.OtherOnWindowsDisk;
            string kept = KeptNote(startup.OtherKept);
            BeginWork(new[] { new[] { Run.Gray("Removing"), Run.Black(name) } }, "Starting…");
            Exception failed = null;
            try { await engine.RemoveOtherSystemAsync(selection); }
            catch (Exception ex) { failed = ex; }
            // Reading the PC again is its own step: failing at that says nothing about the removal.
            bool looked = true;
            try { await ReloadAsync(); }
            catch (Exception) { looked = false; }
            EndWork();

            bool gone = looked && startup.OtherSelection != selection;
            if (!gone)
            {
                string why = failed != null ? Describe(failed)
                    : looked ? "The partitions are still there, and Windows gave no reason."
                    : "hop can't tell whether they went. Open hop again to see.";
                Arrange(new[] { new[] { Run.Gray("Couldn't remove"), Run.Black(name) } }, why, Danger, null, 0);
                Footer("Back", ShowChoose, "Try again", looked && startup.OtherGB > 0 ? () => _ = RemoveOtherAsync() : (Action)null);
                return;
            }
            string partly = failed == null ? "" : $" Its partitions are gone, but hop couldn't finish tidying up: {Describe(failed)}";
            var windows = startup.Drives.FirstOrDefault(d => d.IsWindows);
            if (onWindowsDisk && windows != null && windows.TailFreeGB > 0)
            {
                Arrange(new[] { new[] { Run.Black(name), Run.Gray("is gone.") } },
                    $"{freed} GB is free now. Use it for Linux, or give it back to Windows.{kept}{partly}", Secondary, null, 0);
                target = windows;
                Footer(null, null, "Use it for Linux", ShowChoose, "Give it to Windows", () => _ = ExpandWindowsAsync());
            }
            else
            {
                Arrange(new[] { new[] { Run.Black(name), Run.Gray("is gone.") } }, $"{freed} GB is free now on that disk.{kept}{partly}", Secondary, null, 0);
                // It isn't next to any drive, so Linux can only have it as free space.
                var gap = startup.Drives.Where(d => d.IsFreeSpace).OrderByDescending(d => d.UsableGB).FirstOrDefault();
                if (onWindowsDisk && gap != null) target = gap;
                Footer(null, null, "Done", ShowChoose);
            }
        }

        async Task ExpandWindowsAsync()
        {
            string id = target.Id, title = target.Title, owner = target.IsWindows ? "Windows" : target.InSentence;
            string heading = target.IsWindows ? "Windows" : target.Title;
            int before = target.SizeGB;
            BeginWork(new[] { new[] { Run.Gray("Giving the space to"), Run.Black(owner) } }, "Starting…");
            Exception failed = null;
            try { await engine.ExpandWindowsAsync(id); }
            catch (Exception ex) { failed = ex; }
            bool looked = true;
            try { await ReloadAsync(); }
            catch (Exception) { looked = false; }
            EndWork();

            var row = looked ? startup.Drives.FirstOrDefault(d => d.Id == id) : null;
            if (failed == null && row != null && row.SizeGB > before)
            {
                Arrange(new[] { new[] { Run.Black(heading), Run.Gray("has the space back.") } }, $"{title} is {row.SizeGB} GB now.", Secondary, null, 0);
                Footer("Start over", ShowChoose, "Close", Close);
                return;
            }
            string why = failed != null ? Describe(failed)
                : row != null ? $"{title} is still {row.SizeGB} GB, and Windows gave no reason."
                : "hop can't tell whether it worked. Open hop again to see.";
            Arrange(new[] { new[] { Run.Gray("Couldn't give the space to"), Run.Black(owner) } }, why, Danger, null, 0);
            Footer(null, null, "Use it for Linux", ShowChoose, "Try again", () => _ = ExpandWindowsAsync());
        }
    }
}
