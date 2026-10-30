using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading.Tasks;

namespace Hop
{
    public sealed class Distro
    {
        public string Id;
        public string Name;
        public string Version;
        public string Note;
        public string Source;
        public string Strategy;
        public string Logo;
        public System.Drawing.Color Color;
    }

    public sealed class StartupInfo
    {
        public int UsableGB;            // how much C: can give up while Windows keeps its reserve
        public int WindowsGB;           // size of C:
        public int UsedGB;
        public string DiskName;
        public int TailFreeGB;          // unallocated space right after C:
        public string OtherName;        // another Linux on this drive, such as Pond
        public int OtherGB;
        public string Status;           // "ready", "leftover" (from an attempt that didn't finish) or "none"
        public string PreparedDistro;   // set when an installer is ready
        public string PreparedId;
    }

    public sealed class InstallSteps
    {
        public string[] Steps;
        public string[] Notes;
    }

    /// <summary>
    /// Runs engine\Engine.ps1 in an in-process PowerShell runspace. Calls are
    /// serialized; progress is shared through <see cref="Sync"/>.
    /// </summary>
    public sealed class Engine : IDisposable
    {
        readonly Runspace runspace;
        readonly object gate = new object();
        volatile PowerShell running;

        public readonly Hashtable Sync = Hashtable.Synchronized(new Hashtable());
        public readonly ArrayList Log = ArrayList.Synchronized(new ArrayList());

        public Engine()
        {
            Sync["Log"] = Log;
            ResetProgress();

            var session = InitialSessionState.CreateDefault();
            session.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            runspace = RunspaceFactory.CreateRunspace(session);
            runspace.Open();
            runspace.SessionStateProxy.SetVariable("Sync", Sync);

            using (var ps = PowerShell.Create())
            {
                ps.Runspace = runspace;
                ps.AddScript(ReadEngineScript(), useLocalScope: false).Invoke();
            }
        }

        static string ReadEngineScript()
        {
            using (var stream = typeof(Engine).Assembly.GetManifestResourceStream("Hop.Engine.ps1"))
            using (var reader = new StreamReader(stream))
                return reader.ReadToEnd();
        }

        public void ResetProgress()
        {
            Sync["Status"] = "";
            Sync["Percent"] = -1;
            Sync["Stage"] = 0;
            Sync["Bytes"] = 0L;
            Sync["TotalBytes"] = 0L;
        }

        public string Status => Sync["Status"] as string ?? "";
        public int Percent => Convert.ToInt32(Sync["Percent"]);
        public int Stage => Convert.ToInt32(Sync["Stage"]);
        public long Bytes => Convert.ToInt64(Sync["Bytes"] ?? 0L);
        public long TotalBytes => Convert.ToInt64(Sync["TotalBytes"] ?? 0L);

        Collection Invoke(string command, IDictionary parameters = null)
        {
            lock (gate)
            {
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddCommand(command);
                    if (parameters != null) ps.AddParameters(parameters);
                    running = ps;
                    try { return new Collection(ps.Invoke()); }
                    finally { running = null; }
                }
            }
        }

        Task<Collection> InvokeAsync(string command, IDictionary parameters = null) =>
            Task.Run(() => Invoke(command, parameters));

        public List<Distro> GetCatalog() =>
            Invoke("Get-Catalog").Items.Select(o => new Distro
            {
                Id = Get<string>(o, "Id"),
                Name = Get<string>(o, "Name"),
                Version = Get<string>(o, "Version"),
                Note = Get<string>(o, "Note"),
                Source = Get<string>(o, "Source"),
                Strategy = Get<string>(o, "Strategy"),
                Logo = Get<string>(o, "Logo"),
                Color = System.Drawing.ColorTranslator.FromHtml(Get<string>(o, "Color")),
            }).ToList();

        public async Task<StartupInfo> GetStartupInfoAsync()
        {
            var info = (await InvokeAsync("Get-StartupInfo")).Single;
            var stateValue = info.Properties["State"]?.Value;
            var state = stateValue == null ? null : PSObject.AsPSObject(stateValue);
            var otherValue = info.Properties["Other"]?.Value;
            var other = otherValue == null ? null : PSObject.AsPSObject(otherValue);
            return new StartupInfo
            {
                UsableGB = Get<int>(info, "UsableGB"),
                WindowsGB = Get<int>(info, "WindowsGB"),
                UsedGB = Get<int>(info, "UsedGB"),
                DiskName = Get<string>(info, "DiskName"),
                Status = Get<string>(info, "Status"),
                TailFreeGB = Get<int>(info, "TailFreeGB"),
                OtherName = other == null ? null : Get<string>(other, "Name"),
                OtherGB = other == null ? 0 : Get<int>(other, "SizeGB"),
                PreparedDistro = state == null ? null : Get<string>(state, "Distro"),
                PreparedId = state == null ? null : Get<string>(state, "DistroId"),
            };
        }

        public Task InstallAsync(string distroId, string isoPath, int linuxGB) =>
            InvokeAsync("Invoke-Install", new Hashtable
            {
                ["DistroId"] = distroId,
                ["IsoPath"] = isoPath ?? "",
                ["LinuxGB"] = linuxGB,
            });

        public Task CleanupAsync(bool installerOnly) =>
            InvokeAsync("Invoke-Cleanup", new Hashtable { ["InstallerOnly"] = installerOnly });

        public async Task<InstallSteps> GetStepsAsync()
        {
            var steps = (await InvokeAsync("Get-StateSteps")).Single;
            return new InstallSteps
            {
                Steps = Get<string[]>(steps, "Steps"),
                Notes = Get<string[]>(steps, "Notes"),
            };
        }

        public Task RestartIntoInstallerAsync() => InvokeAsync("Restart-IntoInstaller");

        public Task RemoveOtherSystemAsync() => InvokeAsync("Remove-OtherSystem");

        public Task ExpandWindowsAsync() => InvokeAsync("Expand-Windows");

        /// <summary>Stops the running command; its task then fails with PipelineStoppedException.</summary>
        public void Stop() => running?.BeginStop(null, null);

        static T Get<T>(PSObject o, string name) =>
            LanguagePrimitives.ConvertTo<T>(o.Properties[name]?.Value);

        public void Dispose() => runspace.Dispose();

        sealed class Collection
        {
            public readonly List<PSObject> Items;
            public Collection(IEnumerable<PSObject> items) => Items = items.Where(i => i != null).ToList();
            public PSObject Single => Items.Last();
        }
    }
}
