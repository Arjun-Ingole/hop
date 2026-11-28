using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Hop
{
    /// <summary>
    /// Checks a file that was just written. Read the ordinary way, it comes back from Windows' memory, which is what
    /// was written and says nothing of the disk. Read past the cache, as this does, Windows first writes out what it
    /// still holds and then reads what the disk really has. Called from the engine scripts as [Hop.FileCheck].
    /// </summary>
    public static class FileCheck
    {
        // A multiple of every sector size, as reading past the cache needs, and enough to keep a disk busy.
        const int Chunk = 1 << 20;

        /// <summary>The SHA-256 of what's on the disk for this file, in upper-case hex as Get-FileHash gives it.</summary>
        public static string Sha256FromDisk(string path)
        {
            using (var file = CreateFile(path, GenericRead, FileShareAll, IntPtr.Zero, OpenExisting, FileFlagNoBuffering | FileFlagSequentialScan, IntPtr.Zero))
            {
                if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), $"Could not open {path} to check it.");
                // The buffer has to start on a sector boundary too, which memory from VirtualAlloc does.
                IntPtr buffer = VirtualAlloc(IntPtr.Zero, (UIntPtr)Chunk, MemCommit | MemReserve, PageReadWrite);
                if (buffer == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    var managed = new byte[Chunk];
                    using (var sha = SHA256.Create())
                    {
                        while (true)
                        {
                            if (!ReadFile(file, buffer, Chunk, out int read, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), $"Could not read {path} to check it.");
                            if (read == 0) break;
                            Marshal.Copy(buffer, managed, 0, read);
                            sha.TransformBlock(managed, 0, read, null, 0);
                            if (read < Chunk) break;
                        }
                        sha.TransformFinalBlock(new byte[0], 0, 0);
                        return BitConverter.ToString(sha.Hash).Replace("-", "");
                    }
                }
                finally
                {
                    VirtualFree(buffer, UIntPtr.Zero, MemRelease);
                }
            }
        }

        const uint GenericRead = 0x80000000, FileShareAll = 7, OpenExisting = 3;
        const uint FileFlagNoBuffering = 0x20000000, FileFlagSequentialScan = 0x08000000;
        const uint MemCommit = 0x1000, MemReserve = 0x2000, MemRelease = 0x8000, PageReadWrite = 0x04;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateFileW")]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadFile(SafeFileHandle file, IntPtr buffer, int count, out int read, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr VirtualAlloc(IntPtr address, UIntPtr size, uint type, uint protect);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool VirtualFree(IntPtr address, UIntPtr size, uint type);
    }
}
