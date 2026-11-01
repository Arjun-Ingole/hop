using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Hop
{
    /// <summary>
    /// %ProgramData%\hop, which code running as administrator and SYSTEM reads and acts on. By default anyone
    /// can create files under %ProgramData%, so before anything uses it this makes sure only administrators
    /// can write there, and moves aside anything an ordinary user could have put there first.
    /// Called from Program.cs as hop starts, and from the engine scripts as [Hop.StateFolder].
    /// </summary>
    public static class StateFolder
    {
        const int Tries = 5;

        /// <summary>Set once the folder is safe. Until then nothing writes there, not even a crash log.</summary>
        public static bool Ready { get; private set; }

        public static string ProgramData => Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);

        /// <summary>hop's folder, and the one builds called LinuxHop used, whose state file is still read if it's there.</summary>
        public static void ProtectAll()
        {
            string folder = Path.Combine(ProgramData, "hop");
            var moved = new List<string>(Protect(folder, true));
            moved.AddRange(Protect(Path.Combine(ProgramData, "LinuxHop"), false));
            Ready = true;
            foreach (string line in moved) Log(folder, line);
        }

        /// <summary>
        /// Makes the folder if asked to, or takes over the one a build before this left, keeping what's in it.
        /// Says what it had to move aside. Throws if it couldn't make the folder safe.
        /// </summary>
        public static string[] Protect(string folder, bool create)
        {
            var moved = new List<string>();
            for (int i = 0; i < Tries; i++)
            {
                if (!Directory.Exists(folder) && !File.Exists(folder))
                {
                    if (!create) return moved.ToArray();
                    // It might be there by now, as someone else's, so this goes round again to look.
                    Directory.CreateDirectory(folder, RestartCopy.ProtectedRights());
                    continue;
                }
                if (!Directory.Exists(folder) || !IsTrusted(folder))
                {
                    moved.Add(MoveAside(folder, folder));
                    continue;
                }
                // Before as well as after: setting the rights walks what's inside, which shouldn't go through a link.
                Sweep(folder, folder, moved);
                if (!Directory.GetAccessControl(folder, AccessControlSections.Access).AreAccessRulesProtected)
                    Directory.SetAccessControl(folder, RestartCopy.ProtectedRights());
                Sweep(folder, folder, moved);
                return moved.ToArray();
            }
            throw new IOException($"Something keeps replacing {folder}.");
        }

        /// <summary>
        /// Not a link, and owned by administrators or SYSTEM. An ordinary user can't give anything away to them,
        /// so this says who made it. hop always runs elevated, so its own account counts as well, for what a
        /// build before this made on a PC where an elevated process owns what it makes.
        /// </summary>
        public static bool IsTrusted(string path)
        {
            try
            {
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0) return false;
                FileSystemSecurity rights = (attributes & FileAttributes.Directory) != 0
                    ? (FileSystemSecurity)Directory.GetAccessControl(path, AccessControlSections.Owner)
                    : File.GetAccessControl(path, AccessControlSections.Owner);
                return IsTrustedOwner(rights.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier);
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException || ex is InvalidOperationException)
            {
                return false;
            }
        }

        static bool IsTrustedOwner(SecurityIdentifier owner)
        {
            if (owner == null) return false;
            if (owner.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid) || owner.IsWellKnown(WellKnownSidType.LocalSystemSid)) return true;
            using (var me = WindowsIdentity.GetCurrent())
                return owner == me.User && new WindowsPrincipal(me).IsInRole(WindowsBuiltInRole.Administrator);
        }

        static void Sweep(string root, string folder, List<string> moved)
        {
            foreach (string entry in Directory.GetFileSystemEntries(folder))
            {
                if (!IsTrusted(entry)) moved.Add(MoveAside(entry, root));
                else if ((File.GetAttributes(entry) & FileAttributes.Directory) != 0) Sweep(root, entry, moved);
            }
        }

        // Renames, so a link stays a link and nothing it points at is touched. Works for a file too.
        static string MoveAside(string path, string root)
        {
            string aside = $"{root.TrimEnd('\\')}-moved-{Guid.NewGuid():N}";
            Directory.Move(path, aside);
            return $"Moved {path} to {aside}, because hop can't trust who made it.";
        }

        static void Log(string folder, string line)
        {
            try
            {
                string logs = Path.Combine(folder, "logs");
                Directory.CreateDirectory(logs);
                File.AppendAllText(Path.Combine(logs, $"hop-{DateTime.Now:yyyy-MM-dd}.log"), $"{DateTime.Now:HH:mm:ss}  {line}{Environment.NewLine}");
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException) { }
        }
    }
}
