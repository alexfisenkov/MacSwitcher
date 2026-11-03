using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using MacSwitcher.Windows.Native;

namespace MacSwitcher.Windows.Automation
{
    internal enum BrokerOutcome : byte { Unsafe = 0, Success = 1, Unknown = 2 }
    internal enum BrokerStage : byte
    {
        None = 0, Focus = 1, Desktop = 2, Layout = 3, Integrity = 4,
        Element = 5, Identity = 6, Password = 7, ReadOnly = 8,
        Pattern = 9, Value = 10, Selection = 11, RuntimeId = 12,
        Postcheck = 13, Exception = 14, SelectionRange = 15,
        SelectionPattern = 16, NativeDeadline = 17,
        NativeModifier = 18, NativeMessage = 19, NativeMismatch = 20
    }
    internal enum BrokerPhase : byte
    {
        None = 0, NativePrecondition = 1, NativeFirstCapture = 2,
        NativeState = 3, NativeSetSelection = 4, NativeSelectionAck = 5,
        NativeBeforeMutation = 6, NativeReplaceDelivery = 7,
        NativeReadback = 8, NativeFinalAck = 9
    }

    internal sealed class FieldSnapshot
    {
        internal IntPtr Foreground, Focus;
        internal uint ProcessId, ThreadId;
        internal int[] RuntimeId = Array.Empty<int>();
        internal string Value = "";
        internal int SelectionStart, SelectionEnd;
        internal bool CanWrite;
        internal bool NativeRangeWriter;

        internal bool SameIdentity(FieldSnapshot? other)
        {
            return other != null && Foreground == other.Foreground && Focus == other.Focus &&
                ProcessId == other.ProcessId && ThreadId == other.ThreadId &&
                RuntimeId != null && other.RuntimeId != null && RuntimeId.SequenceEqual(other.RuntimeId);
        }

        internal bool SameState(FieldSnapshot? other)
        {
            return other != null && SameIdentity(other) && Value == other.Value &&
                SelectionStart == other.SelectionStart && SelectionEnd == other.SelectionEnd;
        }
    }

    internal sealed class BrokerResponse
    {
        internal BrokerOutcome Outcome;
        internal BrokerStage Stage;
        internal BrokerPhase Phase;
        internal int NativeError;
        internal int DiagnosticTextLength = -1;
        internal int DiagnosticSelectionStart = -1;
        internal int DiagnosticSelectionEnd = -1;
        internal int DiagnosticNativeClassKind = -1; // 0 other, 1 Edit, 2 RichEdit.
        internal FieldSnapshot? Field;
    }

    internal static class BrokerWire
    {
        internal const int MaxTextBytes = 262144;
        internal const int MaxFrameBytes = 1048576;
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

        internal static bool IsWellFormedUtf16(string? value)
        {
            if (value == null) return false;
            for (int i = 0; i < value.Length; i++)
            {
                if (value[i] == '\0') return false;
                if (char.IsHighSurrogate(value[i]))
                {
                    if (++i >= value.Length || !char.IsLowSurrogate(value[i])) return false;
                }
                else if (char.IsLowSurrogate(value[i])) return false;
            }
            return true;
        }

        internal static bool IsScalarBoundary(string value, int offset)
        {
            return offset >= 0 && offset <= value.Length &&
                !(offset > 0 && offset < value.Length &&
                  char.IsHighSurrogate(value[offset - 1]) && char.IsLowSurrogate(value[offset]));
        }

        internal static byte[] EncodeFrame(Action<BinaryWriter> write)
        {
            using (var memory = new MemoryStream())
            using (var payload = new BinaryWriter(memory, Encoding.UTF8, true))
            {
                write(payload);
                payload.Flush();
                if (memory.Length < 1 || memory.Length > MaxFrameBytes)
                    throw new InvalidDataException("IPC frame bound exceeded.");
                return memory.ToArray();
            }
        }

        internal static void WriteFrame(BinaryWriter output, byte[] payload)
        {
            if (payload.Length < 1 || payload.Length > MaxFrameBytes)
                throw new InvalidDataException("IPC frame bound exceeded.");
            output.Write(payload.Length);
            output.Write(payload);
            output.Flush();
        }

        internal static BinaryReader ReadFrame(BinaryReader input)
        {
            var length = input.ReadInt32();
            if (length < 1 || length > MaxFrameBytes) throw new InvalidDataException("IPC frame bound exceeded.");
            var bytes = input.ReadBytes(length);
            if (bytes.Length != length) throw new EndOfStreamException();
            return new BinaryReader(new MemoryStream(bytes, false), Encoding.UTF8);
        }

        internal static byte[] EncodeResponse(BrokerResponse result)
        {
            return EncodeFrame(payload =>
            {
                payload.Write((byte)result.Outcome);
                payload.Write((byte)result.Stage);
                payload.Write((byte)result.Phase);
                payload.Write(result.NativeError);
                payload.Write(result.DiagnosticTextLength);
                payload.Write(result.DiagnosticSelectionStart);
                payload.Write(result.DiagnosticSelectionEnd);
                payload.Write(result.DiagnosticNativeClassKind);
                WriteField(payload, result.Field);
            });
        }

        internal static void WriteText(BinaryWriter output, string? value)
        {
            if (!IsWellFormedUtf16(value ?? "")) throw new EncoderFallbackException("Invalid UTF-16.");
            var bytes = StrictUtf8.GetBytes(value ?? "");
            if (bytes.Length > MaxTextBytes) throw new InvalidDataException("Text bound exceeded.");
            output.Write(bytes.Length);
            output.Write(bytes);
        }

        internal static string ReadText(BinaryReader input)
        {
            var count = input.ReadInt32();
            if (count < 0 || count > MaxTextBytes) throw new InvalidDataException("Text bound exceeded.");
            var bytes = input.ReadBytes(count);
            if (bytes.Length != count) throw new EndOfStreamException();
            return StrictUtf8.GetString(bytes);
        }

        internal static void WriteField(BinaryWriter output, FieldSnapshot? field)
        {
            output.Write(field != null);
            if (field == null) return;
            if (field.RuntimeId == null || field.RuntimeId.Length < 1 || field.RuntimeId.Length > 64 ||
                field.Value == null || field.Value.Length > 32768 || !IsWellFormedUtf16(field.Value) ||
                field.SelectionStart < 0 || field.SelectionEnd < field.SelectionStart ||
                field.SelectionEnd > field.Value.Length ||
                !IsScalarBoundary(field.Value, field.SelectionStart) ||
                !IsScalarBoundary(field.Value, field.SelectionEnd))
                throw new InvalidDataException("Field bounds exceeded.");
            output.Write(field.Foreground.ToInt64());
            output.Write(field.Focus.ToInt64());
            output.Write(field.ProcessId);
            output.Write(field.ThreadId);
            output.Write(field.RuntimeId.Length);
            foreach (var id in field.RuntimeId) output.Write(id);
            WriteText(output, field.Value);
            output.Write(field.SelectionStart);
            output.Write(field.SelectionEnd);
            output.Write(field.CanWrite);
            output.Write(field.NativeRangeWriter);
        }

        internal static FieldSnapshot? ReadField(BinaryReader input)
        {
            if (!input.ReadBoolean()) return null;
            var field = new FieldSnapshot();
            field.Foreground = new IntPtr(input.ReadInt64());
            field.Focus = new IntPtr(input.ReadInt64());
            field.ProcessId = input.ReadUInt32();
            field.ThreadId = input.ReadUInt32();
            int count = input.ReadInt32();
            if (count < 1 || count > 64) throw new InvalidDataException("Runtime ID bound exceeded.");
            field.RuntimeId = new int[count];
            for (int i = 0; i < count; i++) field.RuntimeId[i] = input.ReadInt32();
            field.Value = ReadText(input);
            field.SelectionStart = input.ReadInt32();
            field.SelectionEnd = input.ReadInt32();
            field.CanWrite = input.ReadBoolean();
            field.NativeRangeWriter = input.ReadBoolean();
            if (field.Value.Length > 32768 || field.SelectionStart < 0 || field.SelectionEnd < field.SelectionStart ||
                field.SelectionEnd > field.Value.Length ||
                !IsScalarBoundary(field.Value, field.SelectionStart) ||
                !IsScalarBoundary(field.Value, field.SelectionEnd))
                throw new InvalidDataException("Field bounds exceeded.");
            return field;
        }
    }

    // Each call has an external deadline. A stuck provider is discarded with its broker process.
    internal sealed class AutomationBrokerClient : IDisposable
    {
        private readonly object gate = new object();
        private Process? process;
        private BinaryReader? reader;
        private BinaryWriter? writer;
        private bool disposed;

        private void EnsureStarted()
        {
            if (process != null && !process.HasExited) return;
            var executable = Assembly.GetExecutingAssembly().Location;
            var start = new ProcessStartInfo(executable, "--automation-broker")
            {
                UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardInput = true, RedirectStandardOutput = true
            };
            process = Process.Start(start);
            if (process == null) throw new IOException("Automation broker could not start.");
            reader = new BinaryReader(process.StandardOutput.BaseStream, Encoding.UTF8, true);
            writer = new BinaryWriter(process.StandardInput.BaseStream, Encoding.UTF8, true);
        }

        private void Terminate()
        {
            try { if (process != null && !process.HasExited) process.Kill(); } catch { }
            try { reader?.Dispose(); } catch { }
            try { writer?.Dispose(); } catch { }
            try { process?.Dispose(); } catch { }
            reader = null; writer = null; process = null;
        }

        internal BrokerResponse Capture(NativeFocusSnapshot? focus, int timeoutMilliseconds)
        {
            if (focus == null) return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
            return Call(1, focus, null, null, timeoutMilliseconds);
        }

        internal BrokerResponse WriteValue(NativeFocusSnapshot? focus, FieldSnapshot? expected, string? replacement, int timeoutMilliseconds)
        {
            if (focus == null || expected == null || replacement == null || replacement.Length > 32768)
                return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
            return Call(2, focus, expected, replacement, timeoutMilliseconds);
        }

        internal BrokerResponse ReplaceNativeRange(NativeFocusSnapshot? focus, FieldSnapshot? expected,
            int start, int end, string? replacement, int timeoutMilliseconds)
        {
            if (focus == null || expected == null || !expected.NativeRangeWriter ||
                start < 0 || end < start || end > expected.Value.Length || replacement == null ||
                replacement.Length > 4096 || !BrokerWire.IsScalarBoundary(expected.Value, start) ||
                !BrokerWire.IsScalarBoundary(expected.Value, end))
                return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
            return Call(3, focus, expected, replacement, timeoutMilliseconds, start, end);
        }

        private BrokerResponse Call(byte operation, NativeFocusSnapshot focus, FieldSnapshot? expected, string? replacement, int timeoutMilliseconds)
        { return Call(operation, focus, expected, replacement, timeoutMilliseconds, -1, -1); }

        private BrokerResponse Call(byte operation, NativeFocusSnapshot focus, FieldSnapshot? expected,
            string? replacement, int timeoutMilliseconds, int rangeStart, int rangeEnd)
        {
            lock (gate)
            {
                if (disposed) return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
                try
                {
                    var deadline = operation == 2 || operation == 3
                        ? (long)Win32.GetTickCount64() + Math.Max(1, timeoutMilliseconds) : 0;
                    byte[] packet;
                    try
                    {
                        packet = BrokerWire.EncodeFrame(payload =>
                        {
                            payload.Write(operation);
                            payload.Write(focus.Foreground.ToInt64());
                            payload.Write(focus.Focus.ToInt64());
                            payload.Write(focus.ProcessId);
                            payload.Write(focus.ThreadId);
                            payload.Write(focus.Layout.ToInt64());
                            payload.Write(deadline);
                            payload.Write(rangeStart);
                            payload.Write(rangeEnd);
                            BrokerWire.WriteField(payload, expected);
                            BrokerWire.WriteText(payload, replacement);
                        });
                    }
                    catch (EncoderFallbackException)
                    { return new BrokerResponse { Outcome = BrokerOutcome.Unsafe }; }
                    catch (InvalidDataException)
                    { return new BrokerResponse { Outcome = BrokerOutcome.Unsafe }; }
                    bool coldCapture = operation == 1 && (process == null || process.HasExited);
                    EnsureStarted();
                    if (operation != 1 && (long)Win32.GetTickCount64() >= deadline)
                        return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
                    // Never close over mutable instance streams: a timed-out call may still be scheduled
                    // when a later call starts a new broker generation.
                    var callReader = reader!;
                    var callWriter = writer!;
                    var task = Task.Run(() =>
                    {
                        BrokerWire.WriteFrame(callWriter, packet);
                        using var responseFrame = BrokerWire.ReadFrame(callReader);
                        var response = new BrokerResponse { Outcome = (BrokerOutcome)responseFrame.ReadByte() };
                        response.Stage = (BrokerStage)responseFrame.ReadByte();
                        response.Phase = (BrokerPhase)responseFrame.ReadByte();
                        response.NativeError = responseFrame.ReadInt32();
                        response.DiagnosticTextLength = responseFrame.ReadInt32();
                        response.DiagnosticSelectionStart = responseFrame.ReadInt32();
                        response.DiagnosticSelectionEnd = responseFrame.ReadInt32();
                        response.DiagnosticNativeClassKind = responseFrame.ReadInt32();
                        response.Field = BrokerWire.ReadField(responseFrame);
                        if (responseFrame.BaseStream.Position != responseFrame.BaseStream.Length)
                            throw new InvalidDataException("Unexpected response bytes.");
                        if (response.Outcome > BrokerOutcome.Unknown ||
                            response.Stage > BrokerStage.NativeMismatch ||
                            response.Phase > BrokerPhase.NativeFinalAck)
                            throw new InvalidDataException("Invalid broker response.");
                        return response;
                    });
                    var remaining = operation != 1
                        ? (int)Math.Max(1, deadline - (long)Win32.GetTickCount64())
                        : coldCapture ? Math.Max(3000, timeoutMilliseconds)
                            : Math.Max(1, timeoutMilliseconds);
                    if (!task.Wait(remaining))
                    {
                        Terminate();
                        task.ContinueWith(t => { var ignored = t.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                        return new BrokerResponse { Outcome = operation != 1 ? BrokerOutcome.Unknown : BrokerOutcome.Unsafe };
                    }
                    return task.Result;
                }
                catch
                {
                    Terminate();
                    return new BrokerResponse { Outcome = operation != 1 ? BrokerOutcome.Unknown : BrokerOutcome.Unsafe };
                }
            }
        }

        public void Dispose()
        {
            lock (gate) { disposed = true; Terminate(); }
        }
    }

    internal static class AutomationBrokerServer
    {
        private static bool TryReadNativeEditText(IntPtr hwnd, uint timeout,
            out string text, out int nativeError)
        {
            text = "";
            nativeError = 0;
            IntPtr lengthResult;
            if (Win32.SendMessageTimeout(hwnd, Win32.WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero,
                Win32.SMTO_ABORTIFHUNG | Win32.SMTO_ERRORONEXIT, timeout,
                out lengthResult) == IntPtr.Zero)
            { nativeError = Marshal.GetLastWin32Error(); return false; }
            var length = lengthResult.ToInt64();
            if (length < 0 || length > 32768) return false;
            var buffer = new StringBuilder((int)length + 1);
            IntPtr copiedResult;
            if (Win32.SendMessageTimeoutTextBuffer(hwnd, Win32.WM_GETTEXT,
                new IntPtr(buffer.Capacity), buffer,
                Win32.SMTO_ABORTIFHUNG | Win32.SMTO_ERRORONEXIT, timeout,
                out copiedResult) == IntPtr.Zero)
            { nativeError = Marshal.GetLastWin32Error(); return false; }
            var copied = copiedResult.ToInt64();
            if (copied < 0 || copied > length || copied != buffer.Length) return false;
            text = buffer.ToString();
            return BrokerWire.IsWellFormedUtf16(text);
        }

        internal static int Run()
        {
            var thread = new Thread(Serve) { IsBackground = false, Name = "MacSwitcher UIA MTA" };
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
            thread.Join();
            return 0;
        }

        private static void Serve()
        {
            using (var input = new BinaryReader(Console.OpenStandardInput(), Encoding.UTF8))
            using (var output = new BinaryWriter(Console.OpenStandardOutput(), Encoding.UTF8))
            {
                while (true)
                {
                    BinaryReader request;
                    try { request = BrokerWire.ReadFrame(input); }
                    catch { return; }
                    BrokerResponse result;
                    try
                    {
                        var operation = request.ReadByte();
                        var foreground = new IntPtr(request.ReadInt64());
                        var focusHwnd = new IntPtr(request.ReadInt64());
                        var pid = request.ReadUInt32();
                        var tid = request.ReadUInt32();
                        var expectedLayout = new IntPtr(request.ReadInt64());
                        var deadline = request.ReadInt64();
                        var rangeStart = request.ReadInt32();
                        var rangeEnd = request.ReadInt32();
                        var expected = BrokerWire.ReadField(request);
                        var replacement = BrokerWire.ReadText(request);
                        if (request.BaseStream.Position != request.BaseStream.Length)
                            throw new InvalidDataException("Unexpected request bytes.");
                        var focus = NativeFocusSnapshot.Capture();
                        if (operation == 1)
                        {
                            BrokerStage stage;
                            int nativeError;
                            int textLength, selectionStart, selectionEnd, nativeClassKind;
                            var field = SafeCapture(focus, foreground, focusHwnd, pid, tid,
                                expectedLayout, out stage, out nativeError, out textLength,
                                out selectionStart, out selectionEnd, out nativeClassKind, 150);
                            result = new BrokerResponse { Outcome = field == null ? BrokerOutcome.Unsafe : BrokerOutcome.Success,
                                Stage = stage, NativeError = nativeError, Field = field,
                                DiagnosticTextLength = textLength,
                                DiagnosticSelectionStart = selectionStart,
                                DiagnosticSelectionEnd = selectionEnd,
                                DiagnosticNativeClassKind = nativeClassKind };
                        }
                        else if (operation == 2)
                            result = SafeWrite(focus, foreground, focusHwnd, pid, tid,
                                expectedLayout, deadline, expected, replacement);
                        else if (operation == 3)
                            result = SafeReplaceNativeRange(focus, foreground, focusHwnd, pid, tid,
                                expectedLayout, deadline, expected, rangeStart, rangeEnd, replacement);
                        else result = new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
                        if (result.Field == null && result.Outcome == BrokerOutcome.Success)
                            result.Outcome = BrokerOutcome.Unsafe;
                    }
                    catch
                    {
                        // No user text or exception details leave this process.
                        result = new BrokerResponse { Outcome = BrokerOutcome.Unknown, Stage = BrokerStage.Exception };
                    }
                    finally { request.Dispose(); }
                    byte[] response;
                    try { response = BrokerWire.EncodeResponse(result); }
                    catch
                    {
                        response = BrokerWire.EncodeResponse(new BrokerResponse
                        { Outcome = BrokerOutcome.Unknown, Stage = BrokerStage.Exception });
                    }
                    try { BrokerWire.WriteFrame(output, response); }
                    catch { return; }
                }
            }
        }

        private static FieldSnapshot? SafeCapture(NativeFocusSnapshot? focus, IntPtr foreground,
            IntPtr hwnd, uint pid, uint tid, IntPtr expectedLayout)
        {
            BrokerStage ignored;
            int ignoredError;
            int ignoredTextLength, ignoredStart, ignoredEnd, ignoredClass;
            return SafeCapture(focus, foreground, hwnd, pid, tid, expectedLayout,
                out ignored, out ignoredError, out ignoredTextLength, out ignoredStart,
                out ignoredEnd, out ignoredClass);
        }

        private static FieldSnapshot? SafeCapture(NativeFocusSnapshot? focus, IntPtr foreground,
            IntPtr hwnd, uint pid, uint tid, IntPtr expectedLayout,
            out BrokerStage stage, out int nativeError, out int diagnosticTextLength,
            out int diagnosticStart, out int diagnosticEnd, out int diagnosticNativeClassKind,
            uint selectionTimeout = 20)
        {
            stage = BrokerStage.None;
            nativeError = 0;
            diagnosticTextLength = diagnosticStart = diagnosticEnd = -1;
            diagnosticNativeClassKind = -1;
            if (focus == null || focus.Foreground != foreground || focus.Focus != hwnd ||
                focus.ProcessId != pid || focus.ThreadId != tid)
            { stage = BrokerStage.Focus; if (focus == null) nativeError = Marshal.GetLastWin32Error(); return null; }
            if (!NativeSafety.IsNormalDesktop()) { stage = BrokerStage.Desktop; return null; }
            if (Win32.GetKeyboardLayout(tid) != expectedLayout) { stage = BrokerStage.Layout; return null; }
            if (!NativeSafety.IsEqualOrLowerIntegrity(pid)) { stage = BrokerStage.Integrity; return null; }
            var element = AutomationElement.FocusedElement;
            if (element == null) { stage = BrokerStage.Element; return null; }
            if (element.Current.IsPassword) { stage = BrokerStage.Password; return null; }
            if (element.Current.ProcessId != pid ||
                (element.Current.NativeWindowHandle != 0 && element.Current.NativeWindowHandle != hwnd.ToInt64()) ||
                (element.Current.ControlType != ControlType.Edit && element.Current.ControlType != ControlType.Document) ||
                !element.Current.IsEnabled)
            { stage = BrokerStage.Identity; return null; }
            var nativeClassBuffer = new StringBuilder(256);
            if (Win32.GetClassName(hwnd, nativeClassBuffer, nativeClassBuffer.Capacity) == 0)
            { stage = BrokerStage.Identity; nativeError = Marshal.GetLastWin32Error(); return null; }
            var nativeClass = nativeClassBuffer.ToString();
            bool nativePlainEdit = nativeClass.Equals("Edit", StringComparison.OrdinalIgnoreCase) ||
                nativeClass.StartsWith("WindowsForms10.EDIT", StringComparison.OrdinalIgnoreCase);
            bool nativeRichEdit = nativeClass.StartsWith("RichEdit", StringComparison.OrdinalIgnoreCase) ||
                nativeClass.StartsWith("WindowsForms10.RichEdit", StringComparison.OrdinalIgnoreCase);
            diagnosticNativeClassKind = nativePlainEdit ? 1 : nativeRichEdit ? 2 : 0;
            bool nativeRange = (nativePlainEdit || nativeRichEdit) &&
                element.Current.NativeWindowHandle == hwnd.ToInt64() && Win32.IsWindowUnicode(hwnd) &&
                Win32.IsWindowEnabled(hwnd);
            if (nativePlainEdit || nativeRichEdit)
            {
                var style = Win32.GetWindowStyle(hwnd, Win32.GWL_STYLE);
                if ((style & Win32.ES_PASSWORD) != 0) { stage = BrokerStage.Password; return null; }
                if ((style & (Win32.ES_READONLY | Win32.WS_DISABLED)) != 0)
                { stage = BrokerStage.ReadOnly; return null; }
            }
            bool rich = nativeRichEdit ||
                element.Current.ControlType == ControlType.Document;
            object pattern;
            ValuePattern? valuePattern = null;
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out pattern))
            {
                valuePattern = (ValuePattern)pattern;
                if (valuePattern.Current.IsReadOnly) { stage = BrokerStage.ReadOnly; return null; }
            }
            object textObject;
            TextPattern? textPattern = null;
            if (element.TryGetCurrentPattern(TextPattern.Pattern, out textObject))
            {
                textPattern = (TextPattern)textObject;
                if (!nativePlainEdit || rich)
                {
                    var readOnly = textPattern.DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute);
                    if (!(readOnly is bool) || (bool)readOnly)
                    { stage = BrokerStage.ReadOnly; return null; }
                }
            }
            if (valuePattern == null && textPattern == null)
            { stage = BrokerStage.Pattern; return null; }
            var providerText = valuePattern != null && !(nativePlainEdit && !rich)
                ? valuePattern.Current.Value : null;
            string? text;
            if (nativePlainEdit && !rich)
            {
                if (!Win32.IsWindowUnicode(hwnd)) { stage = BrokerStage.Identity; return null; }
                string nativeText;
                if (!TryReadNativeEditText(hwnd, selectionTimeout, out nativeText, out nativeError))
                { stage = BrokerStage.Value; return null; }
                text = nativeText;
            }
            else text = providerText ?? textPattern!.DocumentRange.GetText(-1);
            if (text == null || text.Length > 32768 || !BrokerWire.IsWellFormedUtf16(text))
            { stage = BrokerStage.Value; return null; }
            diagnosticTextLength = text.Length;
            int start, end;
            if (nativePlainEdit && !rich)
            {
                if (valuePattern == null) { stage = BrokerStage.Pattern; return null; }
                // EM_GETSEL is a system edit-control message. Field size is capped below 32768.
                IntPtr selection;
                if (Win32.SendMessageTimeout(hwnd, Win32.EM_GETSEL, IntPtr.Zero, IntPtr.Zero,
                    Win32.SMTO_ABORTIFHUNG | Win32.SMTO_ERRORONEXIT,
                    selectionTimeout, out selection) == IntPtr.Zero)
                { stage = BrokerStage.Selection; nativeError = Marshal.GetLastWin32Error(); return null; }
                var bits = unchecked((uint)selection.ToInt64());
                start = (int)(bits & 0xFFFF);
                end = (int)((bits >> 16) & 0xFFFF);
                diagnosticStart = start; diagnosticEnd = end;
                string stableText;
                if (!TryReadNativeEditText(hwnd, selectionTimeout, out stableText, out nativeError) ||
                    stableText != text)
                { stage = BrokerStage.Postcheck; return null; }
            }
            else
            {
                if (textPattern == null) { stage = BrokerStage.Pattern; return null; }
                var document = textPattern.DocumentRange;
                if (document.GetText(-1) != text) { stage = BrokerStage.Value; return null; }
                var ranges = textPattern.GetSelection();
                if (ranges == null || ranges.Length != 1)
                { stage = BrokerStage.SelectionPattern; return null; }
                var selected = ranges[0].GetText(-1);
                var prefix = document.Clone();
                prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, ranges[0], TextPatternRangeEndpoint.Start);
                var preceding = prefix.GetText(-1);
                if (preceding == null || selected == null || !text.StartsWith(preceding + selected, StringComparison.Ordinal))
                { stage = BrokerStage.SelectionPattern; return null; }
                start = preceding.Length;
                end = start + selected.Length;
                diagnosticStart = start; diagnosticEnd = end;
                if (nativeRichEdit)
                {
                    IntPtr nativeSelection;
                    if (Win32.SendMessageTimeout(hwnd, Win32.EM_GETSEL, IntPtr.Zero, IntPtr.Zero,
                        Win32.SMTO_ABORTIFHUNG | Win32.SMTO_ERRORONEXIT,
                        selectionTimeout, out nativeSelection) == IntPtr.Zero)
                    { stage = BrokerStage.Selection; nativeError = Marshal.GetLastWin32Error(); return null; }
                    var bits = unchecked((uint)nativeSelection.ToInt64());
                    if (start != (int)(bits & 0xFFFF) || end != (int)((bits >> 16) & 0xFFFF))
                    { stage = BrokerStage.SelectionRange; return null; }
                }
            }
            if (start > end || end > text.Length ||
                !BrokerWire.IsScalarBoundary(text, start) ||
                !BrokerWire.IsScalarBoundary(text, end))
            { stage = BrokerStage.SelectionRange; return null; }
            var id = element.GetRuntimeId();
            if (id == null || id.Length == 0 || id.Length > 64)
            { stage = BrokerStage.RuntimeId; return null; }
            var latest = AutomationElement.FocusedElement;
            if (latest == null || latest.Current.IsPassword || !latest.Current.IsEnabled ||
                latest.Current.ProcessId != pid || !id.SequenceEqual(latest.GetRuntimeId()) ||
                valuePattern != null && valuePattern.Current.IsReadOnly ||
                !focus.StillSame() || Win32.GetKeyboardLayout(tid) != expectedLayout ||
                !NativeSafety.IsNormalDesktop() || !NativeSafety.IsEqualOrLowerIntegrity(pid))
            { stage = BrokerStage.Postcheck; return null; }
            return new FieldSnapshot { Foreground = foreground, Focus = hwnd, ProcessId = pid, ThreadId = tid,
                RuntimeId = id, Value = text, SelectionStart = start, SelectionEnd = end,
                CanWrite = !rich && valuePattern != null && element.Current.ControlType == ControlType.Edit,
                NativeRangeWriter = nativeRange };
        }

        private static BrokerResponse SafeWrite(NativeFocusSnapshot? focus, IntPtr foreground,
            IntPtr hwnd, uint pid, uint tid, IntPtr expectedLayout, long deadline,
            FieldSnapshot? expected, string? replacement)
        {
            if (focus == null || expected == null || !expected.CanWrite || replacement == null ||
                replacement.Length > 32768 || !BrokerWire.IsWellFormedUtf16(replacement) ||
                !NativeSafety.ModifiersUp() || deadline <= (long)Win32.GetTickCount64())
                return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
            var before = SafeCapture(focus, foreground, hwnd, pid, tid, expectedLayout);
            if (before == null || !before.CanWrite || !before.SameState(expected)) return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
            try
            {
                var element = AutomationElement.FocusedElement;
                if (element == null || element.Current.IsPassword || !element.Current.IsEnabled ||
                    element.Current.ProcessId != pid || !before.RuntimeId.SequenceEqual(element.GetRuntimeId()) ||
                    !focus.StillSame() || Win32.GetKeyboardLayout(tid) != expectedLayout ||
                    !NativeSafety.IsNormalDesktop() || !NativeSafety.IsEqualOrLowerIntegrity(pid))
                    return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
                var value = (ValuePattern)element.GetCurrentPattern(ValuePattern.Pattern);
                if (value.Current.IsReadOnly || deadline <= (long)Win32.GetTickCount64() ||
                    !NativeSafety.ModifiersUp())
                    return new BrokerResponse { Outcome = BrokerOutcome.Unsafe };
                value.SetValue(replacement);
            }
            catch { return new BrokerResponse { Outcome = BrokerOutcome.Unknown }; }
            var after = SafeCapture(NativeFocusSnapshot.Capture(), foreground, hwnd, pid, tid, expectedLayout);
            return after != null && after.Value == replacement
                ? new BrokerResponse { Outcome = BrokerOutcome.Success, Field = after }
                : new BrokerResponse { Outcome = BrokerOutcome.Unknown, Field = after };
        }

        private static BrokerResponse SafeReplaceNativeRange(NativeFocusSnapshot? focus, IntPtr foreground,
            IntPtr hwnd, uint pid, uint tid, IntPtr expectedLayout, long deadline,
            FieldSnapshot? expected, int rangeStart, int rangeEnd, string? replacement)
        {
            if (focus == null || expected == null || !expected.NativeRangeWriter || replacement == null ||
                replacement.IndexOf('\0') >= 0 || replacement.Length > 4096 ||
                rangeStart < 0 || rangeEnd < rangeStart || rangeEnd > expected.Value.Length ||
                !BrokerWire.IsWellFormedUtf16(replacement) ||
                !BrokerWire.IsScalarBoundary(expected.Value, rangeStart) ||
                !BrokerWire.IsScalarBoundary(expected.Value, rangeEnd))
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativePrecondition, BrokerStage.NativeMismatch);
            if (deadline <= (long)Win32.GetTickCount64())
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativePrecondition, BrokerStage.NativeDeadline);
            if (!NativeSafety.ModifiersUp())
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativePrecondition, BrokerStage.NativeModifier);
            var finalText = expected.Value.Substring(0, rangeStart) + replacement +
                expected.Value.Substring(rangeEnd);
            if (finalText.Length > 32768)
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativePrecondition, BrokerStage.NativeMismatch);
            BrokerStage captureStage;
            int captureError, ignoredLength, ignoredStart, ignoredEnd, ignoredClass;
            var before = SafeCapture(focus, foreground, hwnd, pid, tid, expectedLayout,
                out captureStage, out captureError, out ignoredLength, out ignoredStart, out ignoredEnd,
                out ignoredClass);
            if (before == null)
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeFirstCapture,
                    captureStage, captureError);
            if (!before.NativeRangeWriter || !before.SameState(expected))
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeState, BrokerStage.NativeMismatch);
            if (before.SelectionStart != rangeStart || before.SelectionEnd != rangeEnd)
            {
                var selectBudget = (uint)Math.Min(20, Math.Max(0, deadline - (long)Win32.GetTickCount64()));
                if (selectBudget < 1)
                    return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeSetSelection, BrokerStage.NativeDeadline);
                IntPtr ignored;
                if (Win32.SendMessageTimeout(hwnd, Win32.EM_SETSEL, new IntPtr(rangeStart),
                    new IntPtr(rangeEnd), Win32.SMTO_ABORTIFHUNG | Win32.SMTO_ERRORONEXIT,
                    selectBudget, out ignored) == IntPtr.Zero)
                    return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeSetSelection,
                        BrokerStage.NativeMessage, Marshal.GetLastWin32Error());
                var selected = SafeCapture(NativeFocusSnapshot.Capture(), foreground, hwnd, pid, tid,
                    expectedLayout, out captureStage, out captureError, out ignoredLength,
                    out ignoredStart, out ignoredEnd, out ignoredClass);
                if (selected == null)
                    return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeSelectionAck,
                        captureStage, captureError);
                if (!selected.SameIdentity(before) || selected.Value != before.Value ||
                    selected.SelectionStart != rangeStart || selected.SelectionEnd != rangeEnd)
                    return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeSelectionAck,
                        BrokerStage.NativeMismatch);
            }
            if (deadline <= (long)Win32.GetTickCount64())
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeBeforeMutation,
                    BrokerStage.NativeDeadline);
            if (!focus.StillSame())
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeBeforeMutation, BrokerStage.Focus);
            if (Win32.GetKeyboardLayout(tid) != expectedLayout)
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeBeforeMutation, BrokerStage.Layout);
            if (!NativeSafety.ModifiersUp())
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeBeforeMutation,
                    BrokerStage.NativeModifier);
            if (!NativeSafety.IsNormalDesktop())
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeBeforeMutation, BrokerStage.Desktop);
            if (!NativeSafety.IsEqualOrLowerIntegrity(pid))
                return NativeResult(BrokerOutcome.Unsafe, BrokerPhase.NativeBeforeMutation, BrokerStage.Integrity);
            IntPtr replaceResult;
            var writeBudget = (uint)Math.Max(1, deadline - (long)Win32.GetTickCount64());
            if (Win32.SendMessageTimeoutText(hwnd, Win32.EM_REPLACESEL, new IntPtr(1), replacement,
                Win32.SMTO_ABORTIFHUNG | Win32.SMTO_ERRORONEXIT, writeBudget,
                out replaceResult) == IntPtr.Zero)
                return NativeResult(BrokerOutcome.Unknown, BrokerPhase.NativeReplaceDelivery,
                    BrokerStage.NativeMessage, Marshal.GetLastWin32Error());
            var after = SafeCapture(NativeFocusSnapshot.Capture(), foreground, hwnd, pid, tid,
                expectedLayout, out captureStage, out captureError, out ignoredLength,
                out ignoredStart, out ignoredEnd, out ignoredClass);
            if (after == null)
                return NativeResult(BrokerOutcome.Unknown, BrokerPhase.NativeReadback,
                    captureStage, captureError);
            if (!after.SameIdentity(before) || after.Value != finalText ||
                after.SelectionStart != after.SelectionEnd ||
                after.SelectionEnd != rangeStart + replacement.Length)
                return NativeResult(BrokerOutcome.Unknown, BrokerPhase.NativeFinalAck,
                    BrokerStage.NativeMismatch, 0, after);
            return NativeResult(BrokerOutcome.Success, BrokerPhase.NativeFinalAck,
                BrokerStage.None, 0, after);
        }

        private static BrokerResponse NativeResult(BrokerOutcome outcome, BrokerPhase phase,
            BrokerStage stage, int nativeError = 0, FieldSnapshot? field = null)
        {
            return new BrokerResponse { Outcome = outcome, Phase = phase,
                Stage = stage, NativeError = nativeError, Field = field };
        }
    }
}
