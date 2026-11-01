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
        const int ErrorMoreData = 234, ErrorHandleEof = 38;
        const int MaxFailedMoves = 64;   // a cluster that looked free can be taken by the time it's asked for

        /// <summary>Moves each part of the stream past a fraction of the drive to the lowest free space before it. Says how many clusters moved.</summary>
        public static long MoveDown(string letter, string stream, double aboveFraction)
        {
            using (var volume = OpenVolume(letter))
                return Move(letter, stream, -1, (long)(TotalClusters(volume) * aboveFraction));
        }

        /// <summary>Moves the stream into the last part of the drive, for testing MoveDown. Says how many clusters moved.</summary>
        public static long MoveToEnd(string letter, string stream, double fromFraction)
        {
            using (var volume = OpenVolume(letter))
                return Move(letter, stream, (long)(TotalClusters(volume) * fromFraction), 0);
        }

        static long Move(string letter, string stream, long low, long above)
        {
            using (var volume = OpenVolume(letter))
            using (var file = OpenStream(letter, stream))
            {
                long total = TotalClusters(volume), moved = 0;
                int failed = 0;
                var extents = Extents(file);
                extents.Sort((a, b) => b.Lcn.CompareTo(a.Lcn));
                foreach (var extent in extents)
                {
                    if (low >= 0 ? extent.Lcn >= low : extent.Lcn + extent.Clusters <= above) continue;
                    long vcn = extent.Vcn, left = extent.Clusters, from = Math.Max(low, 0), before = low >= 0 ? total : extent.Lcn;
                    while (left > 0 && failed < MaxFailedMoves)
                    {
                        if (!FindFree(volume, from, before, left, out long start, out long length)) break;
                        int count = (int)Math.Min(Math.Min(left, length), int.MaxValue);
                        if (MoveClusters(volume, file, vcn, start, count))
                        {
                            moved += count; vcn += count; left -= count; from = start + count;
                        }
                        else
                        {
                            failed++;
                            from = start + length;
                        }
                    }
                }
                return moved;
            }
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

        static bool MoveClusters(SafeFileHandle volume, SafeFileHandle file, long vcn, long lcn, int count)
        {
            var data = new MoveFileData { File = file.DangerousGetHandle(), StartingVcn = vcn, StartingLcn = lcn, ClusterCount = count };
            return DeviceIoControl(volume, MoveFile, ref data, Marshal.SizeOf(typeof(MoveFileData)), IntPtr.Zero, 0, out _, IntPtr.Zero);
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

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateFileW")]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] input, int inputSize, byte[] output, int outputSize, out int returned, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle device, uint code, ref MoveFileData input, int inputSize, IntPtr output, int outputSize, out int returned, IntPtr overlapped);
    }
}
