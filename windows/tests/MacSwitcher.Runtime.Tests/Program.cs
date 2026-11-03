using System.Diagnostics;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;
using System.Windows.Automation;
using MacSwitcher.Windows.UI;

// Own-process synthetic controls only. Output is a closed status, never field contents.
internal static class Program
{
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SetProp(IntPtr hwnd, string name, IntPtr value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetProp(IntPtr hwnd, string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr RemoveProp(IntPtr hwnd, string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadKeyboardLayout(string id, uint flags);
    [DllImport("user32.dll")] private static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[]? layouts);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint MsgWaitForMultipleObjectsEx(uint count, IntPtr handles,
        uint milliseconds, uint wakeMask, uint flags);
    private const uint QS_ALLINPUT = 0x04FF;
    private const uint MWMO_INPUTAVAILABLE = 0x0004;
    private static string edgeInput = "NOT_RUN";
    private static string edgeTextarea = "NOT_RUN";
    private static readonly EdgeProbeReceipt edgeInputReceipt = new EdgeProbeReceipt();
    private static readonly EdgeProbeReceipt edgeTextareaReceipt = new EdgeProbeReceipt();
    private static string edgeInputRuntime = "NOT_RUN", edgeTextareaRuntime = "NOT_RUN";
    private static readonly EdgeRuntimeReceipt edgeInputRuntimeReceipt = new EdgeRuntimeReceipt();
    private static readonly EdgeRuntimeReceipt edgeTextareaRuntimeReceipt = new EdgeRuntimeReceipt();
    private static string hookStatus = "NOT_RUN";
    private static string integrationStatus = "NOT_RUN";
    private static string integrationProbe = "NOT_RUN";
    private static string integrationLayout = "";
    private static int integrationApplied, integrationUndone, integrationTextLength = -1;
    private static bool integrationExpectedText;
    private static int integrationManualCode;
    private static int integrationShiftCode;
    private static int integrationResetReason;
    private static int integrationNativeCode, integrationNativeBrokerOutcome = -1;
    private static int integrationNativeBrokerStage = -1, integrationNativeBudgetMilliseconds = -1;
    private static int integrationNativeBrokerPhase = -1;
    private static int integrationNativeRpcMilliseconds = -1;
    private static int integrationFullBrokerOutcome = -1, integrationFullBrokerPhase = -1;
    private static int integrationFullBudgetMilliseconds = -1, integrationFullRpcMilliseconds = -1;
    private static int integrationAutoCode, integrationAutoSourceCode;
    private static string integrationWaitStatus = "NOT_RUN";
    private static string brokerProbe = "NOT_RUN";
    private static int brokerRestartCount;
    private static int brokerOutcome = -1, brokerStage = -1;
    private static int brokerPhase = -1;
    private static int brokerNativeCode;
    private static int brokerHResult;
    private static bool fixtureForeground, fixtureFocus;
    private static int brokerTextLength = -1, brokerSelectionStart = -1, brokerSelectionEnd = -1;
    private static int brokerNativeClassKind = -1;
    private static bool brokerSameFixturePid, brokerFocusMatchesPlain;
    private static int brokerObservedTextLength = -1, brokerObservedSelectionStart = -1;
    private static int brokerObservedSelectionEnd = -1;
    private static bool brokerObservedIdentity, brokerObservedValueMatched;
    private static int hookKeyboardCode, hookMouseCode;

    [StructLayout(LayoutKind.Sequential)] private struct GuiThreadInfo
    {
        public uint cbSize, flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public int left, top, right, bottom;
    }

    private sealed class Field
    {
        public long Foreground, Focus;
        public uint Pid, Tid;
        public int[] Id = [];
        public string Text = "";
        public int Start, End;
        public bool CanWrite;
        public bool NativeRangeWriter;
    }

    private sealed class Result
    {
        public byte Outcome;
        public byte Stage;
        public byte Phase;
        public int NativeError;
        public int HResult;
        public int DiagnosticTextLength, DiagnosticStart, DiagnosticEnd;
        public int DiagnosticNativeClassKind;
        public bool UiAvailable, UiSameRuntimeId, UiHasKeyboardFocus;
        public bool UiSameProcess, UiEditType, UiCredentialFlagClear, UiEnabled;
        public bool NativeSameRoot, NativeSameProcess, NativeSameThread;
        public Field? Field;
    }

    private sealed class EdgeProbeReceipt
    {
        internal string Status = "NOT_RUN";
        internal int CaptureOutcome = -1, CaptureStage = -1, CapturePhase = -1;
        internal int WriteOutcome = -1, WriteStage = -1, WritePhase = -1, WriteHResult;
        internal bool OwnWindowAtCapture, OwnWindowAtWrite, CanWrite, InitialTextMatched;
        internal bool DomEventAck, DomValueAck, DomActiveAck, DomDocumentFocused;
        internal bool UiAvailable, UiSameRuntimeId, UiHasKeyboardFocus;
        internal bool UiSameProcess, UiEditType, UiCredentialFlagClear, UiEnabled;
        internal bool NativeSameRoot, NativeSameProcess, NativeSameThread;

        internal string Json()
        {
            return "{\"status\":\"" + Status + "\",\"captureOutcome\":" + CaptureOutcome +
                ",\"captureStage\":" + CaptureStage + ",\"capturePhase\":" + CapturePhase +
                ",\"writeOutcome\":" + WriteOutcome + ",\"writeStage\":" + WriteStage +
                ",\"writePhase\":" + WritePhase + ",\"writeHResult\":" + WriteHResult +
                ",\"ownWindowAtCapture\":" + (OwnWindowAtCapture ? "true" : "false") +
                ",\"ownWindowAtWrite\":" + (OwnWindowAtWrite ? "true" : "false") +
                ",\"canWrite\":" + (CanWrite ? "true" : "false") +
                ",\"initialTextMatched\":" + (InitialTextMatched ? "true" : "false") +
                ",\"domEventAck\":" + (DomEventAck ? "true" : "false") +
                ",\"domValueAck\":" + (DomValueAck ? "true" : "false") +
                ",\"domActiveAck\":" + (DomActiveAck ? "true" : "false") +
                ",\"domDocumentFocused\":" + (DomDocumentFocused ? "true" : "false") +
                ",\"uiAvailable\":" + (UiAvailable ? "true" : "false") +
                ",\"uiSameRuntimeId\":" + (UiSameRuntimeId ? "true" : "false") +
                ",\"uiHasKeyboardFocus\":" + (UiHasKeyboardFocus ? "true" : "false") +
                ",\"uiSameProcess\":" + (UiSameProcess ? "true" : "false") +
                ",\"uiEditType\":" + (UiEditType ? "true" : "false") +
                ",\"uiCredentialFlagClear\":" + (UiCredentialFlagClear ? "true" : "false") +
                ",\"uiEnabled\":" + (UiEnabled ? "true" : "false") +
                ",\"nativeSameRoot\":" + (NativeSameRoot ? "true" : "false") +
                ",\"nativeSameProcess\":" + (NativeSameProcess ? "true" : "false") +
                ",\"nativeSameThread\":" + (NativeSameThread ? "true" : "false") + "}";
        }
    }

    private sealed class EdgeRuntimeReceipt
    {
        internal string Status = "NOT_RUN";
        internal bool OwnWindow, DomEventAck, DomValueAck, DomActiveAck, DomDocumentFocused, Recovery;
        internal string InitialLayout = "", FinalLayout = "";
        internal int Applied, FullOutcome = -1, FullPhase = -1;
        internal int FullBudgetMilliseconds = -1, FullRpcMilliseconds = -1;

        internal string Json()
        {
            return "{\"status\":\"" + Status + "\",\"ownWindow\":" +
                (OwnWindow ? "true" : "false") + ",\"initialLayout\":\"" + InitialLayout +
                "\",\"finalLayout\":\"" + FinalLayout +
                "\",\"applied\":" + Applied + ",\"fullOutcome\":" + FullOutcome +
                ",\"fullPhase\":" + FullPhase +
                ",\"fullBudgetMilliseconds\":" + FullBudgetMilliseconds +
                ",\"fullRpcMilliseconds\":" + FullRpcMilliseconds +
                ",\"recovery\":" + (Recovery ? "true" : "false") +
                ",\"domEventAck\":" + (DomEventAck ? "true" : "false") +
                ",\"domValueAck\":" + (DomValueAck ? "true" : "false") +
                ",\"domActiveAck\":" + (DomActiveAck ? "true" : "false") +
                ",\"domDocumentFocused\":" + (DomDocumentFocused ? "true" : "false") + "}";
        }
    }

    private sealed class SelectionDriftTextBox : TextBox
    {
        internal bool DriftNextSelection;

        protected override void WndProc(ref Message message)
        {
            base.WndProc(ref message);
            if (message.Msg != 0x00B1 || !DriftNextSelection) return; // EM_SETSEL
            DriftNextSelection = false; // Clear before SelectionStart sends a nested EM_SETSEL.
            SelectionStart = 0;
            SelectionLength = 0;
        }
    }

    [STAThread]
    private static int Main()
    {
        var path = Environment.GetEnvironmentVariable("MACSWITCHER_WINDOWS_EXE");
        if (string.IsNullOrEmpty(path)) path = Path.Combine(Directory.GetCurrentDirectory(),
            "windows", "src", "MacSwitcher.Windows", "bin", "Release", "net462", "MacSwitcher.Windows.exe");
        if (!File.Exists(path)) return Report("FAIL", "app_build_missing", 0);
        var installIntent = new UpdateInstallIntent();
        if (installIntent.TryConsume()) return Report("FAIL", "unrequested_update_launch", 0);
        installIntent.Grant(); installIntent.Cancel();
        if (installIntent.TryConsume()) return Report("FAIL", "declined_update_launch", 0);
        installIntent.Grant();
        if (!installIntent.TryConsume() || installIntent.TryConsume())
            return Report("FAIL", "update_intent_not_one_use", 0);
        using (var protocol = Process.Start(new ProcessStartInfo(path, "--broker-protocol-fixture")
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true }))
        {
            if (protocol == null || !protocol.WaitForExit(5000) || protocol.ExitCode != 0)
                return Report("FAIL", "broker_protocol_process", 0);
            try
            {
                using var input = new BinaryReader(protocol.StandardOutput.BaseStream, Encoding.UTF8);
                var frame = Broker.ReadResponse(input);
                if (frame.Outcome != 1 || frame.Stage != 15 || frame.Phase != 9 ||
                    frame.NativeError != 5 || frame.HResult != 12345 ||
                    frame.DiagnosticTextLength != 7 || frame.DiagnosticStart != 2 ||
                    frame.DiagnosticEnd != 4 || frame.DiagnosticNativeClassKind != 1 ||
                    frame.Field?.Text != "fixture" || frame.Field.Start != 2 || frame.Field.End != 4 ||
                    !frame.Field.NativeRangeWriter || !frame.UiAvailable ||
                    !frame.UiSameRuntimeId || !frame.UiHasKeyboardFocus ||
                    !frame.NativeSameRoot || !frame.NativeSameProcess || !frame.NativeSameThread)
                    return Report("FAIL", "broker_protocol_schema", 0);
            }
            catch { return Report("FAIL", "broker_protocol_parse", 0); }
        }
        using (var contracts = Process.Start(new ProcessStartInfo(path, "--runtime-contract-tests")
        { UseShellExecute = false, CreateNoWindow = true }))
        {
            if (contracts == null || !contracts.WaitForExit(5000) || contracts.ExitCode != 0)
                return Report("FAIL", "runtime_pure_state", 0);
        }
        Application.EnableVisualStyles();
        using var form = new Form { Width = 400, Height = 360, Text = "MacSwitcher synthetic fixture" };
        using var plain = new TextBox { Left = 10, Top = 10, Width = 320, Text = "ghbdtn" };
        using var password = new TextBox { Left = 10, Top = 45, Width = 320, Text = "synthetic-secret", UseSystemPasswordChar = true };
        using var readOnly = new TextBox { Left = 10, Top = 80, Width = 320, Text = "readonly", ReadOnly = true };
        using var rich = new RichTextBox { Left = 10, Top = 115, Width = 320, Height = 55, Text = "rich" };
        using var drift = new SelectionDriftTextBox { Left = 10, Top = 180, Width = 320, Text = "ghbdtn" };
        using var multiline = new TextBox { Left = 10, Top = 215, Width = 320, Height = 80,
            Multiline = true, AcceptsReturn = true, AcceptsTab = true };
        form.Controls.AddRange([plain, password, readOnly, rich, drift, multiline]);
        form.Show();
        form.Activate();
        plain.Focus();
        plain.SelectionStart = plain.TextLength;
        Application.DoEvents();
        using (var hookProbe = Process.Start(new ProcessStartInfo(path, "--hook-registration-test")
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true }))
        {
            if (hookProbe == null || !hookProbe.WaitForExit(5000))
            {
                try { hookProbe?.Kill(); } catch { }
                return Report("FAIL", "hook_registration_timeout", 4);
            }
            var response = hookProbe.StandardOutput.ReadToEnd();
            try
            {
                using var json = JsonDocument.Parse(response);
                hookStatus = json.RootElement.GetProperty("status").GetString() ?? "FAIL";
                hookKeyboardCode = json.RootElement.GetProperty("keyboardCode").GetInt32();
                hookMouseCode = json.RootElement.GetProperty("mouseCode").GetInt32();
            }
            catch { return Report("FAIL", "hook_registration_response", 4); }
            if (hookProbe.ExitCode != 0 || hookStatus != "PASS")
                return Report("FAIL", "hook_registration", 4);
        }
        if (GetForegroundWindow() != form.Handle || !plain.Focused)
            return Report("NOT_RUN", "no_interactive_fixture_focus", 5);
        fixtureForeground = GetForegroundWindow() == form.Handle;
        fixtureFocus = plain.Focused;

        var broker = new Broker(path);
        int checks = 5;
        try
        {
            Result? captured = null;
            for (int attempt = 0; attempt < 4; attempt++)
            {
                var attemptBroker = broker;
                captured = PumpBroker(() => attemptBroker.Call(1, null, null),
                    attempt == 0 ? 10000 : 3000, out brokerProbe);
                if (captured == null)
                {
                    if (brokerProbe != "RPC_TIMEOUT" || brokerRestartCount != 0)
                        return Report("FAIL", "plain_capture_rpc", checks);
                    attemptBroker.Dispose();
                    broker = new Broker(path);
                    brokerRestartCount++;
                    if (!Focus(form, plain)) return Report("FAIL", "plain_capture_refocus", checks);
                    continue;
                }
                brokerOutcome = captured.Outcome;
                brokerStage = captured.Stage;
                brokerPhase = captured.Phase;
                brokerNativeCode = captured.NativeError;
                brokerHResult = captured.HResult;
                brokerTextLength = captured.DiagnosticTextLength;
                brokerSelectionStart = captured.DiagnosticStart;
                brokerSelectionEnd = captured.DiagnosticEnd;
                brokerNativeClassKind = captured.DiagnosticNativeClassKind;
                if (captured.Field != null)
                {
                    brokerTextLength = captured.Field.Text.Length;
                    brokerSelectionStart = captured.Field.Start;
                    brokerSelectionEnd = captured.Field.End;
                    brokerSameFixturePid = captured.Field.Pid == Environment.ProcessId;
                    brokerFocusMatchesPlain = captured.Field.Focus == plain.Handle.ToInt64();
                }
                if (captured?.Outcome == 1 && captured.Field?.Text == "ghbdtn") break;
                Application.DoEvents(); Thread.Sleep(100);
            }
            if (captured?.Outcome != 1 || captured.Field == null || captured.Field.Text != plain.Text ||
                captured.Field.Start != plain.TextLength || captured.Field.End != plain.TextLength)
                return Report("FAIL", "plain_capture", checks);
            checks++;
            var changed = RequireBroker(() => broker.Call(2, captured.Field, "привет"));
            Application.DoEvents();
            if (changed.Field != null)
            {
                brokerObservedTextLength = changed.Field.Text.Length;
                brokerObservedSelectionStart = changed.Field.Start;
                brokerObservedSelectionEnd = changed.Field.End;
                brokerObservedIdentity = changed.Field.Foreground == captured.Field.Foreground &&
                    changed.Field.Focus == captured.Field.Focus && changed.Field.Pid == captured.Field.Pid &&
                    changed.Field.Tid == captured.Field.Tid &&
                    changed.Field.Id.SequenceEqual(captured.Field.Id);
                brokerObservedValueMatched = changed.Field.Text == "привет";
            }
            if (changed?.Outcome != 1 || changed.Field?.Text != "привет" || plain.Text != "привет")
                return Report("FAIL", "plain_value_write", checks);
            checks++;
            plain.SelectAll(); Application.DoEvents();
            var nativeBefore = RequireBroker(() => broker.Call(1, null, null));
            if (nativeBefore?.Outcome == 1 && nativeBefore.Field?.NativeRangeWriter == true)
            {
                var nativeAfter = RequireBroker(() => broker.Call(3, nativeBefore.Field, "ghbdtn",
                    nativeBefore.Field.Start, nativeBefore.Field.End));
                Application.DoEvents();
                if (nativeAfter?.Outcome != 1 || plain.Text != "ghbdtn")
                    return Report("FAIL", "native_range_write", checks);
                checks++;
            }
            if (!Focus(form, drift)) return Report("FAIL", "selection_rollback_focus", checks);
            drift.SelectionStart = drift.TextLength; drift.SelectionLength = 0;
            var driftBefore = RequireBroker(() => broker.Call(1, null, null));
            if (driftBefore.Outcome != 1 || driftBefore.Field?.NativeRangeWriter != true ||
                driftBefore.Field.Start != drift.TextLength || driftBefore.Field.End != drift.TextLength)
                return Report("FAIL", "selection_rollback_capture", checks);
            drift.DriftNextSelection = true;
            var refused = RequireBroker(() => broker.Call(3, driftBefore.Field, "привет", 0, drift.TextLength));
            Application.DoEvents();
            if (refused.Outcome != 0 || drift.DriftNextSelection ||
                drift.Text != "ghbdtn" || drift.SelectionStart != drift.TextLength ||
                drift.SelectionLength != 0)
                return Report("FAIL", "selection_rollback_ack", checks);
            checks++;
            if (!Focus(form, password) || RequireBroker(() => broker.Call(1, null, null)).Outcome == 1)
                return Report("FAIL", "password_rejection", checks);
            checks++;
            if (!Focus(form, readOnly) || RequireBroker(() => broker.Call(1, null, null)).Outcome == 1)
                return Report("FAIL", "readonly_rejection", checks);
            checks++;
            if (!Focus(form, rich)) return Report("FAIL", "rich_focus", checks);
            var richCapture = RequireBroker(() => broker.Call(1, null, null));
            if (richCapture == null || richCapture.Outcome == 2 ||
                richCapture.Outcome == 1 && richCapture.Field?.CanWrite != false)
                return Report("FAIL", "rich_atomic_rejection", checks);
            checks++;
            if (!Focus(form, password) || RequireBroker(() => broker.Call(2, captured.Field, "unsafe")).Outcome == 1)
                return Report("FAIL", "focus_drift_rejection", checks);
            checks++;
            if (!Focus(form, plain)) return Report("FAIL", "integration_fixture_focus", checks);
            integrationStatus = RunRuntimeIntegration(form, plain, password, multiline,
                path, out var integrationChecks);
            checks += integrationChecks;
            if (integrationStatus == "NOT_RUN") return Report("NOT_RUN", "runtime_integration_precondition", checks);
            if (integrationStatus != "PASS") return Report("FAIL", "runtime_integration", checks);
            var edge = FindEdge();
            if (edge != null)
            {
                edgeInput = ProbeEdge(broker, edge, false, edgeInputReceipt);
                if (edgeInput != "PASS" && edgeInput != "UNSUPPORTED")
                    return Report("FAIL", "edge_input_probe", checks);
                edgeTextarea = ProbeEdge(broker, edge, true, edgeTextareaReceipt);
                if (edgeTextarea != "PASS" && edgeTextarea != "UNSUPPORTED")
                    return Report("FAIL", "edge_textarea_probe", checks);
                if (edgeInput == "PASS") checks++;
                if (edgeTextarea == "PASS") checks++;
                edgeInputRuntime = ProbeEdgeRuntime(edge, path, false, edgeInputRuntimeReceipt);
                if (edgeInputRuntime != "PASS" && edgeInputRuntime != "UNSUPPORTED")
                    return Report("FAIL", "edge_input_runtime", checks);
                edgeTextareaRuntime = ProbeEdgeRuntime(edge, path, true, edgeTextareaRuntimeReceipt);
                if (edgeTextareaRuntime != "PASS" && edgeTextareaRuntime != "UNSUPPORTED")
                    return Report("FAIL", "edge_textarea_runtime", checks);
                if (edgeInputRuntime == "PASS") checks++;
                if (edgeTextareaRuntime == "PASS") checks++;
            }
            return Report("PASS", "synthetic_uia_broker", checks);
        }
        catch { return Report("FAIL", "broker_exception", checks); }
        finally { broker.Dispose(); }
    }

    private static bool Focus(Form form, Control control)
    {
        form.Activate(); control.Focus(); Application.DoEvents();
        return GetForegroundWindow() == form.Handle && control.Focused;
    }

    private static T? Pump<T>(Func<T?> action, int timeoutMilliseconds) where T : class
    {
        var task = Task.Run(action);
        var until = Environment.TickCount64 + timeoutMilliseconds;
        while (!task.IsCompleted && Environment.TickCount64 < until)
        { Application.DoEvents(); if (!task.IsCompleted) WaitForUiMessage(until); }
        return task.IsCompletedSuccessfully ? task.Result : null;
    }

    private static Result? PumpBroker(Func<Result> action, int timeoutMilliseconds, out string stage)
    {
        var task = Task.Run(action);
        var until = Environment.TickCount64 + timeoutMilliseconds;
        while (!task.IsCompleted && Environment.TickCount64 < until)
        { Application.DoEvents(); if (!task.IsCompleted) WaitForUiMessage(until); }
        if (!task.IsCompleted)
        {
            stage = "RPC_TIMEOUT";
            task.ContinueWith(t => { var ignored = t.Exception; },
                TaskContinuationOptions.OnlyOnFaulted);
            return null;
        }
        if (task.IsFaulted || task.IsCanceled)
        {
            stage = "CLIENT_EXCEPTION";
            if (task.Exception?.GetBaseException() is Win32Exception native)
                brokerNativeCode = native.NativeErrorCode;
            return null;
        }
        stage = "RESPONSE";
        return task.Result;
    }

    private static void WaitForUiMessage(long until)
    {
        var remaining = until - Environment.TickCount64;
        if (remaining <= 0) return;
        // Wake immediately for the target WinForms window's queued native/UIA message.
        // A 5-ms cap also notices completion of the worker task without busy spinning.
        MsgWaitForMultipleObjectsEx(0, IntPtr.Zero, (uint)Math.Min(5, remaining),
            QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    }

    private static Result RequireBroker(Func<Result> action, int timeoutMilliseconds = 3000)
    {
        var response = PumpBroker(action, timeoutMilliseconds, out var stage);
        brokerProbe = stage;
        if (response == null) throw new IOException("Broker RPC unavailable.");
        brokerOutcome = response.Outcome;
        brokerStage = response.Stage;
        brokerPhase = response.Phase;
        brokerNativeCode = response.NativeError;
        brokerHResult = response.HResult;
        return response;
    }

    private static int Report(string status, string probe, int checks)
    {
        Console.WriteLine("{\"status\":\"" + status + "\",\"probe\":\"" + probe +
            "\",\"checks\":" + checks + ",\"hook\":\"" + hookStatus +
            "\",\"keyboardCode\":" + hookKeyboardCode + ",\"mouseCode\":" + hookMouseCode +
            ",\"integration\":\"" + integrationStatus +
            "\",\"integrationProbe\":\"" + integrationProbe +
            "\",\"integrationLayout\":\"" + integrationLayout +
            "\",\"integrationApplied\":" + integrationApplied +
            ",\"integrationUndone\":" + integrationUndone +
            ",\"integrationTextLength\":" + integrationTextLength +
            ",\"integrationExpectedText\":" + (integrationExpectedText ? "true" : "false") +
            ",\"integrationManualCode\":" + integrationManualCode +
            ",\"integrationShiftCode\":" + integrationShiftCode +
            ",\"integrationResetReason\":" + integrationResetReason +
            ",\"integrationNativeCode\":" + integrationNativeCode +
            ",\"integrationNativeBrokerOutcome\":" + integrationNativeBrokerOutcome +
            ",\"integrationNativeBrokerStage\":" + integrationNativeBrokerStage +
            ",\"integrationNativeBrokerPhase\":" + integrationNativeBrokerPhase +
            ",\"integrationNativeRpcMilliseconds\":" + integrationNativeRpcMilliseconds +
            ",\"integrationNativeBudgetMilliseconds\":" + integrationNativeBudgetMilliseconds +
            ",\"integrationFullBrokerOutcome\":" + integrationFullBrokerOutcome +
            ",\"integrationFullBrokerPhase\":" + integrationFullBrokerPhase +
            ",\"integrationFullBudgetMilliseconds\":" + integrationFullBudgetMilliseconds +
            ",\"integrationFullRpcMilliseconds\":" + integrationFullRpcMilliseconds +
            ",\"integrationAutoCode\":" + integrationAutoCode +
            ",\"integrationAutoSourceCode\":" + integrationAutoSourceCode +
            ",\"integrationWaitStatus\":\"" + integrationWaitStatus +
            "\",\"brokerProbe\":\"" + brokerProbe +
            "\",\"brokerRestartCount\":" + brokerRestartCount +
            ",\"brokerOutcome\":" + brokerOutcome +
            ",\"brokerStage\":" + brokerStage +
            ",\"brokerPhase\":" + brokerPhase +
            ",\"brokerNativeCode\":" + brokerNativeCode +
            ",\"brokerHResult\":" + brokerHResult +
            ",\"fixtureForeground\":" + (fixtureForeground ? "true" : "false") +
            ",\"fixtureFocus\":" + (fixtureFocus ? "true" : "false") +
            ",\"brokerTextLength\":" + brokerTextLength +
            ",\"brokerSelectionStart\":" + brokerSelectionStart +
            ",\"brokerSelectionEnd\":" + brokerSelectionEnd +
            ",\"brokerNativeClassKind\":" + brokerNativeClassKind +
            ",\"brokerSameFixturePid\":" + (brokerSameFixturePid ? "true" : "false") +
            ",\"brokerFocusMatchesPlain\":" + (brokerFocusMatchesPlain ? "true" : "false") +
            ",\"brokerObservedTextLength\":" + brokerObservedTextLength +
            ",\"brokerObservedSelectionStart\":" + brokerObservedSelectionStart +
            ",\"brokerObservedSelectionEnd\":" + brokerObservedSelectionEnd +
            ",\"brokerObservedIdentity\":" + (brokerObservedIdentity ? "true" : "false") +
            ",\"brokerObservedValueMatched\":" + (brokerObservedValueMatched ? "true" : "false") +
            ",\"edgeInput\":\"" + edgeInput +
            "\",\"edgeTextarea\":\"" + edgeTextarea +
            "\",\"edgeInputReceipt\":" + edgeInputReceipt.Json() +
            ",\"edgeTextareaReceipt\":" + edgeTextareaReceipt.Json() +
            ",\"edgeInputRuntime\":\"" + edgeInputRuntime +
            "\",\"edgeTextareaRuntime\":\"" + edgeTextareaRuntime +
            "\",\"edgeInputRuntimeReceipt\":" + edgeInputRuntimeReceipt.Json() +
            ",\"edgeTextareaRuntimeReceipt\":" + edgeTextareaRuntimeReceipt.Json() + "}");
        return status == "PASS" ? 0 : 1;
    }

    private static string? FindEdge()
    {
        var roots = new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) };
        return roots.Select(root => Path.Combine(root, "Microsoft", "Edge", "Application", "msedge.exe"))
            .FirstOrDefault(File.Exists);
    }

    private static string RunRuntimeIntegration(Form form, TextBox plain, TextBox password,
        TextBox multiline,
        string executable, out int checks)
    {
        checks = 0;
        integrationProbe = "app_data_manifest";
        var appDirectory = Path.GetDirectoryName(Path.GetFullPath(executable));
        if (string.IsNullOrEmpty(appDirectory)) return "FAIL";
        var data = Path.Combine(appDirectory, "data");
        if (!File.Exists(Path.Combine(data, "dictionary-manifest.json"))) return "FAIL";
        integrationProbe = "load_layouts";
        if (LoadKeyboardLayout("00000419", 1) == IntPtr.Zero ||
            LoadKeyboardLayout("00000409", 1) == IntPtr.Zero) return "NOT_RUN";
        integrationProbe = "list_layouts";
        int count = GetKeyboardLayoutList(0, null);
        if (count < 2 || count > 256) return "NOT_RUN";
        var layouts = new IntPtr[count];
        GetKeyboardLayoutList(count, layouts);
        if (!layouts.Any(x => unchecked((uint)x.ToInt64()) == 0x04190419u) ||
            !layouts.Any(x => unchecked((uint)x.ToInt64()) == 0x04090409u)) return "NOT_RUN";
        integrationProbe = "fixture_focus";
        if (!Focus(form, plain)) return "NOT_RUN";
        plain.Text = "ghbdtn"; plain.SelectionStart = plain.TextLength;
        var marker = System.Security.Cryptography.RandomNumberGenerator.GetInt32(1, int.MaxValue);
        integrationProbe = "fixture_marker";
        if (SetProp(form.Handle, "MacSwitcher.RuntimeFixture", new IntPtr(marker)) == IntPtr.Zero)
            return "FAIL";
        try
        {
            integrationProbe = "client_start";
            using var session = new FixtureSession(executable, data, marker);
            integrationProbe = "client_ready";
            if (!session.Ready) return "FAIL";
            integrationProbe = "chord_cancellation";
            session.Command("CACHE");
            var beforeChord = session.Command("STATE");
            var afterChord = session.Command("CHORD_CTRL");
            if (beforeChord.Layout != "en" || afterChord.Layout != "en" ||
                beforeChord.Applied != afterChord.Applied || plain.Text != "ghbdtn")
                return "FAIL";
            checks++;
            integrationProbe = "single_shift_left";
            session.Command("CACHE");
            var firstTap = session.Command("TAP_L");
            integrationLayout = firstTap.Layout;
            if (firstTap.Layout != "ru") return "FAIL";
            integrationProbe = "manual_word_text";
            session.Command("TAP_R");
            var result = session.Command("WAIT");
            integrationLayout = result.Layout;
            integrationApplied = result.Applied;
            integrationUndone = result.Undone;
            integrationTextLength = plain.Text.Length;
            integrationExpectedText = plain.Text == "привет";
            if (!integrationExpectedText) return "FAIL";
            integrationProbe = "manual_word_receipt";
            if (result.Applied < 1) return "FAIL";
            integrationProbe = "manual_word_layout";
            if (result.Layout != "ru") return "FAIL";
            checks++;
            integrationProbe = "manual_undo_single_shift";
            var undoFirstTap = session.Command("TAP_R");
            integrationLayout = undoFirstTap.Layout;
            if (undoFirstTap.Layout != "en") return "FAIL";
            integrationProbe = "manual_undo_text";
            session.Command("TAP_L");
            result = session.Command("WAIT");
            integrationLayout = result.Layout;
            integrationApplied = result.Applied;
            integrationUndone = result.Undone;
            integrationTextLength = plain.Text.Length;
            integrationExpectedText = plain.Text == "ghbdtn";
            if (!integrationExpectedText) return "FAIL";
            integrationProbe = "manual_undo_receipt";
            if (result.Undone < 1) return "FAIL";
            integrationProbe = "manual_undo_layout";
            if (result.Layout != "en") return "FAIL";
            checks++;
            integrationProbe = "manual_redo";
            session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "привет" || result.Applied < 2) return "FAIL";
            checks++;

            integrationProbe = "word_source_mismatch";
            LoadKeyboardLayout("00000419", 1);
            plain.Text = "ghbdtn"; plain.SelectionStart = plain.TextLength;
            session.Command("CACHE");
            if (session.Command("TAP_L").Layout != "en") return "FAIL";
            session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "привет" || result.Layout != "ru" || result.Applied < 3)
                return "FAIL";
            checks++;
            integrationProbe = "word_source_mismatch_undo";
            session.Command("TAP_R"); session.Command("TAP_L");
            result = session.Command("WAIT");
            if (plain.Text != "ghbdtn" || result.Layout != "en" || result.Undone < 2)
                return "FAIL";
            checks++;
            integrationProbe = "word_source_mismatch_redo";
            session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "привет" || result.Layout != "ru" || result.Applied < 4)
                return "FAIL";
            checks++;

            integrationProbe = "rapid_word_without_cache";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = ""; plain.SelectionStart = 0;
            session.Command("AUTO_OFF"); session.Command("CACHE");
            foreach (var letter in "ghbdtn")
            {
                session.Command("KEY_D"); plain.AppendText(letter.ToString());
                session.Command("KEY_U");
            }
            session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "привет" || result.Layout != "ru" || result.Applied < 5)
                return "FAIL";
            checks++;

            integrationProbe = "rapid_selection_without_cache";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = "ghbdtn world"; plain.Select(0, 6);
            session.Command("MOUSE_INTERRUPT");
            session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "привет world" || result.Layout != "ru" || result.Applied < 6)
                return "FAIL";
            checks++;

            integrationProbe = "selection";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = "ghbdtn world"; plain.Select(0, 6);
            session.Command("CACHE"); session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "привет world" || result.Applied < 7) return "FAIL";
            checks++;
            integrationProbe = "selection_undo";
            session.Command("TAP_R"); session.Command("TAP_L");
            result = session.Command("WAIT");
            if (plain.Text != "ghbdtn world" || result.Undone < 3) return "FAIL";
            checks++;

            integrationProbe = "new_word";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = "ghbdtn next"; plain.SelectionStart = plain.TextLength;
            session.Command("CACHE"); session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "ghbdtn туче" || result.Applied < 8) return "FAIL";
            checks++;

            integrationProbe = "manual_trailing_space";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = "one ghbdtn "; plain.SelectionStart = plain.TextLength;
            session.Command("CACHE"); session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "one привет " || plain.SelectionStart != plain.TextLength ||
                result.Layout != "ru" || result.Applied < 9) return "FAIL";
            checks++;
            integrationProbe = "manual_trailing_space_undo";
            session.Command("TAP_R"); session.Command("TAP_L");
            result = session.Command("WAIT");
            if (plain.Text != "one ghbdtn " || plain.SelectionStart != plain.TextLength ||
                result.Layout != "en" || result.Undone < 4) return "FAIL";
            checks++;
            integrationProbe = "manual_trailing_space_redo";
            session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "one привет " || plain.SelectionStart != plain.TextLength ||
                result.Layout != "ru" || result.Applied < 10) return "FAIL";
            checks++;

            integrationProbe = "manual_punctuation_space";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = "one ghbdtn! "; plain.SelectionStart = plain.TextLength;
            session.Command("CACHE"); session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "one привет! " || plain.SelectionStart != plain.TextLength ||
                result.Layout != "ru" || result.Applied < 11) return "FAIL";
            checks++;
            integrationProbe = "manual_punctuation_space_undo";
            session.Command("TAP_R"); session.Command("TAP_L");
            result = session.Command("WAIT");
            if (plain.Text != "one ghbdtn! " || plain.SelectionStart != plain.TextLength ||
                result.Layout != "en" || result.Undone < 5) return "FAIL";
            checks++;
            integrationProbe = "manual_punctuation_space_redo";
            session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "one привет! " || plain.SelectionStart != plain.TextLength ||
                result.Layout != "ru" || result.Applied < 12) return "FAIL";
            checks++;

            integrationProbe = "manual_multiline_crlf";
            LoadKeyboardLayout("00000409", 1);
            if (!Focus(form, multiline)) return "FAIL";
            multiline.Text = "one ghbdtn\r\n";
            if (multiline.Text != "one ghbdtn\r\n") return "FAIL";
            multiline.SelectionStart = multiline.TextLength;
            session.Command("CACHE"); session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (multiline.Text != "one привет\r\n" ||
                multiline.SelectionStart != multiline.TextLength ||
                result.Layout != "ru" || result.Applied < 13) return "FAIL";
            checks++;
            integrationProbe = "manual_multiline_crlf_undo";
            session.Command("TAP_R"); session.Command("TAP_L");
            result = session.Command("WAIT");
            if (multiline.Text != "one ghbdtn\r\n" ||
                multiline.SelectionStart != multiline.TextLength ||
                result.Layout != "en" || result.Undone < 6) return "FAIL";
            checks++;

            integrationProbe = "manual_multiline_tab";
            LoadKeyboardLayout("00000409", 1);
            multiline.Text = "one ghbdtn\t";
            if (multiline.Text != "one ghbdtn\t") return "FAIL";
            multiline.SelectionStart = multiline.TextLength;
            session.Command("CACHE"); session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (multiline.Text != "one привет\t" ||
                multiline.SelectionStart != multiline.TextLength ||
                result.Layout != "ru" || result.Applied < 14) return "FAIL";
            checks++;
            integrationProbe = "manual_multiline_tab_undo";
            session.Command("TAP_R"); session.Command("TAP_L");
            result = session.Command("WAIT");
            if (multiline.Text != "one ghbdtn\t" ||
                multiline.SelectionStart != multiline.TextLength ||
                result.Layout != "en" || result.Undone < 7) return "FAIL";
            checks++;

            integrationProbe = "auto_early";
            if (!Focus(form, plain)) return "FAIL";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = ""; plain.SelectionStart = 0;
            session.Command("AUTO_ON"); session.Command("CACHE");
            foreach (var letter in "ghbd")
            {
                session.Command("KEY_D"); plain.AppendText(letter.ToString());
                session.Command("KEY_U");
            }
            result = session.Command("WAIT");
            integrationLayout = result.Layout; integrationApplied = result.Applied;
            integrationUndone = result.Undone; integrationTextLength = plain.Text.Length;
            integrationExpectedText = plain.Text == "прив";
            if (!integrationExpectedText || result.Applied < 15) return "FAIL";
            checks++;

            integrationProbe = "auto_clear_source";
            if (LoadKeyboardLayout("00000409", 1) == IntPtr.Zero) return "FAIL";
            plain.Text = ""; plain.SelectionStart = 0;
            session.Command("CACHE");
            if (session.Command("STATE").Layout != "en") return "FAIL";
            integrationProbe = "auto_after_verified_clear";
            foreach (var letter in "ghbd")
            {
                session.Command("KEY_D"); plain.AppendText(letter.ToString());
                session.Command("KEY_U");
            }
            result = session.Command("WAIT");
            integrationLayout = result.Layout; integrationApplied = result.Applied;
            integrationUndone = result.Undone; integrationTextLength = plain.Text.Length;
            integrationExpectedText = plain.Text == "прив";
            if (!integrationExpectedText || result.Applied < 16) return "FAIL";
            checks++;

            integrationProbe = "auto_fast_burst";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = ""; plain.SelectionStart = 0;
            session.Command("AUTO_OFF"); session.Command("AUTO_ON"); session.Command("CACHE");
            foreach (var letter in "rfr ")
            {
                var space = letter == ' ';
                session.Command(space ? "SPACE_D" : "KEY_D"); plain.AppendText(letter.ToString());
                session.Command(space ? "SPACE_U" : "KEY_U");
            }
            result = session.Command("WAIT");
            integrationLayout = result.Layout; integrationApplied = result.Applied;
            integrationUndone = result.Undone; integrationTextLength = plain.Text.Length;
            integrationExpectedText = plain.Text == "как ";
            if (!integrationExpectedText || result.Applied < 17) return "FAIL";
            checks++;

            integrationProbe = "focus_drift";
            plain.Text = "ghbd"; plain.SelectionStart = plain.TextLength;
            session.Command("AUTO_OFF"); session.Command("AUTO_ON"); session.Command("CACHE");
            session.Command("KEY_D"); plain.AppendText("t");
            if (!Focus(form, password)) return "FAIL";
            session.Command("KEY_U"); result = session.Command("WAIT");
            if (plain.Text != "ghbdt" || password.Text != "synthetic-secret" || result.Recovery) return "FAIL";
            checks++;
            integrationProbe = "password_rejection";
            session.Command("WAIT"); session.Command("TAP_L"); session.Command("TAP_R");
            var priorApplied = result.Applied;
            result = session.Command("WAIT");
            if (password.Text != "synthetic-secret" || result.Applied != priorApplied || result.Recovery)
                return "FAIL";
            checks++;
            integrationProbe = "complete";
            return "PASS";
        }
        catch { return "FAIL"; }
        finally { RemoveProp(form.Handle, "MacSwitcher.RuntimeFixture"); }
    }

    private sealed class FixtureReply
    {
        public int Applied, Undone;
        public string Layout = "";
        public bool Recovery;
        public int ManualCode;
        public int NativeCode, NativeBrokerOutcome, NativeBrokerStage, NativeBudgetMilliseconds,
            NativeBrokerPhase, NativeRpcMilliseconds, ShiftCode, ResetReason;
        public int FullBrokerOutcome, FullBrokerPhase, FullBudgetMilliseconds, FullRpcMilliseconds;
        public int AutoCode, AutoSourceCode;
    }

    private sealed class FixtureSession : IDisposable
    {
        private readonly Process process;
        public bool Ready { get; }

        public FixtureSession(string executable, string data, int marker)
            : this(executable, data, marker, (uint)Environment.ProcessId, null) { }

        public FixtureSession(string executable, string data, int marker,
            uint targetPid, string? browserMarker)
        {
            var start = new ProcessStartInfo(executable,
                (browserMarker == null ? "--runtime-fixture-client " :
                    "--runtime-browser-fixture-client ") + targetPid)
            { UseShellExecute = false, CreateNoWindow = true,
              RedirectStandardInput = true, RedirectStandardOutput = true };
            start.Environment["MACSWITCHER_RUNTIME_FIXTURE_MARKER"] = marker.ToString();
            start.Environment["MACSWITCHER_RUNTIME_FIXTURE_DATA"] = data;
            if (browserMarker != null)
                start.Environment["MACSWITCHER_RUNTIME_BROWSER_FIXTURE_PAGE_MARKER"] = browserMarker;
            process = Process.Start(start) ?? throw new InvalidOperationException();
            Ready = Pump(() => process.StandardOutput.ReadLine(), 30000) == "READY";
        }

        public FixtureReply Command(string command)
        {
            process.StandardInput.WriteLine(command);
            process.StandardInput.Flush();
            var line = Pump(() => process.StandardOutput.ReadLine(),
                command == "CACHE" || command == "WAIT" ? 5500 : 4000);
            if (line == "CACHE_NOT_READY")
            { integrationProbe = "cache_preparation"; throw new InvalidOperationException(); }
            if (line == null && command == "CACHE") integrationProbe = "cache_preparation";
            if (line == "WORK_NOT_READY" || line == null && command == "WAIT")
            { integrationWaitStatus = "WORK_NOT_READY"; throw new InvalidOperationException(); }
            if (line == null || !line.StartsWith("OK|", StringComparison.Ordinal))
                throw new InvalidOperationException();
            var pieces = line.Split('|');
            if (pieces.Length != 20) throw new InvalidOperationException();
            if (command == "WAIT") integrationWaitStatus = "SETTLED";
            var reply = new FixtureReply { Applied = int.Parse(pieces[1]), Undone = int.Parse(pieces[2]),
                Layout = pieces[3], Recovery = pieces[4] == "1", ManualCode = int.Parse(pieces[5]),
                NativeCode = int.Parse(pieces[6]), NativeBrokerOutcome = int.Parse(pieces[7]),
                NativeBrokerStage = int.Parse(pieces[8]), NativeBudgetMilliseconds = int.Parse(pieces[9]),
                NativeBrokerPhase = int.Parse(pieces[10]), NativeRpcMilliseconds = int.Parse(pieces[11]),
                ShiftCode = int.Parse(pieces[12]), ResetReason = int.Parse(pieces[13]),
                FullBrokerOutcome = int.Parse(pieces[14]), FullBrokerPhase = int.Parse(pieces[15]),
                FullBudgetMilliseconds = int.Parse(pieces[16]), FullRpcMilliseconds = int.Parse(pieces[17]),
                AutoCode = int.Parse(pieces[18]), AutoSourceCode = int.Parse(pieces[19]) };
            integrationManualCode = reply.ManualCode;
            integrationNativeCode = reply.NativeCode;
            integrationNativeBrokerOutcome = reply.NativeBrokerOutcome;
            integrationNativeBrokerStage = reply.NativeBrokerStage;
            integrationNativeBudgetMilliseconds = reply.NativeBudgetMilliseconds;
            integrationNativeBrokerPhase = reply.NativeBrokerPhase;
            integrationNativeRpcMilliseconds = reply.NativeRpcMilliseconds;
            integrationShiftCode = reply.ShiftCode;
            integrationResetReason = reply.ResetReason;
            integrationFullBrokerOutcome = reply.FullBrokerOutcome;
            integrationFullBrokerPhase = reply.FullBrokerPhase;
            integrationFullBudgetMilliseconds = reply.FullBudgetMilliseconds;
            integrationFullRpcMilliseconds = reply.FullRpcMilliseconds;
            integrationAutoCode = reply.AutoCode;
            integrationAutoSourceCode = reply.AutoSourceCode;
            return reply;
        }

        public void Dispose()
        {
            try { process.StandardInput.WriteLine("EXIT"); process.StandardInput.Flush(); } catch { }
            if (!process.WaitForExit(2000))
            { try { process.Kill(true); } catch { } }
            process.Dispose();
        }
    }

    private static bool OwnEdgeWindow(IntPtr window, uint pid, string pageMarker)
    {
        if (window == IntPtr.Zero || GetForegroundWindow() != window) return false;
        uint currentPid;
        GetWindowThreadProcessId(window, out currentPid);
        if (currentPid != pid) return false;
        try
        {
            if (!Process.GetProcessById((int)pid).ProcessName.Equals("msedge",
                StringComparison.OrdinalIgnoreCase)) return false;
        }
        catch { return false; }
        var title = new StringBuilder(256);
        GetWindowText(window, title, title.Capacity);
        return title.ToString().StartsWith(pageMarker + "-", StringComparison.Ordinal);
    }

    private static bool ReadEdgeTitleState(IntPtr window, string pageMarker,
        out bool eventAck, out bool valueAck, out bool activeAck, out bool documentFocused)
    {
        eventAck = valueAck = activeAck = documentFocused = false;
        var title = new StringBuilder(256);
        GetWindowText(window, title, title.Capacity);
        var observed = title.ToString();
        if (!observed.StartsWith(pageMarker + "-", StringComparison.Ordinal)) return false;
        var suffix = observed.Substring(pageMarker.Length + 1);
        eventAck = suffix.StartsWith("event-", StringComparison.Ordinal);
        valueAck = suffix.Contains("-value-", StringComparison.Ordinal);
        activeAck = suffix.Contains("-active", StringComparison.Ordinal);
        documentFocused = suffix.EndsWith("-focused", StringComparison.Ordinal);
        return true;
    }

    private static bool FocusOwnEdgeField(IntPtr window, uint pid, string pageMarker,
        int windowMarker)
    {
        if (!OwnEdgeWindow(window, pid, pageMarker) ||
            GetProp(window, "MacSwitcher.RuntimeBrowserFixture").ToInt64() != windowMarker)
            return false;
        var accessibleName = pageMarker + "-field";
        var task = Task.Run(() =>
        {
            if (!OwnEdgeWindow(window, pid, pageMarker) ||
                GetProp(window, "MacSwitcher.RuntimeBrowserFixture").ToInt64() != windowMarker)
                return false;
            var root = AutomationElement.FromHandle(window);
            var field = root.FindFirst(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.NameProperty, accessibleName));
            if (field == null || field.Current.IsPassword || !field.Current.IsEnabled ||
                field.Current.ControlType != ControlType.Edit) return false;
            field.SetFocus();
            return field.Current.HasKeyboardFocus;
        });
        var until = Environment.TickCount64 + 3000;
        while (!task.IsCompleted && Environment.TickCount64 < until)
        { Application.DoEvents(); if (!task.IsCompleted) WaitForUiMessage(until); }
        return task.IsCompletedSuccessfully && task.Result &&
            OwnEdgeWindow(window, pid, pageMarker);
    }

    private static string ProbeEdge(Broker broker, string executable, bool textarea,
        EdgeProbeReceipt receipt)
    {
        var temporary = Path.Combine(Path.GetTempPath(), "MacSwitcher-EdgeFixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        var page = Path.Combine(temporary, "fixture.html");
        var kind = textarea ? "textarea" : "input";
        var pageMarker = "msw-" + kind + "-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(page, "<!doctype html><meta charset=\"utf-8\"><title>" +
            pageMarker + "-noevent-other-inactive-blurred</title><" + kind +
            " id=\"target\" aria-label=\"" + pageMarker + "-field\"" +
            (textarea ? ">ghbdtn</textarea>" : " value=\"ghbdtn\">") +
            "<script>const x=document.getElementById('target');let seen=false;" +
            "function update(){document.title='" + pageMarker +
            "-'+(seen?'event':'noevent')+'-'+(x.value==='привет'?'value':'other')+" +
            "'-'+(document.activeElement===x?'active':'inactive')+'-'+" +
            "(document.hasFocus()?'focused':'blurred')}" +
            "x.addEventListener('input',()=>{seen=true;update()});" +
            "function focusTarget(){x.focus();x.setSelectionRange(x.value.length,x.value.length);update()}" +
            "window.onload=focusTarget;window.addEventListener('focus',focusTarget);" +
            "setInterval(update,40)</script>", Encoding.UTF8);
        var profile = Path.Combine(temporary, "profile");
        Process? edge = null;
        IntPtr markedWindow = IntPtr.Zero;
        bool writeAttempted = false;
        string Finish(string status) { receipt.Status = status; return status; }
        try
        {
            edge = Process.Start(new ProcessStartInfo(executable,
                "--no-first-run --no-default-browser-check --disable-background-networking " +
                "--user-data-dir=\"" + profile + "\" --app=\"" + new Uri(page).AbsoluteUri + "\"")
            { UseShellExecute = false, CreateNoWindow = false });
            if (edge == null) return Finish("NOT_RUN");
            IntPtr edgeWindow = IntPtr.Zero;
            uint edgePid = 0;
            var until = Environment.TickCount64 + 6000;
            while (Environment.TickCount64 < until)
            {
                Application.DoEvents();
                var window = GetForegroundWindow();
                uint pid;
                GetWindowThreadProcessId(window, out pid);
                if (OwnEdgeWindow(window, pid, pageMarker))
                {
                    edgeWindow = window; edgePid = pid; break;
                }
                WaitForUiMessage(until);
            }
            if (edgeWindow == IntPtr.Zero) return Finish("NOT_RUN");
            var windowMarker = System.Security.Cryptography.RandomNumberGenerator.GetInt32(1, int.MaxValue);
            if (SetProp(edgeWindow, "MacSwitcher.RuntimeBrowserFixture", new IntPtr(windowMarker)) == IntPtr.Zero)
                return Finish("MARKER_UNAVAILABLE");
            markedWindow = edgeWindow;
            if (!FocusOwnEdgeField(edgeWindow, edgePid, pageMarker, windowMarker))
                return Finish("FOCUS_NOT_READY");
            until = Environment.TickCount64 + 3000;
            while (Environment.TickCount64 < until)
            {
                Application.DoEvents();
                bool eventAck, valueAck, activeAck, documentFocused;
                if (!OwnEdgeWindow(edgeWindow, edgePid, pageMarker)) return Finish("FOCUS_DRIFT");
                if (ReadEdgeTitleState(edgeWindow, pageMarker, out eventAck, out valueAck,
                    out activeAck, out documentFocused) && activeAck && documentFocused)
                { receipt.DomActiveAck = true; receipt.DomDocumentFocused = true; break; }
                WaitForUiMessage(until);
            }
            if (!receipt.DomActiveAck) return Finish("FOCUS_NOT_READY");
            Result? captured = null;
            for (int attempt = 0; attempt < 10; attempt++)
            {
                receipt.OwnWindowAtCapture = OwnEdgeWindow(edgeWindow, edgePid, pageMarker);
                if (!receipt.OwnWindowAtCapture) return Finish("FOCUS_DRIFT");
                captured = RequireBroker(() => broker.Call(1, null, null), attempt == 0 ? 5000 : 3000);
                receipt.CaptureOutcome = captured.Outcome;
                receipt.CaptureStage = captured.Stage;
                receipt.CapturePhase = captured.Phase;
                receipt.CanWrite = captured.Field?.CanWrite == true;
                receipt.InitialTextMatched = captured.Field?.Text == "ghbdtn";
                if (captured.Outcome == 1 && receipt.InitialTextMatched) break;
                Application.DoEvents(); WaitForUiMessage(Environment.TickCount64 + 100);
            }
            if (captured?.Outcome != 1 || captured.Field == null || !captured.Field.CanWrite ||
                !receipt.InitialTextMatched) return Finish("UNSUPPORTED");
            receipt.OwnWindowAtWrite = OwnEdgeWindow(edgeWindow, edgePid, pageMarker);
            if (!receipt.OwnWindowAtWrite) return Finish("FOCUS_DRIFT");
            bool beforeEvent, beforeValue, beforeActive, beforeFocused;
            if (!ReadEdgeTitleState(edgeWindow, pageMarker, out beforeEvent, out beforeValue,
                out beforeActive, out beforeFocused) || !beforeActive || !beforeFocused)
                return Finish("FOCUS_NOT_READY");
            writeAttempted = true;
            var changed = RequireBroker(() => broker.Call(2, captured.Field, "привет"));
            receipt.WriteOutcome = changed.Outcome;
            receipt.WriteStage = changed.Stage;
            receipt.WritePhase = changed.Phase;
            receipt.WriteHResult = changed.HResult;
            receipt.UiAvailable = changed.UiAvailable;
            receipt.UiSameRuntimeId = changed.UiSameRuntimeId;
            receipt.UiHasKeyboardFocus = changed.UiHasKeyboardFocus;
            receipt.UiSameProcess = changed.UiSameProcess;
            receipt.UiEditType = changed.UiEditType;
            receipt.UiCredentialFlagClear = changed.UiCredentialFlagClear;
            receipt.UiEnabled = changed.UiEnabled;
            receipt.NativeSameRoot = changed.NativeSameRoot;
            receipt.NativeSameProcess = changed.NativeSameProcess;
            receipt.NativeSameThread = changed.NativeSameThread;
            until = Environment.TickCount64 + 1500;
            while (Environment.TickCount64 < until)
            {
                Application.DoEvents();
                bool eventAck, valueAck, activeAck, documentFocused;
                if (!ReadEdgeTitleState(edgeWindow, pageMarker, out eventAck, out valueAck,
                    out activeAck, out documentFocused))
                    return Finish("FOCUS_DRIFT");
                receipt.DomEventAck = eventAck;
                receipt.DomValueAck = valueAck;
                receipt.DomActiveAck = activeAck;
                receipt.DomDocumentFocused = documentFocused;
                if (receipt.DomEventAck && receipt.DomValueAck) break;
                WaitForUiMessage(until);
            }
            if (changed.Outcome == 2) return Finish("WRITE_UNKNOWN");
            if (changed.Outcome == 0) return Finish("WRITE_REFUSED");
            if (changed.Field?.Text != "привет" || !receipt.DomEventAck ||
                !receipt.DomValueAck || !receipt.DomActiveAck || !receipt.DomDocumentFocused)
                return Finish("SEMANTIC_GAP");
            return Finish("PASS");
        }
        catch (IOException) { return Finish("RPC_TIMEOUT"); }
        catch { return Finish(writeAttempted ? "WRITE_EXCEPTION" : "NOT_RUN"); }
        finally
        {
            if (markedWindow != IntPtr.Zero)
            { try { RemoveProp(markedWindow, "MacSwitcher.RuntimeBrowserFixture"); } catch { } }
            try { if (edge != null && !edge.HasExited) edge.Kill(true); } catch { }
            edge?.Dispose();
            try { Directory.Delete(temporary, true); } catch { }
        }
    }

    private static string ProbeEdgeRuntime(string edgeExecutable, string appExecutable,
        bool textarea, EdgeRuntimeReceipt receipt)
    {
        var temporary = Path.Combine(Path.GetTempPath(), "MacSwitcher-EdgeRuntime-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        var page = Path.Combine(temporary, "fixture.html");
        var kind = textarea ? "textarea" : "input";
        var pageMarker = "msw-" + kind + "-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(page, "<!doctype html><meta charset=\"utf-8\"><title>" +
            pageMarker + "-noevent-other-inactive-blurred</title><" + kind +
            " id=\"target\" aria-label=\"" + pageMarker + "-field\"" +
            (textarea ? ">ghbdtn</textarea>" : " value=\"ghbdtn\">") +
            "<script>const x=document.getElementById('target');let seen=false;" +
            "function update(){document.title='" + pageMarker +
            "-'+(seen?'event':'noevent')+'-'+(x.value==='привет'?'value':'other')+" +
            "'-'+(document.activeElement===x?'active':'inactive')+'-'+" +
            "(document.hasFocus()?'focused':'blurred')}" +
            "x.addEventListener('input',()=>{seen=true;update()});" +
            "function focusTarget(){x.focus();x.setSelectionRange(x.value.length,x.value.length);update()}" +
            "window.onload=focusTarget;window.addEventListener('focus',focusTarget);" +
            "setInterval(update,40)</script>", Encoding.UTF8);
        var profile = Path.Combine(temporary, "profile");
        var data = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(appExecutable))!, "data");
        Process? edge = null;
        IntPtr markedWindow = IntPtr.Zero;
        string Finish(string status) { receipt.Status = status; return status; }
        try
        {
            if (!File.Exists(Path.Combine(data, "dictionary-manifest.json")))
                return Finish("APP_DATA_MISSING");
            edge = Process.Start(new ProcessStartInfo(edgeExecutable,
                "--no-first-run --no-default-browser-check --disable-background-networking " +
                "--user-data-dir=\"" + profile + "\" --app=\"" + new Uri(page).AbsoluteUri + "\"")
            { UseShellExecute = false, CreateNoWindow = false });
            if (edge == null) return Finish("EDGE_START_FAILED");
            IntPtr edgeWindow = IntPtr.Zero;
            uint edgePid = 0;
            var until = Environment.TickCount64 + 6000;
            while (Environment.TickCount64 < until)
            {
                Application.DoEvents();
                var window = GetForegroundWindow();
                uint pid;
                GetWindowThreadProcessId(window, out pid);
                if (OwnEdgeWindow(window, pid, pageMarker))
                { edgeWindow = window; edgePid = pid; break; }
                WaitForUiMessage(until);
            }
            if (edgeWindow == IntPtr.Zero) return Finish("EDGE_FOCUS_UNAVAILABLE");
            var marker = System.Security.Cryptography.RandomNumberGenerator.GetInt32(1, int.MaxValue);
            if (SetProp(edgeWindow, "MacSwitcher.RuntimeBrowserFixture", new IntPtr(marker)) == IntPtr.Zero)
                return Finish("MARKER_UNAVAILABLE");
            markedWindow = edgeWindow;
            receipt.OwnWindow = OwnEdgeWindow(edgeWindow, edgePid, pageMarker);
            if (!receipt.OwnWindow) return Finish("FOCUS_DRIFT");
            if (!FocusOwnEdgeField(edgeWindow, edgePid, pageMarker, marker))
                return Finish("FOCUS_NOT_READY");
            until = Environment.TickCount64 + 3000;
            while (Environment.TickCount64 < until)
            {
                Application.DoEvents();
                bool eventAck, valueAck, activeAck, documentFocused;
                if (!OwnEdgeWindow(edgeWindow, edgePid, pageMarker)) return Finish("FOCUS_DRIFT");
                if (ReadEdgeTitleState(edgeWindow, pageMarker, out eventAck, out valueAck,
                    out activeAck, out documentFocused) && activeAck && documentFocused)
                { receipt.DomActiveAck = true; receipt.DomDocumentFocused = true; break; }
                WaitForUiMessage(until);
            }
            if (!receipt.DomActiveAck) return Finish("FOCUS_NOT_READY");
            using var session = new FixtureSession(appExecutable, data, marker, edgePid, pageMarker);
            if (!session.Ready) return Finish("CLIENT_UNAVAILABLE");
            try
            {
                var source = session.Command("SET_EN");
                receipt.InitialLayout = source.Layout;
                if (source.Layout != "en") return Finish("UNSUPPORTED");
                session.Command("CACHE");
            }
            catch { return Finish("UNSUPPORTED"); } // No text mutation has been attempted.
            if (!OwnEdgeWindow(edgeWindow, edgePid, pageMarker)) return Finish("FOCUS_DRIFT");
            bool beforeEvent, beforeValue, beforeActive, beforeFocused;
            if (!ReadEdgeTitleState(edgeWindow, pageMarker, out beforeEvent, out beforeValue,
                out beforeActive, out beforeFocused) || !beforeActive || !beforeFocused)
                return Finish("FOCUS_NOT_READY");
            var first = session.Command("TAP_L");
            if (first.Layout != "ru") return Finish("SOURCE_REFUSED");
            session.Command("TAP_R");
            var result = session.Command("WAIT");
            receipt.FinalLayout = result.Layout;
            receipt.Applied = result.Applied;
            receipt.Recovery = result.Recovery;
            receipt.FullOutcome = result.FullBrokerOutcome;
            receipt.FullPhase = result.FullBrokerPhase;
            receipt.FullBudgetMilliseconds = result.FullBudgetMilliseconds;
            receipt.FullRpcMilliseconds = result.FullRpcMilliseconds;
            until = Environment.TickCount64 + 1500;
            while (Environment.TickCount64 < until)
            {
                Application.DoEvents();
                bool eventAck, valueAck, activeAck, documentFocused;
                if (!ReadEdgeTitleState(edgeWindow, pageMarker, out eventAck, out valueAck,
                    out activeAck, out documentFocused))
                    return Finish("FOCUS_DRIFT");
                receipt.DomEventAck = eventAck;
                receipt.DomValueAck = valueAck;
                receipt.DomActiveAck = activeAck;
                receipt.DomDocumentFocused = documentFocused;
                if (receipt.DomEventAck && receipt.DomValueAck) break;
                WaitForUiMessage(until);
            }
            if (result.Recovery || result.FullBrokerOutcome == 2)
                return Finish("RUNTIME_UNKNOWN");
            if (result.Applied < 1 || result.FullBrokerOutcome != 1)
                return Finish("RUNTIME_REFUSED");
            if (result.FullBudgetMilliseconds < 1 || result.FullBudgetMilliseconds > 120 ||
                result.FullRpcMilliseconds < 0 ||
                result.FullRpcMilliseconds > result.FullBudgetMilliseconds)
                return Finish("RUNTIME_BUDGET_FAIL");
            if (result.Layout != "ru") return Finish("SOURCE_MISMATCH");
            if (!receipt.DomEventAck || !receipt.DomValueAck || !receipt.DomActiveAck ||
                !receipt.DomDocumentFocused)
                return Finish("RUNTIME_SEMANTIC_GAP");
            return Finish("PASS");
        }
        catch { return Finish("RUNTIME_EXCEPTION"); }
        finally
        {
            if (markedWindow != IntPtr.Zero)
            { try { RemoveProp(markedWindow, "MacSwitcher.RuntimeBrowserFixture"); } catch { } }
            try { if (edge != null && !edge.HasExited) edge.Kill(true); } catch { }
            edge?.Dispose();
            try { Directory.Delete(temporary, true); } catch { }
        }
    }

    private sealed class Broker : IDisposable
    {
        private readonly Process process;
        private readonly BinaryReader reader;
        private readonly BinaryWriter writer;
        private bool disposed;

        public Broker(string path)
        {
            process = Process.Start(new ProcessStartInfo(path, "--automation-broker")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true })!;
            reader = new BinaryReader(process.StandardOutput.BaseStream, Encoding.UTF8);
            writer = new BinaryWriter(process.StandardInput.BaseStream, Encoding.UTF8);
        }

        public Result Call(byte operation, Field? expected, string? replacement,
            int rangeStart = -1, int rangeEnd = -1)
        {
            var foreground = GetForegroundWindow();
            uint pid;
            var tid = GetWindowThreadProcessId(foreground, out pid);
            var info = new GuiThreadInfo { cbSize = (uint)Marshal.SizeOf<GuiThreadInfo>() };
            if (!GetGUIThreadInfo(tid, ref info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] packet;
            using (var memory = new MemoryStream())
            using (var payload = new BinaryWriter(memory, Encoding.UTF8, true))
            {
                payload.Write(operation);
                payload.Write(foreground.ToInt64()); payload.Write(info.hwndFocus.ToInt64());
                payload.Write(pid); payload.Write(tid); payload.Write(GetKeyboardLayout(tid).ToInt64());
                payload.Write(operation != 1 ? Environment.TickCount64 + 2000 : 0L);
                payload.Write(rangeStart); payload.Write(rangeEnd);
                WriteField(payload, expected); WriteText(payload, replacement ?? ""); payload.Flush();
                packet = memory.ToArray();
            }
            writer.Write(packet.Length); writer.Write(packet); writer.Flush();
            return ReadResponse(reader);
        }

        public static Result ReadResponse(BinaryReader input)
        {
            var size = input.ReadInt32(); if (size < 1 || size > 1048576) throw new InvalidDataException();
            var bytes = input.ReadBytes(size); if (bytes.Length != size) throw new EndOfStreamException();
            using var response = new BinaryReader(new MemoryStream(bytes, false), Encoding.UTF8);
            var result = new Result { Outcome = response.ReadByte(), Stage = response.ReadByte(),
                Phase = response.ReadByte(),
                NativeError = response.ReadInt32(),
                HResult = response.ReadInt32(),
                DiagnosticTextLength = response.ReadInt32(),
                DiagnosticStart = response.ReadInt32(),
                DiagnosticEnd = response.ReadInt32(),
                DiagnosticNativeClassKind = response.ReadInt32(),
                UiAvailable = response.ReadBoolean(),
                UiSameRuntimeId = response.ReadBoolean(),
                UiHasKeyboardFocus = response.ReadBoolean(),
                UiSameProcess = response.ReadBoolean(),
                UiEditType = response.ReadBoolean(),
                UiCredentialFlagClear = response.ReadBoolean(),
                UiEnabled = response.ReadBoolean(),
                NativeSameRoot = response.ReadBoolean(),
                NativeSameProcess = response.ReadBoolean(),
                NativeSameThread = response.ReadBoolean(),
                Field = ReadField(response) };
            if (response.BaseStream.Position != response.BaseStream.Length) throw new InvalidDataException();
            return result;
        }

        private static void WriteField(BinaryWriter target, Field? field)
        {
            target.Write(field != null);
            if (field == null) return;
            target.Write(field.Foreground); target.Write(field.Focus); target.Write(field.Pid); target.Write(field.Tid);
            target.Write(field.Id.Length); foreach (var id in field.Id) target.Write(id);
            WriteText(target, field.Text); target.Write(field.Start); target.Write(field.End);
            target.Write(field.CanWrite); target.Write(field.NativeRangeWriter);
        }

        private static Field? ReadField(BinaryReader source)
        {
            if (!source.ReadBoolean()) return null;
            var field = new Field { Foreground = source.ReadInt64(), Focus = source.ReadInt64(),
                Pid = source.ReadUInt32(), Tid = source.ReadUInt32() };
            var ids = source.ReadInt32(); if (ids < 1 || ids > 64) throw new InvalidDataException();
            field.Id = new int[ids]; for (int i = 0; i < ids; i++) field.Id[i] = source.ReadInt32();
            field.Text = ReadText(source); field.Start = source.ReadInt32(); field.End = source.ReadInt32();
            field.CanWrite = source.ReadBoolean(); field.NativeRangeWriter = source.ReadBoolean(); return field;
        }

        private static void WriteText(BinaryWriter target, string text)
        {
            var bytes = new UTF8Encoding(false, true).GetBytes(text);
            if (bytes.Length > 262144) throw new InvalidDataException();
            target.Write(bytes.Length); target.Write(bytes);
        }

        private static string ReadText(BinaryReader source)
        {
            var count = source.ReadInt32(); if (count < 0 || count > 262144) throw new InvalidDataException();
            var bytes = source.ReadBytes(count); if (bytes.Length != count) throw new EndOfStreamException();
            return new UTF8Encoding(false, true).GetString(bytes);
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            try { if (!process.HasExited) process.Kill(); } catch { }
            try { reader.Dispose(); } catch { }
            try { writer.Dispose(); } catch { }
            process.Dispose();
        }
    }
}
