using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Hop
{
    /// <summary>
    /// Says what is on a partition by reading its first bytes. To Windows every Linux file
    /// system and a locked BitLocker drive look the same (unreadable), and hop must never
    /// mistake one for the other. Called from the engine scripts as [Hop.DiskProbe].
    /// </summary>
    public static class DiskProbe
    {
        const int HeadSize = 128 * 1024;   // a multiple of every sector size; holds all the signatures below
        const uint GenericRead = 0x80000000, ShareRead = 1, ShareWrite = 2, OpenExisting = 3;

        /// <summary>"ext", "btrfs", "xfs", "luks", "lvm", "swap", "bitlocker" or null.</summary>
        public static string ReadSignature(int diskNumber, long offset)
        {
            var handle = CreateFile($@"\\.\PhysicalDrive{diskNumber}", GenericRead, ShareRead | ShareWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the disk.");
            using (var disk = new FileStream(handle, FileAccess.Read, 1, false))
            {
                disk.Position = offset;
                var head = new byte[HeadSize];
                int read = 0, count;
                while (read < head.Length && (count = disk.Read(head, read, head.Length - read)) > 0) read += count;
                return Identify(head);
            }
        }

        public static string Identify(byte[] head)
        {
            if (Has(head, 3, "-FVE-FS-")) return "bitlocker";
            if (Has(head, 0, "XFSB")) return "xfs";
            if (Has(head, 0, "LUKS") && head.Length > 5 && head[4] == 0xBA && head[5] == 0xBE) return "luks";
            if (Has(head, 512, "LABELONE")) return "lvm";
            if (Has(head, 4086, "SWAPSPACE2") || Has(head, 4086, "SWAP-SPACE")) return "swap";
            if (Has(head, 65536 + 64, "_BHRfS_M")) return "btrfs";

            // ext2/3/4: the magic number at 1080 is only two bytes, so check the superblock makes sense too.
            if (head.Length > 1084 && head[1080] == 0x53 && head[1081] == 0xEF)
            {
                uint inodes = BitConverter.ToUInt32(head, 1024), logBlockSize = BitConverter.ToUInt32(head, 1024 + 24);
                if (inodes > 0 && logBlockSize <= 6) return "ext";
            }
            return null;
        }

        static bool Has(byte[] data, int offset, string text)
        {
            if (offset + text.Length > data.Length) return false;
            for (int i = 0; i < text.Length; i++)
                if (data[offset + i] != (byte)text[i]) return false;
            return true;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateFileW")]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    }
}
