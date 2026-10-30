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
        // --- Another Linux (Pond) ----------------------------------------------------------

        void ShowRemoveOther()
        {
            string name = startup.OtherName;
            Arrange(new[]
            {
                new[] { Run.Gray("Remove"), Run.Black(name) },
                new[] { Run.Gray("and free"), Run.Black(startup.OtherGB + " GB") },
            }, $"This deletes {name} and everything stored in it, and takes it out of the startup menu. Windows and your files stay.",
                Secondary, null, 0);
            Footer("Back", ShowChoose, "Remove " + name, () => _ = RemoveOtherAsync());
        }

        async Task RemoveOtherAsync()
        {
            string name = startup.OtherName;
            int freed = startup.OtherGB;
            BeginWork(new[] { new[] { Run.Gray("Removing"), Run.Black(name) } }, "Starting…");
            try
            {
                await engine.RemoveOtherSystemAsync();
                startup = await engine.GetStartupInfoAsync();
                EndWork();
                Arrange(new[] { new[] { Run.Black(name), Run.Gray("is gone.") } },
                    $"{freed} GB is free now. Use it for Linux, or give it back to Windows.", Secondary, null, 0);
                Footer(null, null, "Use it for Linux", ShowChoose, "Give it to Windows", () => _ = ExpandWindowsAsync());
            }
            catch (Exception ex)
            {
                EndWork();
                try { startup = await engine.GetStartupInfoAsync(); } catch { }
                Arrange(new[] { new[] { Run.Gray("Couldn't remove"), Run.Black(name) } }, Describe(ex), Danger, null, 0);
                Footer("Back", ShowChoose, "Try again", startup.OtherGB > 0 ? () => _ = RemoveOtherAsync() : (Action)null);
            }
        }

        async Task ExpandWindowsAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Giving the space to"), Run.Black("Windows") } }, "Starting…");
            try
            {
                await engine.ExpandWindowsAsync();
                startup = await engine.GetStartupInfoAsync();
                EndWork();
                Arrange(new[] { new[] { Run.Black("Windows"), Run.Gray("has the space back.") } },
                    $"Drive C: is {startup.WindowsGB} GB now.", Secondary, null, 0);
                Footer("Start over", ShowChoose, "Close", Close);
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't give the space to"), Run.Black("Windows") } }, Describe(ex), Danger, null, 0);
                Footer(null, null, "Use it for Linux", ShowChoose, "Try again", () => _ = ExpandWindowsAsync());
            }
        }
    }
}
