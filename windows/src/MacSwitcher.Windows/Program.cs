using System;
using System.IO;
using System.Text;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;
using MacSwitcher.Windows.Automation;
using MacSwitcher.Windows.Native;
using MacSwitcher.Windows.Runtime;
using MacSwitcher.Windows.Storage;
using MacSwitcher.Windows.UI;

namespace MacSwitcher.Windows
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 1 && args[0] == "--automation-broker")
                return AutomationBrokerServer.Run();
            if (args.Length == 1 && args[0] == "--runtime-contract-tests")
                return RuntimeContractChecks.Run();
            if (args.Length == 1 && args[0] == "--hook-registration-test")
                return RunHookRegistrationTest();
            if (args.Length == 1 && args[0] == "--broker-protocol-fixture")
                return RunBrokerProtocolFixture();
            uint fixturePid;
            if (args.Length == 2 && args[0] == "--runtime-fixture-client" &&
                uint.TryParse(args[1], out fixturePid))
                return RuntimeFixtureClient.Run(fixturePid);
            if (args.Length == 2 && args[0] == "--runtime-browser-fixture-client" &&
                uint.TryParse(args[1], out fixturePid))
                return RuntimeFixtureClient.RunBrowser(fixturePid);
            if (args.Length != 0 && (args.Length != 1 ||
                args[0] != "--settings" && args[0] != "--quit")) return 2;
            var quitRequested = args.Length == 1 && args[0] == "--quit";

            var sid = WindowsIdentity.GetCurrent().User?.Value;
            if (string.IsNullOrEmpty(sid)) return 2;
            var objectName = "Local\\MacSwitcher.Windows." + sid;
            bool isFirst;
            using (var mutex = new Mutex(true, "Local\\MacSwitcher.Windows.Mutex", out isFirst))
            {
                if (!isFirst)
                {
                    var eventName = objectName + (quitRequested ? ".Quit" : ".ShowSettings");
                    for (int attempt = 0; attempt < 20; attempt++)
                    {
                        try
                        {
                            using (var duplicateSignal = EventWaitHandle.OpenExisting(eventName)) duplicateSignal.Set();
                            return 0;
                        }
                        catch (WaitHandleCannotBeOpenedException) { Thread.Sleep(50); }
                    }
                    return 3;
                }
                if (quitRequested) { mutex.ReleaseMutex(); return 0; }
                using (var signal = new EventWaitHandle(false, EventResetMode.AutoReset, objectName + ".ShowSettings"))
                using (var quitSignal = new EventWaitHandle(false, EventResetMode.AutoReset, objectName + ".Quit"))
                {
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    var storeDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MacSwitcherWindows");
                    var showSettings = args.Length == 1 || !File.Exists(Path.Combine(storeDirectory, "settings.json"));
                    var store = new ConfigurationStore(storeDirectory);
                    store.Load();
                    var dataDirectory = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "data");
                    using (var runtime = new WindowsSwitcherRuntime(store.Settings, store.Personal, dataDirectory))
                    using (var context = new SwitcherContext(runtime, store, showSettings))
                    {
                        var listening = true;
                        var listener = new Thread(() =>
                        {
                            while (Volatile.Read(ref listening))
                            {
                                var request = WaitHandle.WaitAny(new WaitHandle[] { signal, quitSignal }, 250);
                                if (!Volatile.Read(ref listening)) break;
                                if (request == 0) context.ShowSettingsFromDuplicate();
                                else if (request == 1) context.RequestQuitFromDuplicate();
                            }
                        }) { IsBackground = true, Name = "MacSwitcher single instance" };
                        listener.Start();
                        runtime.Start();
                        Application.Run(context);
                        Volatile.Write(ref listening, false);
                        signal.Set();
                        quitSignal.Set();
                        listener.Join(500);
                        mutex.ReleaseMutex();
                        context.LaunchPendingInstaller();
                    }
                }
                try { mutex.ReleaseMutex(); } catch (ApplicationException) { }
            }
            return 0;
        }

        private static int RunHookRegistrationTest()
        {
            using (var hook = new PhysicalHookHost())
            {
                bool ready = false;
                try { hook.Start(); ready = hook.Ready; }
                catch { }
                using (var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)))
                {
                    output.Write("{\"status\":\"");
                    output.Write(ready ? "PASS" : "FAIL");
                    output.Write("\",\"keyboardCode\":");
                    output.Write(hook.KeyboardRegistrationError);
                    output.Write(",\"mouseCode\":");
                    output.Write(hook.MouseRegistrationError);
                    output.Write('}');
                    output.Flush();
                }
                return ready ? 0 : 1;
            }
        }

        private static int RunBrokerProtocolFixture()
        {
            var response = new BrokerResponse
            {
                Outcome = BrokerOutcome.Success, Stage = BrokerStage.SelectionRange,
                Phase = BrokerPhase.NativeFinalAck,
                NativeError = 5, HResult = 12345, DiagnosticTextLength = 7,
                DiagnosticSelectionStart = 2, DiagnosticSelectionEnd = 4,
                DiagnosticNativeClassKind = 1,
                Field = new FieldSnapshot
                {
                    Foreground = new IntPtr(11), Focus = new IntPtr(12),
                    ProcessId = 13, ThreadId = 14, RuntimeId = new[] { 15, 16 },
                    Value = "fixture", SelectionStart = 2, SelectionEnd = 4,
                    CanWrite = true, NativeRangeWriter = true
                }
            };
            using (var output = new BinaryWriter(Console.OpenStandardOutput(), Encoding.UTF8))
                BrokerWire.WriteFrame(output, BrokerWire.EncodeResponse(response));
            return 0;
        }
    }
}
