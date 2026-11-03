using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Diagnostics;
using MacSwitcher.Core;
using MacSwitcher.Windows.Native;

namespace MacSwitcher.Windows.Runtime
{
    // CI-only private pipe. Commands contain fixed IDs, never target text or arbitrary HWNDs.
    internal static class RuntimeFixtureClient
    {
        private const string MarkerProperty = "MacSwitcher.RuntimeFixture";
        private const string BrowserMarkerProperty = "MacSwitcher.RuntimeBrowserFixture";

        internal static int Run(uint parentPid) { return RunInternal(parentPid, null); }

        internal static int RunBrowser(uint browserPid)
        {
            var pageMarker = Environment.GetEnvironmentVariable("MACSWITCHER_RUNTIME_BROWSER_FIXTURE_PAGE_MARKER");
            if (!ValidBrowserMarker(pageMarker)) return 2;
            return RunInternal(browserPid, pageMarker);
        }

        private static bool ValidBrowserMarker(string? pageMarker)
        {
            if (pageMarker == null || !(pageMarker.StartsWith("msw-input-", StringComparison.Ordinal) ||
                pageMarker.StartsWith("msw-textarea-", StringComparison.Ordinal))) return false;
            var separator = pageMarker.LastIndexOf('-');
            return separator >= 0 && pageMarker.Length - separator - 1 == 32 &&
                pageMarker.Substring(separator + 1).All(c => c >= '0' && c <= '9' ||
                    c >= 'a' && c <= 'f');
        }

        private static int RunInternal(uint targetPid, string? browserMarker)
        {
            long marker;
            var rawMarker = Environment.GetEnvironmentVariable("MACSWITCHER_RUNTIME_FIXTURE_MARKER");
            var data = Environment.GetEnvironmentVariable("MACSWITCHER_RUNTIME_FIXTURE_DATA");
            if (targetPid == 0 || !long.TryParse(rawMarker, NumberStyles.None,
                CultureInfo.InvariantCulture, out marker) || marker <= 0 ||
                string.IsNullOrEmpty(data) || !File.Exists(Path.Combine(data, "dictionary-manifest.json")) ||
                !OwnTargetForeground(targetPid, marker, browserMarker)) return 2;

            var settings = new AppSettings { Enabled = true, AutomaticCorrection = false,
                RussianPriority = true, DoubleShiftMilliseconds = 180 };
            using (var runtime = new WindowsSwitcherRuntime(settings, new PersonalLexicon(), data, true))
            using (var input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false, true)))
            using (var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)))
            {
                output.AutoFlush = true;
                int applied = 0, undone = 0;
                runtime.CorrectionApplied += _ => Interlocked.Increment(ref applied);
                runtime.CorrectionUndone += _ => Interlocked.Increment(ref undone);
                runtime.Start();
                if (!runtime.FixtureHookReady) { output.WriteLine("HOOK_UNAVAILABLE"); return 3; }
                long syntheticTick = (long)Win32.GetTickCount64();
                output.WriteLine("READY");
                while (true)
                {
                    var command = ReadBoundedLine(input);
                    if (command == null) return 0;
                    if (command == "EXIT") { output.WriteLine("BYE"); return 0; }
                    if (!OwnTargetForeground(targetPid, marker, browserMarker))
                    { output.WriteLine("REFUSED"); return 4; }
                    try
                    {
                        switch (command)
                        {
                            case "CACHE":
                                var cacheFocus = NativeFocusSnapshot.Capture();
                                var cacheStarted = (long)Win32.GetTickCount64();
                                var cacheDeadline = cacheStarted + 4000;
                                while (!runtime.FixtureCacheReadyFor(cacheFocus, cacheStarted) &&
                                    (long)Win32.GetTickCount64() < cacheDeadline)
                                    Thread.Sleep(20);
                                if (!runtime.FixtureCacheReadyFor(cacheFocus, cacheStarted))
                                { output.WriteLine("CACHE_NOT_READY"); return 7; }
                                break;
                            case "WAIT":
                                var workDeadline = (long)Win32.GetTickCount64() + 4000;
                                while ((long)Win32.GetTickCount64() < workDeadline)
                                {
                                    if (runtime.FixtureWorkSettled)
                                    {
                                        Thread.Sleep(20);
                                        if (runtime.FixtureWorkSettled) break;
                                    }
                                    Thread.Sleep(20);
                                }
                                if (!runtime.FixtureWorkSettled)
                                { output.WriteLine("WORK_NOT_READY"); return 8; }
                                break;
                            case "GAP": syntheticTick += 500; break;
                            case "TAP_L":
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyDown, Win32.VK_LSHIFT, 42, syntheticTick);
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyUp, Win32.VK_LSHIFT, 42, syntheticTick + 20);
                                syntheticTick += 80; break;
                            case "TAP_R":
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyDown, Win32.VK_RSHIFT, 54, syntheticTick);
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyUp, Win32.VK_RSHIFT, 54, syntheticTick + 20);
                                syntheticTick += 80; break;
                            case "CHORD_CTRL":
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyDown, Win32.VK_LSHIFT, 42, syntheticTick);
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyDown, Win32.VK_CONTROL, 29, syntheticTick + 10);
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyUp, Win32.VK_CONTROL, 29, syntheticTick + 20);
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyUp, Win32.VK_LSHIFT, 42, syntheticTick + 30);
                                syntheticTick += 80; break;
                            case "MOUSE_INTERRUPT":
                                runtime.EmitFixtureMouse(syntheticTick);
                                syntheticTick += 20; break;
                            case "KEY_D":
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyDown, 0x47, 34, syntheticTick);
                                syntheticTick += 10; break;
                            case "KEY_U":
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyUp, 0x47, 34, syntheticTick);
                                syntheticTick += 10; break;
                            case "SPACE_D":
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyDown, 0x20, 57, syntheticTick);
                                syntheticTick += 10; break;
                            case "SPACE_U":
                                runtime.EmitFixtureKey(PhysicalInputKind.KeyUp, 0x20, 57, syntheticTick);
                                syntheticTick += 10; break;
                            case "AUTO_ON":
                                settings = new AppSettings { Enabled = true, AutomaticCorrection = true,
                                    RussianPriority = true, DoubleShiftMilliseconds = 180 };
                                runtime.ApplySettings(settings); break;
                            case "AUTO_OFF":
                                settings = new AppSettings { Enabled = true, AutomaticCorrection = false,
                                    RussianPriority = true, DoubleShiftMilliseconds = 180 };
                                runtime.ApplySettings(settings); break;
                            case "SET_EN":
                                if (!runtime.TrySwitchLayout("en"))
                                { output.WriteLine("SOURCE_UNAVAILABLE"); return 9; }
                                break;
                            case "STATE": break;
                            default: output.WriteLine("REFUSED"); return 5;
                        }
                        output.WriteLine("OK|" + Volatile.Read(ref applied) + "|" +
                            Volatile.Read(ref undone) + "|" + runtime.CurrentLayoutLanguage + "|" +
                            (runtime.HasRecoveryOriginals ? "1" : "0") + "|" +
                            runtime.FixtureManualCode + "|" + runtime.FixtureNativeCode + "|" +
                            runtime.FixtureNativeBrokerOutcome + "|" + runtime.FixtureNativeBrokerStage + "|" +
                            runtime.FixtureNativeBudgetMilliseconds + "|" +
                            runtime.FixtureNativeBrokerPhase + "|" +
                            runtime.FixtureNativeRpcMilliseconds + "|" + runtime.FixtureShiftCode + "|" +
                            runtime.FixtureResetReason + "|" + runtime.FixtureFullBrokerOutcome + "|" +
                            runtime.FixtureFullBrokerPhase + "|" + runtime.FixtureFullBudgetMilliseconds + "|" +
                            runtime.FixtureFullRpcMilliseconds);
                    }
                    catch { output.WriteLine("ERROR"); return 6; }
                }
            }
        }

        private static bool OwnFixtureForeground(uint pid, long marker)
        {
            var foreground = Win32.GetForegroundWindow();
            if (foreground == IntPtr.Zero) return false;
            uint actualPid;
            Win32.GetWindowThreadProcessId(foreground, out actualPid);
            if (actualPid != pid || Win32.GetProp(foreground, MarkerProperty).ToInt64() != marker)
                return false;
            var title = new StringBuilder(128);
            return Win32.GetWindowText(foreground, title, title.Capacity) > 0 &&
                title.ToString() == "MacSwitcher synthetic fixture";
        }

        private static bool OwnTargetForeground(uint pid, long marker, string? browserMarker)
        {
            if (browserMarker == null) return OwnFixtureForeground(pid, marker);
            var foreground = Win32.GetForegroundWindow();
            if (foreground == IntPtr.Zero) return false;
            uint actualPid;
            Win32.GetWindowThreadProcessId(foreground, out actualPid);
            if (actualPid != pid ||
                Win32.GetProp(foreground, BrowserMarkerProperty).ToInt64() != marker) return false;
            try
            {
                if (!Process.GetProcessById((int)pid).ProcessName.Equals("msedge",
                    StringComparison.OrdinalIgnoreCase)) return false;
            }
            catch { return false; }
            var title = new StringBuilder(256);
            return Win32.GetWindowText(foreground, title, title.Capacity) > 0 &&
                title.ToString().StartsWith(browserMarker + "-", StringComparison.Ordinal);
        }

        private static string? ReadBoundedLine(StreamReader input)
        {
            var builder = new StringBuilder(32);
            while (true)
            {
                int code = input.Read();
                if (code < 0) return builder.Length == 0 ? null : "";
                if (code == '\n') return builder.ToString();
                if (code == '\r') continue;
                if (builder.Length >= 32) return "";
                builder.Append((char)code);
            }
        }
    }
}
