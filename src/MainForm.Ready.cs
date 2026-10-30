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
        // --- Ready ---------------------------------------------------------------------------

        async Task ShowReadyAsync()
        {
            InstallSteps installSteps;
            try { installSteps = await engine.GetStepsAsync(); }
            catch (Exception ex) { ShowBlocked(Describe(ex)); return; }

            steps.Set(installSteps.Steps, installSteps.Notes);
            Arrange(new[]
            {
                new[] { new Run { Text = prepared.Name, Color = Ink, Logo = Logo(prepared.Logo) }, Run.Gray("is ready.") },
            }, "Restart to open its installer. These are the choices to make there.", Secondary, steps, 40);
            Footer("Undo changes", () => ShowUndo(() => _ = ShowReadyAsync()), "Restart now", () => _ = RestartAsync(),
                "Later", Close, Secondary);
        }

        async Task RestartAsync()
        {
            primary.Enabled = false;
            try
            {
                await engine.RestartIntoInstallerAsync();
            }
            catch (Exception ex)
            {
                note.Set(Describe(ex) + " You can also restart yourself and tap F11 while the PC starts, then choose the installer.", Danger);
                primary.Enabled = true;
            }
        }

        // --- Undo ----------------------------------------------------------------------------

        void ShowUndo(Action goBack)
        {
            removeAll.Selected = removeInstaller.Selected = false;
            removeAll.Enabled = removeInstaller.Enabled = true;
            Arrange(new[] { new[] { Run.Gray("Remove"), Run.Black("hop's changes") } },
                "Choose what's true for this PC.", Secondary, removeAll, 32);
            Footer("Back", goBack, "Remove", null);
        }

        void PickUndo(OptionRow row)
        {
            removeAll.Selected = row == removeAll;
            removeInstaller.Selected = row == removeInstaller;
            bool installerOnly = row == removeInstaller;
            primary.Enabled = true;
            onPrimary = () => _ = CleanupAsync(installerOnly, () =>
            {
                Arrange(new[] { new[] { Run.Black("Changes removed.") } },
                    installerOnly ? "The installer and its startup entry are gone." : "The space is back on drive C:.", Secondary, null, 0);
                Footer("Start over", ShowChoose, "Close", Close);
            });
        }

        void ShowBlocked(string message)
        {
            Arrange(new[] { new[] { Run.Black("hop can't continue.") } }, message, Secondary, null, 0);
            Footer(null, null, "Close", Close);
        }
    }
}
