using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace MacSwitcher.Windows.Native
{
    internal static class KeyboardLayoutSource
    {
        internal static string? Language(IntPtr layout)
        {
            uint hkl = unchecked((uint)layout.ToInt64());
            if (hkl == 0x04190419u) return "ru";
            if (hkl == 0x04090409u) return "en";
            return null;
        }

        internal static IntPtr FindInstalled(string language)
        {
            int size = Win32.GetKeyboardLayoutList(0, null);
            if (size <= 0 || size > 256) return IntPtr.Zero;
            var layouts = new IntPtr[size];
            int actual = Win32.GetKeyboardLayoutList(size, layouts);
            for (int i = 0; i < actual && i < size; i++)
                if (string.Equals(Language(layouts[i]), language, StringComparison.Ordinal)) return layouts[i];
            return IntPtr.Zero;
        }

        internal static bool RequestAndConfirm(NativeFocusSnapshot? focus, string language, int timeoutMilliseconds = 30)
        {
            if (focus == null || !focus.StillSame() || !NativeSafety.IsNormalDesktop() ||
                !NativeSafety.IsEqualOrLowerIntegrity(focus.ProcessId)) return false;
            var target = FindInstalled(language);
            if (target == IntPtr.Zero) return false;
            if (Win32.GetKeyboardLayout(focus.ThreadId) == target) return true;
            if (timeoutMilliseconds < 1) return false;
            var releaseDeadline = (long)Win32.GetTickCount64() + Math.Min(10, timeoutMilliseconds);
            while (!NativeSafety.ModifiersUp() && (long)Win32.GetTickCount64() < releaseDeadline) Thread.Sleep(1);
            if (!NativeSafety.ModifiersUp()) return false;
            if (!Win32.PostMessage(focus.Focus, Win32.WM_INPUTLANGCHANGEREQUEST, UIntPtr.Zero, target)) return false;
            var until = (long)Win32.GetTickCount64() + timeoutMilliseconds;
            while ((long)Win32.GetTickCount64() < until)
            {
                if (!focus.StillSame()) return false;
                if (Win32.GetKeyboardLayout(focus.ThreadId) == target) return true;
                Thread.Sleep(1);
            }
            return focus.StillSame() && Win32.GetKeyboardLayout(focus.ThreadId) == target;
        }

        internal static bool RequestAndConfirmPrevious(NativeFocusSnapshot? previous, string language)
        {
            if (previous == null || !PreviousTargetStillValid(previous)) return false;
            var foreground = Win32.GetForegroundWindow();
            uint currentPid;
            Win32.GetWindowThreadProcessId(foreground, out currentPid);
            if (foreground != previous.Foreground && currentPid != Process.GetCurrentProcess().Id) return false;
            var target = FindInstalled(language);
            if (target == IntPtr.Zero) return false;
            if (Win32.GetKeyboardLayout(previous.ThreadId) == target) return true;
            if (!Win32.PostMessage(previous.Focus, Win32.WM_INPUTLANGCHANGEREQUEST, UIntPtr.Zero, target)) return false;
            var deadline = (long)Win32.GetTickCount64() + 30;
            while ((long)Win32.GetTickCount64() < deadline)
            {
                if (!PreviousTargetStillValid(previous)) return false;
                if (Win32.GetKeyboardLayout(previous.ThreadId) == target) return true;
                Thread.Sleep(1);
            }
            return PreviousTargetStillValid(previous) && Win32.GetKeyboardLayout(previous.ThreadId) == target;
        }

        internal static bool PreviousTargetStillValid(NativeFocusSnapshot? previous)
        {
            if (previous == null || !NativeSafety.IsNormalDesktop() ||
                !NativeSafety.IsEqualOrLowerIntegrity(previous.ProcessId) ||
                !Win32.IsWindow(previous.Foreground) || !Win32.IsWindow(previous.Focus)) return false;
            uint pid;
            var tid = Win32.GetWindowThreadProcessId(previous.Foreground, out pid);
            if (pid != previous.ProcessId || tid != previous.ThreadId) return false;
            var info = new Win32.GUITHREADINFO { cbSize = (uint)Marshal.SizeOf(typeof(Win32.GUITHREADINFO)) };
            return Win32.GetGUIThreadInfo(tid, ref info) && info.hwndFocus == previous.Focus;
        }
    }
}
