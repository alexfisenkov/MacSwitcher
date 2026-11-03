using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace MacSwitcher.Windows.Native
{
    internal sealed class NativeFocusSnapshot
    {
        private static readonly int OwnProcessId = Process.GetCurrentProcess().Id;
        internal IntPtr Foreground { get; private set; }
        internal IntPtr Focus { get; private set; }
        internal uint ProcessId { get; private set; }
        internal uint ThreadId { get; private set; }
        internal IntPtr Layout { get; private set; }

        internal static NativeFocusSnapshot? Capture()
        {
            var foreground = Win32.GetForegroundWindow();
            if (foreground == IntPtr.Zero) return null;
            uint pid;
            var thread = Win32.GetWindowThreadProcessId(foreground, out pid);
            if (thread == 0 || pid == 0 || pid == OwnProcessId) return null;
            var info = new Win32.GUITHREADINFO { cbSize = (uint)Marshal.SizeOf(typeof(Win32.GUITHREADINFO)) };
            if (!Win32.GetGUIThreadInfo(thread, ref info) || info.hwndFocus == IntPtr.Zero) return null;
            return new NativeFocusSnapshot { Foreground = foreground, Focus = info.hwndFocus,
                ProcessId = pid, ThreadId = thread, Layout = Win32.GetKeyboardLayout(thread) };
        }

        internal bool StillSame()
        {
            var current = Capture();
            return current != null && current.Foreground == Foreground && current.Focus == Focus &&
                current.ProcessId == ProcessId && current.ThreadId == ThreadId;
        }
    }

    internal static class NativeSafety
    {
        internal static bool IsNormalDesktop()
        {
            var input = Win32.OpenInputDesktop(0, false, Win32.DESKTOP_READOBJECTS);
            if (input == IntPtr.Zero) return false;
            try
            {
                var own = Win32.GetThreadDesktop(Win32.GetCurrentThreadId());
                return own != IntPtr.Zero && string.Equals(DesktopName(input), DesktopName(own), StringComparison.OrdinalIgnoreCase)
                    && string.Equals(DesktopName(input), "Default", StringComparison.OrdinalIgnoreCase);
            }
            finally { Win32.CloseDesktop(input); }
        }

        private static string? DesktopName(IntPtr desktop)
        {
            var name = new StringBuilder(128);
            uint required;
            return Win32.GetUserObjectInformation(desktop, 2, name, (uint)(name.Capacity * 2), out required) ? name.ToString() : null;
        }

        internal static bool IsEqualOrLowerIntegrity(uint pid)
        {
            int own, other;
            return TryIntegrity((uint)Process.GetCurrentProcess().Id, out own) &&
                TryIntegrity(pid, out other) && other <= own;
        }

        internal static bool TryTargetHigherIntegrity(uint pid, out bool higher)
        {
            higher = false;
            int own, other;
            if (!TryIntegrity((uint)Process.GetCurrentProcess().Id, out own) || !TryIntegrity(pid, out other))
                return false;
            higher = other > own;
            return true;
        }

        private static bool TryIntegrity(uint pid, out int rid)
        {
            rid = 0;
            var process = Win32.OpenProcess(Win32.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (process == IntPtr.Zero) return false;
            try
            {
                IntPtr token;
                if (!Win32.OpenProcessToken(process, Win32.TOKEN_QUERY, out token)) return false;
                try
                {
                    int bytes;
                    Win32.GetTokenInformation(token, Win32.TokenIntegrityLevel, IntPtr.Zero, 0, out bytes);
                    if (bytes < IntPtr.Size || bytes > 4096) return false;
                    var memory = Marshal.AllocHGlobal(bytes);
                    try
                    {
                        if (!Win32.GetTokenInformation(token, Win32.TokenIntegrityLevel, memory, bytes, out bytes)) return false;
                        var sid = Marshal.ReadIntPtr(memory);
                        var countAddress = Win32.GetSidSubAuthorityCount(sid);
                        if (countAddress == IntPtr.Zero) return false;
                        var count = Marshal.ReadByte(countAddress);
                        if (count == 0) return false;
                        var authority = Win32.GetSidSubAuthority(sid, (uint)(count - 1));
                        if (authority == IntPtr.Zero) return false;
                        rid = Marshal.ReadInt32(authority);
                        return true;
                    }
                    finally { Marshal.FreeHGlobal(memory); }
                }
                finally { Win32.CloseHandle(token); }
            }
            finally { Win32.CloseHandle(process); }
        }

        internal static bool ModifiersUp()
        {
            return Up(Win32.VK_SHIFT) && CommandModifiersUp();
        }

        internal static bool CommandModifiersUp()
        {
            return Up(Win32.VK_CONTROL) && Up(Win32.VK_MENU) &&
                Up(Win32.VK_LWIN) && Up(Win32.VK_RWIN);
        }

        private static bool Up(int key) { return (Win32.GetAsyncKeyState(key) & 0x8000) == 0; }
    }
}
