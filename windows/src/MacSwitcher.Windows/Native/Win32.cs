using System;
using System.Runtime.InteropServices;
using System.Text;

namespace MacSwitcher.Windows.Native
{
    internal static class Win32
    {
        internal const int WH_KEYBOARD_LL = 13;
        internal const int WH_MOUSE_LL = 14;
        internal const int HC_ACTION = 0;
        internal const int WM_KEYDOWN = 0x0100;
        internal const int WM_KEYUP = 0x0101;
        internal const int WM_SYSKEYDOWN = 0x0104;
        internal const int WM_SYSKEYUP = 0x0105;
        internal const int WM_INPUTLANGCHANGEREQUEST = 0x0050;
        internal const int WM_INPUTLANGCHANGE = 0x0051;
        internal const int WM_QUIT = 0x0012;
        internal const int WM_MOUSEMOVE = 0x0200;
        internal const uint EM_GETSEL = 0x00B0;
        internal const uint EM_SETSEL = 0x00B1;
        internal const uint EM_REPLACESEL = 0x00C2;
        internal const uint SMTO_ABORTIFHUNG = 0x0002;
        internal const uint SMTO_ERRORONEXIT = 0x0020;
        internal const int GWL_STYLE = -16;
        internal const int ES_PASSWORD = 0x0020;
        internal const int ES_READONLY = 0x0800;
        internal const int WS_DISABLED = 0x08000000;
        internal const int LLKHF_INJECTED = 0x10;
        internal const int LLMHF_INJECTED = 0x01;
        internal const int VK_LSHIFT = 0xA0;
        internal const int VK_RSHIFT = 0xA1;
        internal const int VK_SHIFT = 0x10;
        internal const int VK_CONTROL = 0x11;
        internal const int VK_MENU = 0x12;
        internal const int VK_LWIN = 0x5B;
        internal const int VK_RWIN = 0x5C;
        internal const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        internal const uint TOKEN_QUERY = 0x0008;
        internal const uint DESKTOP_READOBJECTS = 0x0001;
        internal const int TokenIntegrityLevel = 25;

        [StructLayout(LayoutKind.Sequential)] internal struct KBDLLHOOKSTRUCT
        {
            internal uint vkCode, scanCode, flags, time;
            internal UIntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)] internal struct MSLLHOOKSTRUCT
        {
            internal POINT pt;
            internal uint mouseData, flags, time;
            internal UIntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)] internal struct POINT { internal int x, y; }

        [StructLayout(LayoutKind.Sequential)] internal struct GUITHREADINFO
        {
            internal uint cbSize, flags;
            internal IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
            internal RECT rcCaret;
        }

        [StructLayout(LayoutKind.Sequential)] internal struct RECT { internal int left, top, right, bottom; }

        [StructLayout(LayoutKind.Sequential)] internal struct MSG
        {
            internal IntPtr hwnd;
            internal uint message;
            internal UIntPtr wParam;
            internal IntPtr lParam;
            internal uint time;
            internal POINT pt;
            internal uint lPrivate;
        }


        [UnmanagedFunctionPointer(CallingConvention.Winapi)] internal delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)] internal static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] internal static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] internal static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
        [DllImport("user32.dll")] internal static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] internal static extern bool TranslateMessage(ref MSG msg);
        [DllImport("user32.dll")] internal static extern IntPtr DispatchMessage(ref MSG msg);
        [DllImport("user32.dll", SetLastError = true)] internal static extern bool PostThreadMessage(uint threadId, uint message, UIntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] internal static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr GetModuleHandle(string? moduleName);
        [DllImport("kernel32.dll")] internal static extern ulong GetTickCount64();
        [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll", SetLastError = true)] internal static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
        [DllImport("user32.dll")] internal static extern IntPtr GetKeyboardLayout(uint threadId);
        [DllImport("user32.dll")] internal static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[]? layouts);
        [DllImport("user32.dll", SetLastError = true)] internal static extern bool PostMessage(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] internal static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr SendMessageTimeoutText(IntPtr hwnd, uint message, IntPtr wParam,
            [MarshalAs(UnmanagedType.LPWStr)] string text, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)] internal static extern int GetWindowStyle(IntPtr hwnd, int index);
        [DllImport("user32.dll")] internal static extern bool IsWindowUnicode(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern int GetClassName(IntPtr hwnd, StringBuilder buffer, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(IntPtr hwnd, StringBuilder buffer, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr GetProp(IntPtr hwnd, string name);
        [DllImport("user32.dll", SetLastError = true)] internal static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);
        [DllImport("user32.dll")] internal static extern IntPtr GetThreadDesktop(uint threadId);
        [DllImport("user32.dll")] internal static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern bool GetUserObjectInformation(IntPtr objectHandle, int index, StringBuilder info, uint length, out uint needed);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int needed);
        [DllImport("advapi32.dll")] internal static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
        [DllImport("advapi32.dll")] internal static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern uint GetPrivateProfileInt(string section, string key, uint defaultValue, string fileName);
    }
}
