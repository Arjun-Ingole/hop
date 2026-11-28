using System;
using System.Runtime.InteropServices;

namespace Hop
{
    static class Native
    {
        const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        const int DWMWCP_ROUND = 2, DWMWCP_ROUNDSMALL = 3;
        const int WM_NCLBUTTONDOWN = 0xA1, HTCAPTION = 2;

        public const int CS_DROPSHADOW = 0x20000;
        public const int WS_MINIMIZEBOX = 0x20000, WS_SYSMENU = 0x80000;

        /// <summary>Stops the PC sleeping on its own while hop works. Holds for the UI thread that asks. The screen can still turn off.</summary>
        public static void KeepAwake(bool on)
        {
            try { SetThreadExecutionState(on ? EsContinuous | EsSystemRequired : EsContinuous); } catch { }
        }

        const uint EsContinuous = 0x80000000, EsSystemRequired = 0x1;

        [DllImport("kernel32.dll")]
        static extern uint SetThreadExecutionState(uint flags);

        /// <summary>Windows 11 rounded corners. Does nothing on Windows 10.</summary>
        public static void RoundCorners(IntPtr hwnd, bool small = false)
        {
            if (!IsWindows11) return;
            int preference = small ? DWMWCP_ROUNDSMALL : DWMWCP_ROUND;
            try { DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref preference, sizeof(int)); } catch { }
        }

        public static bool IsWindows11 => Environment.OSVersion.Version.Build >= 22000;

        /// <summary>Lets a mouse press on a custom title area move the window.</summary>
        public static void BeginWindowDrag(IntPtr hwnd)
        {
            ReleaseCapture();
            SendMessage(hwnd, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
        }

        // --- Shutting down ---------------------------------------------------------------

        /// <summary>
        /// The words Windows shows by hop's name if a shutdown has to wait for it. Only from the
        /// window's own thread. Windows lists it only while hop is actually holding the shutdown.
        /// </summary>
        public static void BlockShutdown(IntPtr hwnd, string reason)
        {
            try { ShutdownBlockReasonCreate(hwnd, reason); } catch { }
        }

        public static void AllowShutdown(IntPtr hwnd)
        {
            try { ShutdownBlockReasonDestroy(hwnd); } catch { }
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool ShutdownBlockReasonCreate(IntPtr hWnd, string reason);

        [DllImport("user32.dll")]
        static extern bool ShutdownBlockReasonDestroy(IntPtr hWnd);

        // --- Taskbar progress ---------------------------------------------------------

        public enum TaskbarState { NoProgress = 0, Indeterminate = 1, Normal = 2, Error = 4 }

        static ITaskbarList3 taskbar;
        static bool taskbarMissing;

        /// <summary>
        /// The bar behind hop's taskbar button, so a long download shows while hop is minimized.
        /// Made the first time it's needed, on the UI thread. Without it (no Explorer, say) it does nothing.
        /// </summary>
        public static void TaskbarProgress(IntPtr hwnd, TaskbarState state, double fraction = 0)
        {
            if (taskbarMissing || hwnd == IntPtr.Zero) return;
            try
            {
                if (taskbar == null)
                {
                    var list = (ITaskbarList3)new TaskbarList();
                    list.HrInit();
                    taskbar = list;
                }
                taskbar.SetProgressState(hwnd, (int)state);
                if (state == TaskbarState.Normal || state == TaskbarState.Error)
                    taskbar.SetProgressValue(hwnd, (ulong)Math.Round(Math.Max(0, Math.Min(1, fraction)) * 1000), 1000);
            }
            catch { taskbarMissing = taskbar == null; }
        }

        [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090"), ClassInterface(ClassInterfaceType.None)]
        class TaskbarList { }

        // ITaskbarList, ITaskbarList2 and then ITaskbarList3's own, in vtable order. Only the ones hop uses come after.
        [ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eee84"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface ITaskbarList3
        {
            void HrInit();
            void AddTab(IntPtr hwnd);
            void DeleteTab(IntPtr hwnd);
            void ActivateTab(IntPtr hwnd);
            void SetActiveAlt(IntPtr hwnd);
            void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
            void SetProgressValue(IntPtr hwnd, ulong completed, ulong total);
            void SetProgressState(IntPtr hwnd, int flags);
        }

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("user32.dll")]
        static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
    }
}
