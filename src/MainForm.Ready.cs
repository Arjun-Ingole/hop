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
            if (startup.CameBack) { await ShowCameBackAsync(); return; }

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

        /// <summary>hop restarted the PC for the installer, and here is Windows again.</summary>
        async Task ShowCameBackAsync()
        {
            InstallSteps help;
            try { help = await engine.GetReturnedHelpAsync(); }
            catch (Exception ex) { ShowBlocked(Describe(ex)); return; }

            steps.Set(help.Steps, help.Notes);
            Arrange(new[]
            {
                new[] { new Run { Text = prepared.Name, Color = Ink, Logo = Logo(prepared.Logo) }, Run.Gray("didn't start.") },
            }, "The PC came back to Windows instead of the installer. Your setup is still here.", Secondary, steps, 32);
            Footer("Undo changes", () => ShowUndo(() => _ = ShowReadyAsync()), "Try again", () => _ = RestartAsync(),
                "Open BIOS", () => _ = OpenBiosAsync(), Secondary);
        }

        async Task RestartAsync()
        {
            primary.Enabled = secondary.Enabled = false;
            try
            {
                await engine.RestartIntoInstallerAsync();
            }
            catch (Exception ex)
            {
                note.Set(Describe(ex) + $" You can also restart yourself and tap {startup.BootKey} while the PC starts, then choose the installer.", Danger);
                primary.Enabled = secondary.Enabled = true;
            }
        }

        async Task OpenBiosAsync()
        {
            primary.Enabled = secondary.Enabled = false;
            try
            {
                await engine.RestartIntoFirmwareAsync();
            }
            catch (Exception ex)
            {
                note.Set(Describe(ex) + " Restart yourself and tap Delete, F2 or F10 while the PC starts.", Danger);
                primary.Enabled = secondary.Enabled = true;
            }
        }

        // --- Installed -------------------------------------------------------------------------

        /// <summary>Linux went in from the installer, which is now only taking up space.</summary>
        void ShowInstalled()
        {
            Arrange(new[]
            {
                new[] { new Run { Text = prepared.Name, Color = Ink, Logo = Logo(prepared.Logo) }, Run.Gray("is installed.") },
            }, "The installer is still on this drive and isn't needed any more. Remove it to free the space. Linux stays.", Secondary, null, 0);
            Footer(null, null, "Remove the installer", () => { int before = startup.WindowsGB; _ = CleanupAsync(true, () => ShowRemoved(true, before)); }, "Later", Close);
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
            onPrimary = () => { int before = startup.WindowsGB; _ = CleanupAsync(installerOnly, () => ShowRemoved(installerOnly, before)); };
        }

        /// <summary>Says what actually happened: C: may have grown, or the space may just be free.</summary>
        void ShowRemoved(bool installerOnly, int windowsGBBefore)
        {
            int grew = startup.WindowsGB - windowsGBBefore;
            string result = grew > 0 ? $"Drive C: is {grew} GB bigger."
                : installerOnly ? "The space it used is free, but Windows can't reach it from here."
                : "The space is free on this drive.";
            Arrange(new[] { new[] { Run.Black("Changes removed.") } }, result, Secondary, null, 0);
            Footer("Start over", ShowChoose, "Close", Close);
        }

        void ShowBlocked(string message)
        {
            Arrange(new[] { new[] { Run.Black("hop can't continue.") } }, message, Secondary, null, 0);
            if (engine != null) Footer("Copy a bug report", () => _ = CopyReportAsync(), "Close", Close);
            else Footer(null, null, "Close", Close);
        }

        /// <summary>The PC, the disk layout, the startup menu and the log, ready to paste into an issue.</summary>
        async Task CopyReportAsync()
        {
            footerLink.Set("Copying…", false, Tertiary, false);
            onLink = null;
            string report;
            try { report = await engine.GetReportAsync(); }
            catch (Exception ex) { report = Describe(ex); }
            try
            {
                Clipboard.SetText(report);
                footerLink.Set("Copied. Paste it into a GitHub issue.", false, Tertiary, false);
            }
            catch
            {
                footerLink.Set("Couldn't reach the clipboard.", false, Tertiary, false);
            }
        }
    }
}
