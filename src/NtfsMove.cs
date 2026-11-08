using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Hop
{
    /// <summary>
    /// Moves an NTFS system stream to free clusters with FSCTL_MOVE_FILE, the call defragmenters use.
    /// defrag /X can leave one like $Mft::$BITMAP near the end of a drive, where it stops Windows
    /// shrinking it, though Microsoft lists it as movable. Called from the engine scripts as [Hop.NtfsMove].
    /// </summary>
    public static class NtfsMove
    {
        const uint GenericRead = 0x80000000, GenericWrite = 0x40000000, FileReadAttributes = 0x80, Synchronize = 0x100000;
        const uint ShareAll = 7, OpenExisting = 3, BackupSemantics = 0x02000000;
        const uint GetVolumeBitmap = 0x9006F, GetRetrievalPointers = 0x90073, MoveFile = 0x90074;
        const int ErrorMoreData = 234, ErrorHandleEof = 38, ErrorInvalidParameter = 87;
        const int MaxFailedMoves = 64;   // a cluster that looked free can be taken by the time it's asked for

        /// <summary>Moves each part of the stream past a fraction of the drive to the lowest free space before it. Says how many clusters moved.</summary>
        public static long MoveDown(string letter, string stream, double aboveFraction) => MoveDown(letter, stream, aboveFraction, 0);

        /// <summary>The same, stopping after so many seconds, 0 for none. What moved before then stays moved.</summary>
        public static long MoveDown(string letter, string stream, double aboveFraction, int seconds)
        {
            using (var volume = OpenVolume(letter))
                return Move(letter, stream, -1, (long)(TotalClusters(volume) * aboveFraction), seconds);
        }

        /// <summary>Moves the stream into the last part of the drive, for testing MoveDown. Says how many clusters moved.</summary>
        public static long MoveToEnd(string letter, string stream, double fromFraction)
        {
            using (var volume = OpenVolume(letter))
                return Move(letter, stream, (long)(TotalClusters(volume) * fromFraction), 0, 0);
        }

        // Moves of up to this many clusters at a time, so a big file can stop at the time limit.
        const int MovePieceClusters = 16384;

        /// <summary>Why the last MoveDown or MoveToEnd moved less than it tried to, for the log. Empty when nothing went wrong.</summary>
        public static string LastFailure { get; private set; } = "";

        static long Move(string letter, string stream, long low, long above, int seconds)
        {
            LastFailure = "";
            var deadline = seconds > 0 ? DateTime.UtcNow.AddSeconds(seconds) : DateTime.MaxValue;
            using (var volume = OpenVolume(letter))
            using (var file = OpenStream(letter, stream))
            {
                long total = TotalClusters(volume), moved = 0;
                // NTFS refuses to move the clusters past the end of a stream's data. Trying them used to spend every
                // attempt, so the part that can move never did.
                long inData = DataClusters(letter, file);
                var refused = new List<string>();
                var extents = Extents(file);
                extents.Sort((a, b) => b.Lcn.CompareTo(a.Lcn));
                foreach (var whole in extents)
                {
                    var extent = whole;
                    if (inData >= 0 && extent.Vcn + extent.Clusters > inData)
                    {
                        long past = extent.Vcn + extent.Clusters - Math.Max(extent.Vcn, inData);
                        refused.Add($"{past} clusters at {extent.Lcn + extent.Clusters - past} are past the end of its data");
                        extent.Clusters -= past;
                        if (extent.Clusters <= 0) continue;
                    }
                    if (low >= 0 ? extent.Lcn >= low : extent.Lcn + extent.Clusters <= above) continue;
                    long vcn = extent.Vcn, left = extent.Clusters, from = Math.Max(low, 0), before = low >= 0 ? total : extent.Lcn;
                    int failed = 0, error = 0;
                    while (left > 0 && failed < MaxFailedMoves && DateTime.UtcNow < deadline)
                    {
                        if (!FindFree(volume, from, before, left, out long start, out long length)) { refused.Add($"no free space before cluster {before} for {left} clusters"); break; }
                        int count = (int)Math.Min(Math.Min(left, length), MovePieceClusters);
                        if (MoveClusters(volume, file, vcn, start, count, out error))
                        {
                            moved += count; vcn += count; left -= count; from = start + count;
                        }
                        else
                        {
                            failed++;
                            // NTFS turns down what it never moves, such as the start of $Mft, the same way every time.
                            // A cluster taken since the bitmap was read is worth trying elsewhere.
                            if (error == ErrorInvalidParameter) break;
                            from = start + length;
                        }
                    }
                    if (failed > 0) refused.Add($"Windows refused {failed} moves of the clusters at {extent.Lcn} (error {error}: {new Win32Exception(error).Message})");
                }
                LastFailure = string.Join("; ", refused);
                return moved;
            }
        }

        /// <summary>Where each part of a stream is, and how much of it is data, for the log.</summary>
        public static string Describe(string letter, string stream)
        {
            using (var file = OpenStream(letter, stream))
            {
                long inData = DataClusters(letter, file);
                var parts = Extents(file);
                parts.Sort((a, b) => a.Vcn.CompareTo(b.Vcn));
                return $"{stream}: {(inData < 0 ? "unknown" : inData.ToString())} clusters of data, in " +
                    string.Join(", ", parts.ConvertAll(e => $"{e.Clusters} at {e.Lcn}"));
            }
        }

        // How many clusters the stream's data reaches into, or -1 when Windows won't say.
        static long DataClusters(string letter, SafeFileHandle file)
        {
            if (!GetFileInformationByHandleEx(file, 1, out StandardInfo info, Marshal.SizeOf(typeof(StandardInfo)))) return -1;
            if (!GetDiskFreeSpace($@"{letter.TrimEnd(':')}:\", out uint sectors, out uint bytes, out _, out _)) return -1;
            long cluster = (long)sectors * bytes;
            return cluster > 0 && info.EndOfFile > 0 ? (info.EndOfFile + cluster - 1) / cluster : -1;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct StandardInfo
        {
            public long AllocationSize, EndOfFile;
            public uint NumberOfLinks;
            public byte DeletePending, Directory;
        }

        struct Extent { public long Vcn, Lcn, Clusters; }

        static List<Extent> Extents(SafeFileHandle file)
        {
            var extents = new List<Extent>();
            var output = new byte[64 * 1024];
            long vcn = 0;
            while (true)
            {
                bool ok = DeviceIoControl(file, GetRetrievalPointers, BitConverter.GetBytes(vcn), 8, output, output.Length, out _, IntPtr.Zero);
                int error = ok ? 0 : Marshal.GetLastWin32Error();
                if (!ok && error == ErrorHandleEof) return extents;   // small enough to live in the file's own record
                if (!ok && error != ErrorMoreData) throw new Win32Exception(error, "Could not find where the file is.");
                int count = BitConverter.ToInt32(output, 0);
                long next = BitConverter.ToInt64(output, 8);
                for (int i = 0; i < count; i++)
                {
                    long nextVcn = BitConverter.ToInt64(output, 16 + i * 16), lcn = BitConverter.ToInt64(output, 24 + i * 16);
                    if (lcn >= 0) extents.Add(new Extent { Vcn = next, Lcn = lcn, Clusters = nextVcn - next });   // -1 is a hole
                    next = nextVcn;
                }
                if (ok || count == 0) return extents;
                vcn = next;
            }
        }

        /// <summary>The first free run between two clusters that holds what's wanted, or else the longest there is.</summary>
        static bool FindFree(SafeFileHandle volume, long from, long before, long wanted, out long start, out long length)
        {
            start = length = 0;
            long runStart = -1, runLength = 0;
            var output = new byte[1024 * 1024 + 16];
            long lcn = from;
            while (lcn < before)
            {
                bool ok = DeviceIoControl(volume, GetVolumeBitmap, BitConverter.GetBytes(lcn), 8, output, output.Length, out int returned, IntPtr.Zero);
                int error = ok ? 0 : Marshal.GetLastWin32Error();
                if (!ok && error != ErrorMoreData) throw new Win32Exception(error, "Could not read which clusters are free.");
                long first = BitConverter.ToInt64(output, 0), bits = BitConverter.ToInt64(output, 8);
                long available = Math.Min(bits, (returned - 16) * 8L);
                if (available <= 0) break;
                for (long i = 0; i < available; i++)
                {
                    long cluster = first + i;
                    if (cluster < from) continue;
                    if (cluster >= before) { lcn = before; break; }
                    if ((output[16 + i / 8] & (1 << (int)(i % 8))) == 0)
                    {
                        if (runStart < 0) { runStart = cluster; runLength = 0; }
                        runLength++;
                        if (runLength >= wanted) { start = runStart; length = runLength; return true; }
                    }
                    else
                    {
                        if (runLength > length) { start = runStart; length = runLength; }
                        runStart = -1; runLength = 0;
                    }
                }
                if (ok) break;
                lcn = Math.Max(lcn + 1, first + available);
            }
            if (runLength > length) { start = runStart; length = runLength; }
            return length > 0;
        }

        static long TotalClusters(SafeFileHandle volume)
        {
            var output = new byte[32];
            bool ok = DeviceIoControl(volume, GetVolumeBitmap, BitConverter.GetBytes(0L), 8, output, output.Length, out _, IntPtr.Zero);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            if (!ok && error != ErrorMoreData) throw new Win32Exception(error, "Could not read which clusters are free.");
            return BitConverter.ToInt64(output, 8);
        }

        static bool MoveClusters(SafeFileHandle volume, SafeFileHandle file, long vcn, long lcn, int count, out int error)
        {
            var data = new MoveFileData { File = file.DangerousGetHandle(), StartingVcn = vcn, StartingLcn = lcn, ClusterCount = count };
            bool ok = DeviceIoControl(volume, MoveFile, ref data, Marshal.SizeOf(typeof(MoveFileData)), IntPtr.Zero, 0, out _, IntPtr.Zero);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }

        static SafeFileHandle OpenVolume(string letter)
        {
            var handle = CreateFile($@"\\.\{letter.TrimEnd(':')}:", GenericRead | GenericWrite, ShareAll, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the drive.");
            return handle;
        }

        // Only some of these open for reading, and the rest with less.
        static SafeFileHandle OpenStream(string letter, string stream)
        {
            string path = $@"{letter.TrimEnd(':')}:\{stream.TrimStart('\\')}";
            var handle = CreateFile(path, GenericRead | Synchronize, ShareAll, IntPtr.Zero, OpenExisting, BackupSemantics, IntPtr.Zero);
            if (handle.IsInvalid) handle = CreateFile(path, FileReadAttributes | Synchronize, ShareAll, IntPtr.Zero, OpenExisting, BackupSemantics, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), $"Could not open {stream}.");
            return handle;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MoveFileData
        {
            public IntPtr File;
            public long StartingVcn, StartingLcn;
            public int ClusterCount;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int infoClass, out StandardInfo info, int size);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "GetDiskFreeSpaceW")]
        static extern bool GetDiskFreeSpace(string root, out uint sectorsPerCluster, out uint bytesPerSector, out uint freeClusters, out uint totalClusters);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateFileW")]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] input, int inputSize, byte[] output, int outputSize, out int returned, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle device, uint code, ref MoveFileData input, int inputSize, IntPtr output, int outputSize, out int returned, IntPtr overlapped);
    }
}
