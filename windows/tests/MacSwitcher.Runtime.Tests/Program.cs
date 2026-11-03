using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;
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
    private static string hookStatus = "NOT_RUN";
    private static string integrationStatus = "NOT_RUN";
    private static string integrationProbe = "NOT_RUN";
    private static string integrationLayout = "";
    private static int integrationApplied, integrationUndone, integrationTextLength = -1;
    private static bool integrationExpectedText;
    private static int integrationManualCode;
    private static int integrationNativeCode, integrationNativeBrokerOutcome = -1;
    private static int integrationNativeBrokerStage = -1, integrationNativeBudgetMilliseconds = -1;
    private static int integrationNativeBrokerPhase = -1;
    private static int integrationNativeRpcMilliseconds = -1;
    private static string integrationWaitStatus = "NOT_RUN";
    private static string brokerProbe = "NOT_RUN";
    private static int brokerOutcome = -1, brokerStage = -1;
    private static int brokerPhase = -1;
    private static int brokerNativeCode;
    private static bool fixtureForeground, fixtureFocus;
    private static int brokerTextLength = -1, brokerSelectionStart = -1, brokerSelectionEnd = -1;
    private static int brokerNativeClassKind = -1;
    private static bool brokerSameFixturePid, brokerFocusMatchesPlain;
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
        public int DiagnosticTextLength, DiagnosticStart, DiagnosticEnd;
        public int DiagnosticNativeClassKind;
        public Field? Field;
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
                    frame.NativeError != 5 ||
                    frame.DiagnosticTextLength != 7 || frame.DiagnosticStart != 2 ||
                    frame.DiagnosticEnd != 4 || frame.DiagnosticNativeClassKind != 1 ||
                    frame.Field?.Text != "fixture" || frame.Field.Start != 2 || frame.Field.End != 4 ||
                    !frame.Field.NativeRangeWriter)
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
        using var form = new Form { Width = 400, Height = 280, Text = "MacSwitcher synthetic fixture" };
        using var plain = new TextBox { Left = 10, Top = 10, Width = 320, Text = "ghbdtn" };
        using var password = new TextBox { Left = 10, Top = 45, Width = 320, Text = "synthetic-secret", UseSystemPasswordChar = true };
        using var readOnly = new TextBox { Left = 10, Top = 80, Width = 320, Text = "readonly", ReadOnly = true };
        using var rich = new RichTextBox { Left = 10, Top = 115, Width = 320, Height = 55, Text = "rich" };
        using var drift = new SelectionDriftTextBox { Left = 10, Top = 180, Width = 320, Text = "ghbdtn" };
        form.Controls.AddRange([plain, password, readOnly, rich, drift]);
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

        using var broker = new Broker(path);
        int checks = 5;
        try
        {
            Result? captured = null;
            for (int attempt = 0; attempt < 4; attempt++)
            {
                captured = PumpBroker(() => broker.Call(1, null, null),
                    attempt == 0 ? 10000 : 3000, out brokerProbe);
                if (captured == null) return Report("FAIL", "plain_capture_rpc", checks);
                brokerOutcome = captured.Outcome;
                brokerStage = captured.Stage;
                brokerPhase = captured.Phase;
                brokerNativeCode = captured.NativeError;
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
            integrationStatus = RunRuntimeIntegration(form, plain, password, path, out var integrationChecks);
            checks += integrationChecks;
            if (integrationStatus == "NOT_RUN") return Report("NOT_RUN", "runtime_integration_precondition", checks);
            if (integrationStatus != "PASS") return Report("FAIL", "runtime_integration", checks);
            var edge = FindEdge();
            if (edge != null)
            {
                edgeInput = ProbeEdge(broker, edge, false);
                if (edgeInput == "RPC_TIMEOUT") return Report("FAIL", "edge_rpc_timeout", checks);
                edgeTextarea = ProbeEdge(broker, edge, true);
                if (edgeTextarea == "RPC_TIMEOUT") return Report("FAIL", "edge_rpc_timeout", checks);
                if (edgeInput == "SEMANTIC_GAP" || edgeTextarea == "SEMANTIC_GAP")
                    return Report("FAIL", "edge_dom_input_event", checks);
                if (edgeInput == "PASS") checks++;
                if (edgeTextarea == "PASS") checks++;
            }
            return Report("PASS", "synthetic_uia_broker", checks);
        }
        catch { return Report("FAIL", "broker_exception", checks); }
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
        brokerNativeCode = response.NativeError;
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
            ",\"integrationNativeCode\":" + integrationNativeCode +
            ",\"integrationNativeBrokerOutcome\":" + integrationNativeBrokerOutcome +
            ",\"integrationNativeBrokerStage\":" + integrationNativeBrokerStage +
            ",\"integrationNativeBrokerPhase\":" + integrationNativeBrokerPhase +
            ",\"integrationNativeRpcMilliseconds\":" + integrationNativeRpcMilliseconds +
            ",\"integrationNativeBudgetMilliseconds\":" + integrationNativeBudgetMilliseconds +
            ",\"integrationWaitStatus\":\"" + integrationWaitStatus +
            "\",\"brokerProbe\":\"" + brokerProbe +
            "\",\"brokerOutcome\":" + brokerOutcome +
            ",\"brokerStage\":" + brokerStage +
            ",\"brokerPhase\":" + brokerPhase +
            ",\"brokerNativeCode\":" + brokerNativeCode +
            ",\"fixtureForeground\":" + (fixtureForeground ? "true" : "false") +
            ",\"fixtureFocus\":" + (fixtureFocus ? "true" : "false") +
            ",\"brokerTextLength\":" + brokerTextLength +
            ",\"brokerSelectionStart\":" + brokerSelectionStart +
            ",\"brokerSelectionEnd\":" + brokerSelectionEnd +
            ",\"brokerNativeClassKind\":" + brokerNativeClassKind +
            ",\"brokerSameFixturePid\":" + (brokerSameFixturePid ? "true" : "false") +
            ",\"brokerFocusMatchesPlain\":" + (brokerFocusMatchesPlain ? "true" : "false") +
            ",\"edgeInput\":\"" + edgeInput +
            "\",\"edgeTextarea\":\"" + edgeTextarea + "\"}");
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
            integrationProbe = "manual_undo";
            if (session.Command("TAP_R").Layout != "en") return "FAIL";
            session.Command("TAP_L");
            result = session.Command("WAIT");
            if (plain.Text != "ghbdtn" || result.Undone < 1 || result.Layout != "en") return "FAIL";
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

            integrationProbe = "selection";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = "ghbdtn world"; plain.Select(0, 6);
            session.Command("CACHE"); session.Command("TAP_L"); session.Command("TAP_R");
            result = session.Command("WAIT");
            if (plain.Text != "привет world" || result.Applied < 5) return "FAIL";
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
            if (plain.Text != "ghbdtn туче" || result.Applied < 6) return "FAIL";
            checks++;

            integrationProbe = "auto_early";
            LoadKeyboardLayout("00000409", 1);
            plain.Text = ""; plain.SelectionStart = 0;
            session.Command("AUTO_ON"); session.Command("CACHE");
            foreach (var letter in "ghbd")
            {
                session.Command("KEY_D"); plain.AppendText(letter.ToString());
                session.Command("KEY_U");
            }
            result = session.Command("WAIT");
            if (plain.Text != "прив" || result.Applied < 7) return "FAIL";
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
            if (plain.Text != "как " || result.Applied < 8) return "FAIL";
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
            NativeBrokerPhase, NativeRpcMilliseconds;
    }

    private sealed class FixtureSession : IDisposable
    {
        private readonly Process process;
        public bool Ready { get; }

        public FixtureSession(string executable, string data, int marker)
        {
            var start = new ProcessStartInfo(executable,
                "--runtime-fixture-client " + Environment.ProcessId)
            { UseShellExecute = false, CreateNoWindow = true,
              RedirectStandardInput = true, RedirectStandardOutput = true };
            start.Environment["MACSWITCHER_RUNTIME_FIXTURE_MARKER"] = marker.ToString();
            start.Environment["MACSWITCHER_RUNTIME_FIXTURE_DATA"] = data;
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
            if (pieces.Length != 12) throw new InvalidOperationException();
            if (command == "WAIT") integrationWaitStatus = "SETTLED";
            var reply = new FixtureReply { Applied = int.Parse(pieces[1]), Undone = int.Parse(pieces[2]),
                Layout = pieces[3], Recovery = pieces[4] == "1", ManualCode = int.Parse(pieces[5]),
                NativeCode = int.Parse(pieces[6]), NativeBrokerOutcome = int.Parse(pieces[7]),
                NativeBrokerStage = int.Parse(pieces[8]), NativeBudgetMilliseconds = int.Parse(pieces[9]),
                NativeBrokerPhase = int.Parse(pieces[10]), NativeRpcMilliseconds = int.Parse(pieces[11]) };
            integrationManualCode = reply.ManualCode;
            integrationNativeCode = reply.NativeCode;
            integrationNativeBrokerOutcome = reply.NativeBrokerOutcome;
            integrationNativeBrokerStage = reply.NativeBrokerStage;
            integrationNativeBudgetMilliseconds = reply.NativeBudgetMilliseconds;
            integrationNativeBrokerPhase = reply.NativeBrokerPhase;
            integrationNativeRpcMilliseconds = reply.NativeRpcMilliseconds;
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

    private static string ProbeEdge(Broker broker, string executable, bool textarea)
    {
        var temporary = Path.Combine(Path.GetTempPath(), "MacSwitcher-EdgeFixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        var page = Path.Combine(temporary, "fixture.html");
        var kind = textarea ? "textarea" : "input";
        File.WriteAllText(page, "<!doctype html><meta charset=\"utf-8\"><title>fixture-idle</title>" +
            "<" + kind + " id=\"target\">" + (textarea ? "ghbdtn</textarea>" : "") +
            (textarea ? "" : "<script>document.getElementById('target').value='ghbdtn'</script>") +
            "<script>const x=document.getElementById('target');x.addEventListener('input',()=>document.title='fixture-input-fired');window.onload=()=>x.focus()</script>", Encoding.UTF8);
        var profile = Path.Combine(temporary, "profile");
        Process? edge = null;
        try
        {
            edge = Process.Start(new ProcessStartInfo(executable,
                "--no-first-run --no-default-browser-check --disable-background-networking " +
                "--user-data-dir=\"" + profile + "\" --app=\"" + new Uri(page).AbsoluteUri + "\"")
            { UseShellExecute = false, CreateNoWindow = false });
            if (edge == null) return "NOT_RUN";
            IntPtr edgeWindow = IntPtr.Zero;
            var until = Environment.TickCount64 + 6000;
            while (Environment.TickCount64 < until)
            {
                Application.DoEvents();
                var window = GetForegroundWindow();
                uint pid;
                GetWindowThreadProcessId(window, out pid);
                try
                {
                    if (pid != 0 && Process.GetProcessById((int)pid).ProcessName.Equals("msedge", StringComparison.OrdinalIgnoreCase))
                    { edgeWindow = window; break; }
                }
                catch { }
                Thread.Sleep(20);
            }
            if (edgeWindow == IntPtr.Zero) return "NOT_RUN";
            Result? captured = null;
            for (int attempt = 0; attempt < 10; attempt++)
            {
                captured = RequireBroker(() => broker.Call(1, null, null), attempt == 0 ? 5000 : 3000);
                if (captured?.Outcome == 1 && captured.Field?.Text == "ghbdtn") break;
                Application.DoEvents(); Thread.Sleep(100);
            }
            if (captured?.Outcome != 1 || captured.Field == null || !captured.Field.CanWrite ||
                captured.Field.Text != "ghbdtn") return "UNSUPPORTED";
            var title = new StringBuilder(256);
            GetWindowText(edgeWindow, title, title.Capacity);
            if (!title.ToString().Contains("fixture-idle", StringComparison.Ordinal)) return "NOT_RUN";
            var changed = RequireBroker(() => broker.Call(2, captured.Field, "привет"));
            if (changed?.Outcome != 1 || changed.Field?.Text != "привет") return "UNSUPPORTED";
            until = Environment.TickCount64 + 1000;
            while (Environment.TickCount64 < until)
            {
                Application.DoEvents();
                GetWindowText(edgeWindow, title, title.Capacity);
                if (title.ToString().Contains("fixture-input-fired", StringComparison.Ordinal)) return "PASS";
                Thread.Sleep(10);
            }
            return "SEMANTIC_GAP";
        }
        catch (IOException) { return "RPC_TIMEOUT"; }
        catch { return "NOT_RUN"; }
        finally
        {
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
                DiagnosticTextLength = response.ReadInt32(),
                DiagnosticStart = response.ReadInt32(),
                DiagnosticEnd = response.ReadInt32(),
                DiagnosticNativeClassKind = response.ReadInt32(),
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
            try { if (!process.HasExited) process.Kill(); } catch { }
            reader.Dispose(); writer.Dispose(); process.Dispose();
        }
    }
}
