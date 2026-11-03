using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32;

namespace MacSwitcher.Windows.Native
{
    internal enum PhysicalInputKind { KeyDown, KeyUp, Mouse, Overflow }

    internal sealed class PhysicalInput
    {
        internal PhysicalInputKind Kind;
        internal int VirtualKey;
        internal uint ScanCode;
        internal long Timestamp;
        internal long Revision;
        internal NativeFocusSnapshot? Focus;
    }

    internal sealed class InputFence : IDisposable
    {
        private readonly PhysicalHookHost owner;
        private readonly ManualResetEventSlim release = new ManualResetEventSlim(false);
        private int compromised;
        private int disposed;
        internal readonly long DeadlineTicks;

        internal InputFence(PhysicalHookHost owner, int milliseconds)
        {
            this.owner = owner;
            DeadlineTicks = (long)Win32.GetTickCount64() + milliseconds;
        }

        internal bool Compromised { get { return Volatile.Read(ref compromised) != 0; } }
        internal void MarkCompromised() { Interlocked.Exchange(ref compromised, 1); }
        internal void WaitForRelease()
        {
            var remaining = (int)Math.Max(0, DeadlineTicks - (long)Win32.GetTickCount64());
            if (!release.Wait(remaining)) MarkCompromised();
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            owner.EndFence(this);
            release.Set();
        }
    }

    internal sealed class PhysicalHookHost : IDisposable
    {
        internal static bool IsPassiveMouseMessage(int message) { return message == Win32.WM_MOUSEMOVE; }
        // KBDLLHOOKSTRUCT.time is a 32-bit physical event timestamp. Extend it to the
        // nearest GetTickCount64 epoch before any input-fence wait or dispatch delay.
        internal static long ExtendEventTime(uint eventTime, ulong arrivalTick)
        {
            var elapsed = unchecked((int)((uint)arrivalTick - eventTime));
            return (long)arrivalTick - elapsed;
        }
        private readonly ConcurrentQueue<PhysicalInput> queue = new ConcurrentQueue<PhysicalInput>();
        private readonly AutoResetEvent queueReady = new AutoResetEvent(false);
        private readonly ManualResetEventSlim ready = new ManualResetEventSlim(false);
        private readonly Win32.HookProc keyboardCallback;
        private readonly Win32.HookProc mouseCallback;
        private readonly bool syntheticFixtureOnly;
        private Thread? hookThread, dispatchThread;
        private IntPtr keyboardHook, mouseHook;
        private int keyboardRegistrationError, mouseRegistrationError;
        private uint hookThreadId;
        private int count, running, overflow;
        private long revision;
        private long disruptiveRevision;
        private InputFence? activeFence;
        private readonly object fenceGate = new object();
        private readonly int maxFenceMilliseconds;

        internal event Action<PhysicalInput>? PhysicalEvent;
        internal long Revision { get { return Interlocked.Read(ref revision); } }
        internal long DisruptiveRevision { get { return Interlocked.Read(ref disruptiveRevision); } }
        internal bool Ready { get { return keyboardHook != IntPtr.Zero && mouseHook != IntPtr.Zero && Volatile.Read(ref running) != 0; } }
        internal int KeyboardRegistrationError { get { return Volatile.Read(ref keyboardRegistrationError); } }
        internal int MouseRegistrationError { get { return Volatile.Read(ref mouseRegistrationError); } }

        internal PhysicalHookHost(bool syntheticFixtureOnly = false)
        {
            this.syntheticFixtureOnly = syntheticFixtureOnly;
            keyboardCallback = Keyboard;
            mouseCallback = Mouse;
            maxFenceMilliseconds = ReadFenceBudget();
        }

        private static int ReadFenceBudget()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop"))
                {
                    var raw = key == null ? null : key.GetValue("LowLevelHooksTimeout");
                    int timeout;
                    if (raw != null && int.TryParse(raw.ToString(), out timeout))
                        return timeout < 120 ? 0 : Math.Min(120, timeout / 2);
                }
            }
            catch { return 0; }
            return 100;
        }

        internal void Start()
        {
            if (Interlocked.Exchange(ref running, 1) != 0) return;
            hookThread = new Thread(HookLoop) { IsBackground = true, Name = "MacSwitcher physical hook" };
            dispatchThread = new Thread(DispatchLoop) { IsBackground = true, Name = "MacSwitcher input dispatch" };
            hookThread.Start();
            if (!ready.Wait(2000) || !Ready)
            {
                Dispose();
                throw new InvalidOperationException("Keyboard monitoring is unavailable.");
            }
            dispatchThread.Start();
        }

        private void HookLoop()
        {
            hookThreadId = Win32.GetCurrentThreadId();
            Win32.MSG msg;
            Win32.PeekMessage(out msg, IntPtr.Zero, 0, 0, 0);
            var module = Win32.GetModuleHandle(null);
            keyboardHook = Win32.SetWindowsHookEx(Win32.WH_KEYBOARD_LL, keyboardCallback, module, 0);
            if (keyboardHook == IntPtr.Zero) keyboardRegistrationError = Marshal.GetLastWin32Error();
            mouseHook = Win32.SetWindowsHookEx(Win32.WH_MOUSE_LL, mouseCallback, module, 0);
            if (mouseHook == IntPtr.Zero) mouseRegistrationError = Marshal.GetLastWin32Error();
            ready.Set();
            if (keyboardHook == IntPtr.Zero || mouseHook == IntPtr.Zero)
            {
                if (keyboardHook != IntPtr.Zero) Win32.UnhookWindowsHookEx(keyboardHook);
                if (mouseHook != IntPtr.Zero) Win32.UnhookWindowsHookEx(mouseHook);
                keyboardHook = mouseHook = IntPtr.Zero;
                return;
            }
            while (Volatile.Read(ref running) != 0 && Win32.GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
            {
                Win32.TranslateMessage(ref msg);
                Win32.DispatchMessage(ref msg);
            }
            Win32.UnhookWindowsHookEx(keyboardHook);
            Win32.UnhookWindowsHookEx(mouseHook);
            keyboardHook = mouseHook = IntPtr.Zero;
        }

        private IntPtr Keyboard(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code < 0) return Win32.CallNextHookEx(keyboardHook, code, wParam, lParam);
            if (syntheticFixtureOnly)
                return Win32.CallNextHookEx(keyboardHook, code, wParam, lParam);
            try
            {
                var data = (Win32.KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Win32.KBDLLHOOKSTRUCT));
                if ((data.flags & Win32.LLKHF_INJECTED) != 0)
                {
                    WaitFenceIfNeeded();
                    Interlocked.Increment(ref disruptiveRevision);
                    Enqueue(new PhysicalInput { Kind = PhysicalInputKind.Overflow,
                        Revision = Interlocked.Increment(ref revision) });
                    return Win32.CallNextHookEx(keyboardHook, code, wParam, lParam);
                }
                var message = wParam.ToInt32();
                var kind = message == Win32.WM_KEYDOWN || message == Win32.WM_SYSKEYDOWN
                    ? PhysicalInputKind.KeyDown : PhysicalInputKind.KeyUp;
                var arrival = Win32.GetTickCount64();
                var timestamp = ExtendEventTime(data.time, arrival);
                WaitFenceIfNeeded();
                if (data.vkCode != Win32.VK_SHIFT && data.vkCode != Win32.VK_LSHIFT &&
                    data.vkCode != Win32.VK_RSHIFT)
                    Interlocked.Increment(ref disruptiveRevision);
                var rev = Interlocked.Increment(ref revision);
                Enqueue(new PhysicalInput { Kind = kind, VirtualKey = (int)data.vkCode, ScanCode = data.scanCode,
                    Timestamp = timestamp, Revision = rev, Focus = NativeFocusSnapshot.Capture() });
            }
            catch { Interlocked.Increment(ref disruptiveRevision); Interlocked.Exchange(ref overflow, 1); }
            return Win32.CallNextHookEx(keyboardHook, code, wParam, lParam);
        }

        private IntPtr Mouse(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code < 0) return Win32.CallNextHookEx(mouseHook, code, wParam, lParam);
            if (syntheticFixtureOnly)
                return Win32.CallNextHookEx(mouseHook, code, wParam, lParam);
            if (IsPassiveMouseMessage(wParam.ToInt32()))
                return Win32.CallNextHookEx(mouseHook, code, wParam, lParam);
            try
            {
                var data = (Win32.MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Win32.MSLLHOOKSTRUCT));
                if ((data.flags & Win32.LLMHF_INJECTED) != 0)
                {
                    WaitFenceIfNeeded();
                    Interlocked.Increment(ref disruptiveRevision);
                    Enqueue(new PhysicalInput { Kind = PhysicalInputKind.Overflow,
                        Revision = Interlocked.Increment(ref revision) });
                    return Win32.CallNextHookEx(mouseHook, code, wParam, lParam);
                }
                var timestamp = (long)Win32.GetTickCount64();
                WaitFenceIfNeeded();
                Interlocked.Increment(ref disruptiveRevision);
                var rev = Interlocked.Increment(ref revision);
                Enqueue(new PhysicalInput { Kind = PhysicalInputKind.Mouse, Revision = rev, Timestamp = timestamp,
                    Focus = NativeFocusSnapshot.Capture() });
            }
            catch { Interlocked.Increment(ref disruptiveRevision); Interlocked.Exchange(ref overflow, 1); }
            return Win32.CallNextHookEx(mouseHook, code, wParam, lParam);
        }

        private void WaitFenceIfNeeded()
        {
            InputFence? fence;
            lock (fenceGate) fence = activeFence;
            if (fence != null) fence.WaitForRelease();
        }

        private void Enqueue(PhysicalInput item)
        {
            if (Interlocked.Increment(ref count) > 512)
            {
                Interlocked.Decrement(ref count);
                Interlocked.Increment(ref disruptiveRevision);
                Interlocked.Exchange(ref overflow, 1);
            }
            else queue.Enqueue(item);
            queueReady.Set();
        }

        // Test-only adapter: the caller is restricted by Program's own fixture PID/title gate.
        // It drives the same production observer with a synthetic event, without SendInput.
        internal void EmitFixtureKey(PhysicalInputKind kind, int virtualKey, uint scanCode, long timestamp)
        {
            if (!Ready || kind != PhysicalInputKind.KeyDown && kind != PhysicalInputKind.KeyUp)
                throw new InvalidOperationException("Fixture hook unavailable.");
            WaitFenceIfNeeded();
            if (virtualKey != Win32.VK_SHIFT && virtualKey != Win32.VK_LSHIFT &&
                virtualKey != Win32.VK_RSHIFT)
                Interlocked.Increment(ref disruptiveRevision);
            var item = new PhysicalInput { Kind = kind, VirtualKey = virtualKey,
                ScanCode = scanCode, Timestamp = timestamp,
                Revision = Interlocked.Increment(ref revision), Focus = NativeFocusSnapshot.Capture() };
            PhysicalEvent?.Invoke(item);
        }

        internal void EmitFixtureMouse(long timestamp)
        {
            if (!Ready) throw new InvalidOperationException("Fixture hook unavailable.");
            WaitFenceIfNeeded();
            Interlocked.Increment(ref disruptiveRevision);
            var item = new PhysicalInput { Kind = PhysicalInputKind.Mouse,
                Timestamp = timestamp, Revision = Interlocked.Increment(ref revision),
                Focus = NativeFocusSnapshot.Capture() };
            PhysicalEvent?.Invoke(item);
        }

        private void DispatchLoop()
        {
            while (Volatile.Read(ref running) != 0)
            {
                queueReady.WaitOne(100);
                if (Interlocked.Exchange(ref overflow, 0) != 0)
                    PhysicalEvent?.Invoke(new PhysicalInput { Kind = PhysicalInputKind.Overflow, Revision = Revision });
                PhysicalInput item;
                while (queue.TryDequeue(out item))
                {
                    Interlocked.Decrement(ref count);
                    try { PhysicalEvent?.Invoke(item); }
                    catch { /* Never terminate dispatch because an observer failed. */ }
                }
            }
        }

        internal InputFence? BeginFence(long expectedRevision)
        {
            if (!Ready || maxFenceMilliseconds == 0 || Revision != expectedRevision || !NativeSafety.ModifiersUp()) return null;
            lock (fenceGate)
            {
                if (activeFence != null || Revision != expectedRevision) return null;
                activeFence = new InputFence(this, maxFenceMilliseconds);
                return activeFence;
            }
        }

        internal void EndFence(InputFence fence)
        {
            lock (fenceGate) if (ReferenceEquals(activeFence, fence)) activeFence = null;
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref running, 0) == 0) return;
            lock (fenceGate) { activeFence?.Dispose(); activeFence = null; }
            if (hookThreadId != 0) Win32.PostThreadMessage(hookThreadId, Win32.WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
            queueReady.Set();
            if (hookThread != null && hookThread != Thread.CurrentThread) hookThread.Join(500);
            if (dispatchThread != null && dispatchThread != Thread.CurrentThread) dispatchThread.Join(500);
            queueReady.Dispose();
            ready.Dispose();
        }
    }
}
