using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using MacSwitcher.Core;
using MacSwitcher.Windows.Automation;
using MacSwitcher.Windows.Native;

namespace MacSwitcher.Windows.Runtime
{
    public sealed class RuntimeStatus
    {
        public string Message { get; private set; }
        public bool Ready { get; private set; }
        public bool NeedsAdministrator { get; private set; }
        public RuntimeStatus(string message, bool ready, bool needsAdministrator = false)
        { Message = message; Ready = ready; NeedsAdministrator = needsAdministrator; }
    }

    public sealed class CorrectionNotice
    {
        public string Original { get; private set; }
        public string Replacement { get; private set; }
        public string SourceLanguage { get; private set; }
        public CorrectionNotice(string original, string replacement, string sourceLanguage)
        { Original = original; Replacement = replacement; SourceLanguage = sourceLanguage; }
    }

    internal sealed class CorrectionReceipt
    {
        internal FieldSnapshot Field = null!;
        internal string Original = "", Replacement = "", SourceLanguage = "", ResultLanguage = "";
        internal string OriginalPhrase = "", ReplacementPhrase = "";
        internal bool NativeRange;
        internal int RangeStart;
        internal bool Undone;
    }

    internal sealed class PredictionContext
    {
        internal string Suffix = "";
        internal string[] PrecedingWords = Array.Empty<string>();
    }

    public sealed class WindowsSwitcherRuntime : IDisposable
    {
        private readonly object stateGate = new object();
        private readonly object editGate = new object();
        private readonly IPersonalLexicon personal;
        private readonly PhysicalHookHost hook = new PhysicalHookHost();
        private readonly AutomationBrokerClient broker = new AutomationBrokerClient();
        private readonly RecoveryOriginals recovery = new RecoveryOriginals();
        private readonly PredictionLexicon? lexicon;
        private readonly PredictionEngine? prediction;
        private ShiftGesture gesture;
        private AppSettings settings;
        private System.Threading.Timer? cacheTimer;
        private FieldSnapshot? cachedField, sessionField, gestureField;
        private NativeFocusSnapshot? lastExternalFocus;
        private long lastExternalAtTicks;
        private long cachedAtTicks, cachedAtRevision, sessionRevision;
        private long operationGeneration;
        private string? lastSource;
        private string? pendingSource;
        private IntPtr reportedUnsupportedLayout;
        private bool unknownWord = true;
        private int pendingTextKeys;
        private bool leftShiftDown, rightShiftDown, started, disposed;
        private uint reportedHigherPid;
        private int refreshing;
        private bool observing;
        private PhysicalInput? latestObservation;
        private int manualWorkInFlight;
        private int fixtureManualCode;
        private int fixtureShiftCode;
        private int fixtureResetReason;
        private int fixtureNativeCode;
        private int fixtureNativeBrokerOutcome = -1;
        private int fixtureNativeBrokerStage = -1;
        private int fixtureNativeBrokerPhase = -1;
        private int fixtureNativeBudgetMilliseconds = -1;
        private int fixtureNativeRpcMilliseconds = -1;
        private CorrectionReceipt? receipt;

        public event Action<RuntimeStatus>? StatusChanged;
        public event Action<CorrectionNotice>? CorrectionApplied;
        public event Action<CorrectionNotice>? CorrectionUndone;

        public WindowsSwitcherRuntime(AppSettings settings, IPersonalLexicon personal, string dataDirectory)
        {
            this.settings = settings ?? throw new ArgumentNullException(nameof(settings));
            this.settings.Validate();
            this.personal = personal ?? throw new ArgumentNullException(nameof(personal));
            gesture = new ShiftGesture(settings.DoubleShiftMilliseconds);
            try
            {
                lexicon = PredictionLexicon.Load(dataDirectory, personal);
                prediction = new PredictionEngine(lexicon);
            }
            catch { /* Gesture and explicit selection conversion remain available only with validated data. */ }
            hook.PhysicalEvent += OnPhysicalEvent;
        }

        public bool HasRecoveryOriginals { get { return recovery.Count > 0; } }
        internal bool FixtureHookReady { get { return hook.Ready; } }
        internal int FixtureManualCode { get { return Volatile.Read(ref fixtureManualCode); } }
        internal int FixtureShiftCode { get { return Volatile.Read(ref fixtureShiftCode); } }
        internal int FixtureResetReason { get { return Volatile.Read(ref fixtureResetReason); } }
        internal int FixtureNativeCode { get { return Volatile.Read(ref fixtureNativeCode); } }
        internal int FixtureNativeBrokerOutcome { get { return Volatile.Read(ref fixtureNativeBrokerOutcome); } }
        internal int FixtureNativeBrokerStage { get { return Volatile.Read(ref fixtureNativeBrokerStage); } }
        internal int FixtureNativeBrokerPhase { get { return Volatile.Read(ref fixtureNativeBrokerPhase); } }
        internal int FixtureNativeBudgetMilliseconds { get { return Volatile.Read(ref fixtureNativeBudgetMilliseconds); } }
        internal int FixtureNativeRpcMilliseconds { get { return Volatile.Read(ref fixtureNativeRpcMilliseconds); } }
        internal bool FixtureWorkSettled
        {
            get
            {
                if (Volatile.Read(ref manualWorkInFlight) != 0) return false;
                lock (stateGate) return !observing && latestObservation == null;
            }
        }
        internal bool FixtureCacheReadyFor(NativeFocusSnapshot? focus, long notBeforeTick)
        {
            if (focus == null || !focus.StillSame()) return false;
            lock (stateGate)
                return cachedField != null &&
                    cachedAtTicks >= notBeforeTick &&
                    cachedAtRevision == hook.Revision && MatchesFocus(cachedField, focus);
        }
        internal void EmitFixtureKey(PhysicalInputKind kind, int virtualKey, uint scanCode, long timestamp)
        { hook.EmitFixtureKey(kind, virtualKey, scanCode, timestamp); }
        public string CurrentLayoutLanguage
        {
            get
            {
                var current = NativeFocusSnapshot.Capture();
                if (current != null) return KeyboardLayoutSource.Language(current.Layout) ?? "";
                NativeFocusSnapshot? previous;
                lock (stateGate) previous = lastExternalFocus;
                return previous != null && KeyboardLayoutSource.PreviousTargetStillValid(previous)
                    ? KeyboardLayoutSource.Language(Win32.GetKeyboardLayout(previous.ThreadId)) ?? "" : "";
            }
        }

        public void Start()
        {
            lock (stateGate)
            {
                if (disposed) throw new ObjectDisposedException(nameof(WindowsSwitcherRuntime));
                if (started) return;
                started = true;
                operationGeneration++;
            }
            try
            {
                hook.Start();
                cacheTimer = new System.Threading.Timer(_ => RefreshCache(), null, 0, 80);
                bool standardLayoutsAvailable = KeyboardLayoutSource.FindInstalled("ru") != IntPtr.Zero &&
                    KeyboardLayoutSource.FindInstalled("en") != IntPtr.Zero;
                if (!standardLayoutsAvailable)
                    Publish("Добавьте русскую и английскую (США) раскладки в Windows. Пункт «Параметры языка» есть в меню MacSwitcher.", false);
                else Publish(prediction == null
                    ? "Раскладки доступны; словари исправлений недоступны."
                    : "MacSwitcher работает.", prediction != null);
            }
            catch
            {
                lock (stateGate) started = false;
                Publish("Мониторинг клавиатуры недоступен.", false);
            }
        }

        public void Stop()
        {
            lock (editGate)
                lock (stateGate) { started = false; operationGeneration++; }
            cacheTimer?.Dispose(); cacheTimer = null;
            hook.Dispose();
            Publish("MacSwitcher остановлен.", false);
        }

        public void ApplySettings(AppSettings next)
        {
            if (next == null) throw new ArgumentNullException(nameof(next));
            next.Validate();
            lock (editGate)
                lock (stateGate)
                {
                    settings = next;
                    operationGeneration++;
                    gesture = new ShiftGesture(next.DoubleShiftMilliseconds);
                    sessionField = gestureField = null;
                    unknownWord = true;
                }
            Publish(next.Enabled ? "MacSwitcher работает." : "MacSwitcher приостановлен.", next.Enabled);
        }

        public bool TrySwitchLayout(string language)
        {
            if (language != "ru" && language != "en") return false;
            var focus = NativeFocusSnapshot.Capture();
            NativeFocusSnapshot? previous;
            long age;
            lock (stateGate) { previous = lastExternalFocus; age = (long)Win32.GetTickCount64() - lastExternalAtTicks; }
            var ok = focus != null ? KeyboardLayoutSource.RequestAndConfirm(focus, language)
                : age >= 0 && age <= 60000 && KeyboardLayoutSource.RequestAndConfirmPrevious(previous, language);
            Publish(ok ? "Раскладка изменена." : "Не удалось подтвердить смену раскладки в текущем окне.", ok);
            return ok;
        }

        public bool UndoLastCorrection()
        {
            CorrectionReceipt? prior;
            long generation;
            lock (stateGate) { prior = receipt; generation = operationGeneration; }
            if (prior == null || prior.Undone) return false;
            return ToggleReceipt(prior, true, generation);
        }

        public string ExportRecovery(string directory) { return recovery.Export(directory); }

        public IReadOnlyList<RecoveryOriginalInfo> GetRecoveryOriginalsSnapshot()
        { return recovery.Snapshot(); }

        public bool TryRestoreRecovery(string id)
        {
            if (string.IsNullOrEmpty(id)) return false;
            var entry = recovery.Snapshot().FirstOrDefault(x => x.Id == id);
            if (entry == null) return false;
            var focus = NativeFocusSnapshot.Capture();
            var revision = hook.Revision;
            long generation;
            lock (stateGate) generation = operationGeneration;
            if (!CanMutate(generation, revision)) return false;
            var observed = ReadField(focus, 150);
            if (observed.Outcome != BrokerOutcome.Success || observed.Field == null ||
                !entry.Matches(observed.Field) || !CanMutate(generation, revision)) return false;
            return TryRestoreRecoveryCurrent(entry, focus, observed.Field, revision, generation);
        }

        private bool TryRestoreRecoveryCurrent(RecoveryOriginalInfo entry, NativeFocusSnapshot? focus,
            FieldSnapshot field, long revision, long generation)
        {
            if (!entry.Matches(field) || field.Value.Length == 0 || field.SelectionStart != 0 ||
                field.SelectionEnd != field.Value.Length || !CanMutate(generation, revision))
            {
                Publish("Для восстановления выделите весь текст исходного поля и повторите действие.", false);
                return false;
            }
            if (!entry.MatchesLastObserved(field))
            {
                Publish("Текущее содержимое отличается от последнего подтверждённого наблюдения либо оно неизвестно. Скопируйте или экспортируйте исходник для ручного восстановления.", false);
                return false;
            }
            var source = entry.SourceLanguage == "ru" || entry.SourceLanguage == "en"
                ? entry.SourceLanguage : KeyboardLayoutSource.Language(focus?.Layout ?? IntPtr.Zero) ?? "";
            if (source != "ru" && source != "en") return false;
            bool restored;
            if (field.Value == entry.Original)
                restored = true;
            else if (field.NativeRangeWriter)
                restored = TryNativeRangeEdit(focus, field, 0, field.Value.Length, entry.Original,
                    revision, generation, field.Value, source, source, false, true);
            else if (field.CanWrite)
                restored = TryFullValueEdit(focus, field, entry.Original, revision, generation,
                    field.Value, entry.Original, source, source, false, true);
            else restored = false;
            if (!restored || !CanMutate(generation, revision)) return false;
            var check = ReadField(NativeFocusSnapshot.Capture(), 100);
            if (check.Outcome != BrokerOutcome.Success || check.Field == null ||
                !entry.Matches(check.Field) || check.Field.Value != entry.Original ||
                KeyboardLayoutSource.Language(Win32.GetKeyboardLayout(field.ThreadId)) != source)
            {
                Publish("Текст восстановлен, но итоговое состояние не подтверждено; исходник сохранён.", false);
                return false;
            }
            recovery.RemoveConfirmed(entry.Id);
            lock (stateGate) receipt = null;
            Publish("Исходный текст восстановлен и подтверждён.", true);
            return true;
        }

        private void Publish(string message, bool ready, bool needsAdministrator = false)
        {
            try { StatusChanged?.Invoke(new RuntimeStatus(message, ready, needsAdministrator)); } catch { }
        }

        private static bool IsShift(int vk) { return vk == Win32.VK_LSHIFT || vk == Win32.VK_RSHIFT || vk == Win32.VK_SHIFT; }
        private static ShiftSide Side(PhysicalInput input) { return input.VirtualKey == Win32.VK_RSHIFT || input.ScanCode == 54 ? ShiftSide.Right : ShiftSide.Left; }
        private static bool IsTextKey(int vk) { return vk >= 0x30 && vk <= 0x39 ||
            vk >= 0x41 && vk <= 0x5A || vk >= 0xBA && vk <= 0xDF || vk == 0x20; }

        private void OnPhysicalEvent(PhysicalInput input)
        {
            ShiftAction? action = null;
            FieldSnapshot? origin = null;
            long eventGeneration;
            AppSettings current;
            bool shiftEvent = IsShift(input.VirtualKey);
            if (shiftEvent) Interlocked.Exchange(ref fixtureShiftCode, 1);
            lock (stateGate)
            {
                if (!started) { if (shiftEvent) Interlocked.Exchange(ref fixtureShiftCode, 2); return; }
                current = settings;
                if (!current.Enabled) { if (shiftEvent) Interlocked.Exchange(ref fixtureShiftCode, 2); return; }
                if (input.Focus != null)
                {
                    lastExternalFocus = input.Focus;
                    lastExternalAtTicks = (long)Win32.GetTickCount64();
                }
                if (pendingSource != null)
                {
                    if (input.Focus != null && KeyboardLayoutSource.Language(input.Focus.Layout) == pendingSource)
                        pendingSource = null;
                    else
                    {
                        if (shiftEvent) Interlocked.Exchange(ref fixtureShiftCode, 11);
                        ResetSession(5); return;
                    }
                }
                if (input.Kind == PhysicalInputKind.Overflow || input.Kind == PhysicalInputKind.Mouse || input.Focus == null)
                { if (shiftEvent) Interlocked.Exchange(ref fixtureShiftCode, 3); ResetSession(4); return; }
                if (IsExcluded(input.Focus.ProcessId, current))
                { if (shiftEvent) Interlocked.Exchange(ref fixtureShiftCode, 4); ResetSession(6); return; }
                bool higher;
                if (NativeSafety.TryTargetHigherIntegrity(input.Focus.ProcessId, out higher) && higher)
                {
                    if (shiftEvent) Interlocked.Exchange(ref fixtureShiftCode, 5);
                    ResetSession(7);
                    if (reportedHigherPid != input.Focus.ProcessId)
                    {
                        reportedHigherPid = input.Focus.ProcessId;
                        Publish("Текущее окно запущено от администратора. Для работы с ним явно перезапустите MacSwitcher от администратора.", false, true);
                    }
                    return;
                }
                reportedHigherPid = 0;
                if (cachedField != null && !MatchesFocus(cachedField, input.Focus)) ResetSession(8);
                if (IsShift(input.VirtualKey))
                {
                    var side = Side(input);
                    if (input.Kind == PhysicalInputKind.KeyDown)
                    {
                        if (!NativeSafety.CommandModifiersUp())
                        { Interlocked.Exchange(ref fixtureShiftCode, 7); gesture.Interrupt(); return; }
                        if (side == ShiftSide.Left ? leftShiftDown : rightShiftDown)
                        { Interlocked.Exchange(ref fixtureShiftCode, 8); gesture.Interrupt(); return; }
                        if (leftShiftDown || rightShiftDown)
                        { Interlocked.Exchange(ref fixtureShiftCode, 8); gesture.Interrupt(); leftShiftDown = rightShiftDown = true; return; }
                        if (side == ShiftSide.Left) leftShiftDown = true; else rightShiftDown = true;
                        var source = KeyboardLayoutSource.Language(input.Focus.Layout);
                        if (source == null)
                        {
                            Interlocked.Exchange(ref fixtureShiftCode, 6);
                            gesture.Interrupt();
                            if (reportedUnsupportedLayout != input.Focus.Layout)
                            {
                                reportedUnsupportedLayout = input.Focus.Layout;
                                Publish("Текущая раскладка не поддерживается. Выберите русскую или English (US); настройки — «Параметры языка» в меню.", false);
                            }
                            return;
                        }
                        reportedUnsupportedLayout = IntPtr.Zero;
                        if (gestureField == null) gestureField = CachedFor(input.Focus, input.Revision);
                        gesture.Press(side, input.Timestamp, new LayoutDirection(source, source == "ru" ? "en" : "ru"));
                        Interlocked.Exchange(ref fixtureShiftCode, 9);
                    }
                    else if (input.Kind == PhysicalInputKind.KeyUp)
                    {
                        if (!NativeSafety.CommandModifiersUp()) gesture.Interrupt();
                        if (side == ShiftSide.Left) leftShiftDown = false; else rightShiftDown = false;
                        action = gesture.Release(side, input.Timestamp);
                        if (action == null) Interlocked.Exchange(ref fixtureShiftCode, 10);
                        origin = gestureField;
                        if (action?.Kind == ShiftActionKind.Convert) gestureField = null;
                    }
                }
                else
                {
                    gesture.Interrupt(); gestureField = null;
                    if (!IsTextKey(input.VirtualKey) || leftShiftDown || rightShiftDown ||
                        !NativeSafety.CommandModifiersUp())
                    { ResetSession(9); return; }
                    if (input.Kind == PhysicalInputKind.KeyDown)
                    {
                        if (sessionField == null && !unknownWord)
                            sessionField = CachedFor(input.Focus, input.Revision);
                        if (sessionField == null) unknownWord = true;
                        var observedSource = KeyboardLayoutSource.Language(input.Focus.Layout);
                        if (lastSource != null && observedSource != lastSource && sessionField != null &&
                            sessionField.Value.Length > 0 && !char.IsWhiteSpace(sessionField.Value[sessionField.Value.Length - 1]))
                        { sessionField = null; unknownWord = true; }
                        lastSource = observedSource;
                        sessionRevision = input.Revision;
                        pendingTextKeys = Math.Min(192, pendingTextKeys + 1);
                    }
                }
                eventGeneration = operationGeneration;
            }
            if (action != null)
            {
                var saved = action;
                var revision = input.Revision;
                var focus = input.Focus;
                if (saved.Kind == ShiftActionKind.SwitchLayout)
                {
                    bool switched = KeyboardLayoutSource.RequestAndConfirm(focus, saved.Direction.TargetId);
                    Interlocked.Exchange(ref fixtureShiftCode, switched ? 20 : 21);
                    lock (stateGate)
                    {
                        sessionField = null;
                        pendingTextKeys = 0;
                        lastSource = null;
                        var value = cachedField?.Value;
                        unknownWord = value == null || value.Length > 0 && !char.IsWhiteSpace(value[value.Length - 1]);
                    }
                    if (!switched) Publish("Смена раскладки не подтверждена.", false);
                }
                else if (saved.Kind == ShiftActionKind.Convert)
                {
                    Interlocked.Exchange(ref fixtureShiftCode, 30);
                    Interlocked.Exchange(ref fixtureManualCode, 0);
                    Interlocked.Increment(ref manualWorkInFlight);
                    try
                    {
                        Task.Run(() =>
                        {
                            try { ConvertManual(focus, origin, saved.Direction.SourceId,
                                saved.Direction.TargetId, revision, eventGeneration); }
                            catch { Interlocked.Exchange(ref fixtureManualCode, 99); }
                            finally { Interlocked.Decrement(ref manualWorkInFlight); }
                        });
                    }
                    catch { Interlocked.Decrement(ref manualWorkInFlight); throw; }
                }
            }
            else if (input.Kind == PhysicalInputKind.KeyUp && IsTextKey(input.VirtualKey)) QueueObservation(input);
        }

        private static bool MatchesFocus(FieldSnapshot? field, NativeFocusSnapshot? focus)
        {
            return field != null && focus != null && field.Foreground == focus.Foreground && field.Focus == focus.Focus &&
                field.ProcessId == focus.ProcessId && field.ThreadId == focus.ThreadId;
        }

        private FieldSnapshot? CachedFor(NativeFocusSnapshot? focus, long eventRevision = long.MaxValue)
        {
            return MatchesFocus(cachedField, focus) && cachedAtRevision < eventRevision &&
                (long)Win32.GetTickCount64() - cachedAtTicks <= 250
                ? cachedField : null;
        }

        private void ResetSession(int reason = 1)
        {
            Interlocked.Exchange(ref fixtureResetReason, reason);
            operationGeneration++;
            gesture.Interrupt();
            cachedField = sessionField = gestureField = null;
            unknownWord = true;
            lastSource = null;
            pendingTextKeys = 0;
            leftShiftDown = rightShiftDown = false;
        }

        private static bool IsExcluded(uint pid, AppSettings value)
        {
            try
            {
                var name = Process.GetProcessById((int)pid).ProcessName;
                return value.ExcludedApplications.Any(x => string.Equals(Path.GetFileNameWithoutExtension(x), name, StringComparison.OrdinalIgnoreCase));
            }
            catch { return true; }
        }

        private bool CanMutate(long generation, long revision)
        {
            lock (stateGate)
                return PermitMutation(started, settings.Enabled, disposed, operationGeneration,
                    generation, hook.Revision, revision);
        }

        internal static bool PermitMutation(bool started, bool enabled, bool disposed,
            long currentGeneration, long expectedGeneration, long currentRevision, long expectedRevision)
        {
            return started && enabled && !disposed && currentGeneration == expectedGeneration &&
                currentRevision == expectedRevision;
        }

        private BrokerResponse ReadField(NativeFocusSnapshot? focus, int timeoutMilliseconds)
        {
            lock (editGate) return broker.Capture(focus, timeoutMilliseconds);
        }

        private void RefreshCache()
        {
            if (Interlocked.Exchange(ref refreshing, 1) != 0) return;
            try
            {
                var focus = NativeFocusSnapshot.Capture();
                if (focus == null)
                {
                    var foreground = Win32.GetForegroundWindow();
                    lock (stateGate)
                    {
                        if (foreground != IntPtr.Zero && lastExternalFocus?.Foreground == foreground)
                        {
                            // GetGUIThreadInfo can briefly have no focused HWND while a native
                            // input-language transition is being delivered. Preserve the pending
                            // Shift gesture, but invalidate automatic text work and its generation.
                            Interlocked.Exchange(ref fixtureResetReason, 2);
                            operationGeneration++;
                            sessionField = null;
                            unknownWord = true;
                            lastSource = null;
                            pendingTextKeys = 0;
                        }
                        else ResetSession(10);
                    }
                    return;
                }
                lock (stateGate)
                {
                    lastExternalFocus = focus;
                    lastExternalAtTicks = (long)Win32.GetTickCount64();
                }
                AppSettings current;
                lock (stateGate) current = settings;
                if (!current.Enabled || IsExcluded(focus.ProcessId, current)) return;
                var beforeRevision = hook.Revision;
                var response = ReadField(focus, 300);
                lock (stateGate)
                {
                    if (!started || !focus.StillSame() || hook.Revision != beforeRevision) return;
                    if (response.Outcome == BrokerOutcome.Success && response.Field != null)
                    {
                        if (cachedField != null && !cachedField.SameIdentity(response.Field)) ResetSession(11);
                        cachedField = response.Field;
                        cachedAtTicks = (long)Win32.GetTickCount64();
                        cachedAtRevision = beforeRevision;
                        if (sessionField == null && (response.Field.Value.Length == 0 ||
                            char.IsWhiteSpace(response.Field.Value[response.Field.Value.Length - 1])))
                            unknownWord = false;
                    }
                    else { cachedField = null; unknownWord = true; }
                }
            }
            catch { lock (stateGate) { cachedField = null; unknownWord = true; } }
            finally { Interlocked.Exchange(ref refreshing, 0); }
        }

        private void QueueObservation(PhysicalInput input)
        {
            lock (stateGate)
            {
                latestObservation = input;
                if (observing) return;
                observing = true;
            }
            Task.Run(() =>
            {
                while (true)
                {
                    PhysicalInput? next;
                    lock (stateGate)
                    {
                        next = latestObservation;
                        latestObservation = null;
                        if (next == null) { observing = false; return; }
                    }
                    try { ObserveText(next); } catch { }
                }
            });
        }

        private void ObserveText(PhysicalInput input)
        {
            Thread.Sleep(12); // The hook precedes target dispatch.
            FieldSnapshot? origin;
            string? source;
            AppSettings current;
            int pendingKeys;
            long generation;
            lock (stateGate)
            {
                origin = sessionField; source = lastSource; current = settings;
                pendingKeys = pendingTextKeys; generation = operationGeneration;
            }
            if (origin == null)
            {
                if (input.VirtualKey == 0x20 && hook.Revision == input.Revision)
                {
                    var boundaryRead = ReadField(input.Focus, 80);
                    if (boundaryRead.Outcome == BrokerOutcome.Success && boundaryRead.Field != null &&
                        boundaryRead.Field.Value.Length > 0 &&
                        char.IsWhiteSpace(boundaryRead.Field.Value[boundaryRead.Field.Value.Length - 1]))
                        lock (stateGate) { unknownWord = false; sessionField = boundaryRead.Field; }
                }
                return;
            }
            if (source == null || !current.AutomaticCorrection || prediction == null ||
                !CanMutate(generation, input.Revision) ||
                !MatchesFocus(origin, input.Focus)) return;
            BrokerResponse? response = null;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                if (hook.Revision != input.Revision) return;
                response = ReadField(input.Focus, 80);
                if (response.Outcome == BrokerOutcome.Success && response.Field != null &&
                    response.Field.SameIdentity(origin) && response.Field.Value != origin.Value) break;
                Thread.Sleep(15);
            }
            var field = response?.Field;
            if (field == null || !field.SameIdentity(origin) || field.SelectionStart != field.SelectionEnd ||
                field.SelectionEnd != field.Value.Length || hook.Revision != input.Revision) return;
            if (origin.SelectionStart != origin.SelectionEnd || origin.SelectionEnd != origin.Value.Length ||
                !field.Value.StartsWith(origin.Value, StringComparison.Ordinal) ||
                field.Value.Length - origin.Value.Length > Math.Max(2, 2 * pendingKeys))
            {
                lock (stateGate) { sessionField = null; unknownWord = true; }
                return;
            }
            bool boundary = field.Value.Length > 0 && char.IsWhiteSpace(field.Value[field.Value.Length - 1]);
            var context = BuildPredictionContext(field.Value);
            if (context == null)
            {
                if (boundary) lock (stateGate) { unknownWord = false; sessionField = field; pendingTextKeys = 0; }
                return;
            }
            PredictionProposal? proposal;
            try { proposal = prediction.Evaluate(context.Suffix, source, boundary,
                context.PrecedingWords, current.RussianPriority, current.AlwaysConvertWords); }
            catch { return; }
            if (proposal != null && proposal.OriginalSuffix == context.Suffix &&
                field.Value.EndsWith(context.Suffix, StringComparison.Ordinal))
            {
                var replacement = field.Value.Substring(0, field.Value.Length - context.Suffix.Length) + proposal.ReplacementSuffix;
                if (field.NativeRangeWriter)
                    TryNativeRangeEdit(input.Focus, field, field.Value.Length - context.Suffix.Length,
                        field.Value.Length, proposal.ReplacementSuffix, input.Revision, generation,
                        context.Suffix, source, proposal.TargetLanguage);
                else TryFullValueEdit(input.Focus, field, replacement, input.Revision, generation,
                    context.Suffix, proposal.ReplacementSuffix, source, proposal.TargetLanguage);
            }
            else lock (stateGate) { sessionField = field; unknownWord = false; pendingTextKeys = 0; }
        }

        private static string? LastToken(string value)
        {
            if (value.Length == 0) return null;
            int end = value.Length;
            while (end > 0 && char.IsWhiteSpace(value[end - 1])) end--;
            int start = end;
            while (start > 0 && !char.IsWhiteSpace(value[start - 1])) start--;
            if (start == end || end - start > 192 || value.Length - end > 1) return null;
            return value.Substring(start);
        }

        internal static PredictionContext? BuildPredictionContext(string value)
        {
            if (string.IsNullOrEmpty(value)) return null;
            int end = value.Length;
            if (char.IsWhiteSpace(value[end - 1]))
            {
                if (value[end - 1] != ' ' || end > 1 && char.IsWhiteSpace(value[end - 2])) return null;
                end--;
            }
            int start = end, words = 0;
            while (start > 0 && words < 2)
            {
                int wordEnd = start;
                while (start > 0 && !char.IsWhiteSpace(value[start - 1])) start--;
                if (wordEnd == start || wordEnd - start > 192) return null;
                words++;
                if (words == 2 || start == 0) break;
                int separatorEnd = start;
                while (start > 0 && char.IsWhiteSpace(value[start - 1])) start--;
                if (separatorEnd - start != 1 || value[start] != ' ') return null;
                if (start == 0) break;
            }
            if (words == 0 || value.Length - start > 384) return null;
            var prior = new List<string>(4);
            int cursor = start;
            while (cursor > 0 && prior.Count < 4)
            {
                while (cursor > 0 && value[cursor - 1] == ' ') cursor--;
                int previousEnd = cursor;
                while (cursor > 0 && !char.IsWhiteSpace(value[cursor - 1])) cursor--;
                if (previousEnd == cursor || previousEnd - cursor > 96) break;
                prior.Insert(0, value.Substring(cursor, previousEnd - cursor));
                if (cursor > 0 && value[cursor - 1] != ' ') break;
            }
            return new PredictionContext { Suffix = value.Substring(start), PrecedingWords = prior.ToArray() };
        }

        private void ConvertManual(NativeFocusSnapshot? focus, FieldSnapshot? origin, string source,
            string target, long revision, long generation)
        {
            Interlocked.Exchange(ref fixtureManualCode, 1);
            if (!CanMutate(generation, revision)) { Interlocked.Exchange(ref fixtureManualCode, 2); return; }
            if (origin == null || focus == null)
            {
                Interlocked.Exchange(ref fixtureManualCode, 3);
                Publish("Не удалось заранее подтвердить поле для исправления. Повторите двойное нажатие Shift после выбора текстового поля.", false);
                return;
            }
            if (KeyboardLayoutSource.Language(Win32.GetKeyboardLayout(focus.ThreadId)) != target)
            {
                Interlocked.Exchange(ref fixtureManualCode, 4);
                Publish("Смена раскладки не подтверждена; текст не изменён.", false);
                return;
            }
            var read = ReadField(focus, 100);
            var field = read.Field;
            if (!CanMutate(generation, revision)) { Interlocked.Exchange(ref fixtureManualCode, 2); return; }
            if (read.Outcome != BrokerOutcome.Success || field == null)
            {
                Interlocked.Exchange(ref fixtureManualCode, 5);
                Publish("Это текстовое поле не удалось безопасно проверить. Текст не изменён.", false);
                return;
            }
            if (!field.SameState(origin) || !CanMutate(generation, revision))
            {
                Interlocked.Exchange(ref fixtureManualCode, 6);
                Publish("Поле или выделение изменилось после первого Shift. Текст не изменён; повторите действие.", false);
                return;
            }
            CorrectionReceipt? prior;
            lock (stateGate) prior = receipt;
            if (prior != null && field.SameIdentity(prior.Field) &&
                field.Value == (prior.Undone ? prior.Original : prior.Replacement) &&
                field.SelectionStart == field.SelectionEnd &&
                field.SelectionEnd == (prior.NativeRange
                    ? prior.RangeStart + (prior.Undone ? prior.OriginalPhrase.Length : prior.ReplacementPhrase.Length)
                    : field.Value.Length))
            {
                Interlocked.Exchange(ref fixtureManualCode,
                    ToggleReceipt(prior, !prior.Undone, generation) ? 30 : 31);
                return;
            }
            var pendingOriginal = recovery.FindForField(field);
            if (pendingOriginal != null)
            {
                Interlocked.Exchange(ref fixtureManualCode,
                    TryRestoreRecoveryCurrent(pendingOriginal, focus, field, revision, generation) ? 40 : 41);
                return;
            }
            if (field.SelectionEnd > field.SelectionStart)
            {
                if (lexicon == null && settings.SmartSelection)
                { Interlocked.Exchange(ref fixtureManualCode, 7); return; }
                var selected = field.Value.Substring(field.SelectionStart, field.SelectionEnd - field.SelectionStart);
                if (selected.Length > 4096)
                { Interlocked.Exchange(ref fixtureManualCode, 7); return; }
                var converted = settings.SmartSelection
                    ? SelectionConverter.Convert(selected, lexicon!, true, source, settings.RussianPriority)
                    : LayoutMap.ConvertBidirectional(selected);
                if (converted == selected || converted.Length > 4096)
                { Interlocked.Exchange(ref fixtureManualCode, 7); return; }
                var resultLanguage = ResultLanguage(selected, converted, target);
                if (field.NativeRangeWriter)
                    Interlocked.Exchange(ref fixtureManualCode,
                        TryNativeRangeEdit(focus, field, field.SelectionStart, field.SelectionEnd, converted,
                            revision, generation, selected, source, resultLanguage) ? 20 : 21);
                else if (field.CanWrite && field.SelectionEnd == field.Value.Length)
                {
                    var whole = field.Value.Substring(0, field.SelectionStart) + converted;
                    Interlocked.Exchange(ref fixtureManualCode,
                        TryFullValueEdit(focus, field, whole, revision, generation, selected, converted, source,
                            resultLanguage) ? 22 : 23);
                }
                else
                {
                    Interlocked.Exchange(ref fixtureManualCode, 7);
                    Publish("Это выделение нельзя изменить с проверкой результата в данном редакторе.", false);
                }
                return;
            }
            if (field.SelectionEnd != field.Value.Length)
            { Interlocked.Exchange(ref fixtureManualCode, 7); return; }
            var token = LastToken(field.Value);
            if (token == null) { Interlocked.Exchange(ref fixtureManualCode, 7); return; }
            var wordSource = ActualWordLanguage(token, source);
            var replacement = LayoutMap.ConvertBidirectional(token);
            if (replacement == token) { Interlocked.Exchange(ref fixtureManualCode, 7); return; }
            var targetValue = field.Value.Substring(0, field.Value.Length - token.Length) + replacement;
            var wordLanguage = ResultLanguage(token, replacement, target);
            if (field.NativeRangeWriter)
                Interlocked.Exchange(ref fixtureManualCode,
                    TryNativeRangeEdit(focus, field, field.Value.Length - token.Length, field.Value.Length,
                    replacement, revision, generation, token, wordSource, wordLanguage) ? 20 : 21);
            else Interlocked.Exchange(ref fixtureManualCode,
                TryFullValueEdit(focus, field, targetValue, revision, generation, token, replacement,
                    wordSource, wordLanguage) ? 22 : 23);
        }

        internal static string ActualWordLanguage(string token, string fallback)
        {
            bool latin = token.Any(c => c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z');
            bool cyrillic = token.Any(c => c >= '\u0400' && c <= '\u04ff');
            return latin && !cyrillic ? "en" : cyrillic && !latin ? "ru" : fallback;
        }

        internal static string ResultLanguage(string original, string changed, string fallback)
        {
            int ru = 0, en = 0;
            int length = Math.Min(original.Length, changed.Length);
            for (int i = 0; i < changed.Length; i++)
            {
                if (i < length && original[i] == changed[i]) continue;
                var letter = changed[i];
                if (letter >= '\u0400' && letter <= '\u04ff') ru++;
                else if (letter >= 'A' && letter <= 'Z' || letter >= 'a' && letter <= 'z') en++;
            }
            return ru > 0 && en == 0 ? "ru" : en > 0 && ru == 0 ? "en" : fallback;
        }

        private bool ToggleReceipt(CorrectionReceipt prior, bool undo, long generation)
        {
            var focus = NativeFocusSnapshot.Capture();
            var revision = hook.Revision;
            var read = ReadField(focus, 100);
            var field = read.Field;
            if (!CanMutate(generation, revision) || read.Outcome != BrokerOutcome.Success ||
                field == null || !field.SameIdentity(prior.Field) ||
                field.Value != (undo ? prior.Replacement : prior.Original) ||
                field.SelectionStart != field.SelectionEnd ||
                field.SelectionEnd != (prior.NativeRange
                    ? prior.RangeStart + (undo ? prior.ReplacementPhrase.Length : prior.OriginalPhrase.Length)
                    : field.Value.Length)) return false;
            var target = undo ? prior.Original : prior.Replacement;
            var currentPhrase = undo ? prior.ReplacementPhrase : prior.OriginalPhrase;
            var targetPhrase = undo ? prior.OriginalPhrase : prior.ReplacementPhrase;
            var targetLanguage = undo ? prior.SourceLanguage : prior.ResultLanguage;
            bool changed = prior.NativeRange
                ? TryNativeRangeEdit(focus, field, prior.RangeStart,
                    prior.RangeStart + currentPhrase.Length, targetPhrase, revision, generation,
                    currentPhrase, undo ? prior.ResultLanguage : prior.SourceLanguage,
                    targetLanguage, false)
                : TryFullValueEdit(focus, field, target, revision, generation,
                    currentPhrase, targetPhrase, undo ? prior.ResultLanguage : prior.SourceLanguage,
                    targetLanguage, false);
            if (!changed) return false;
            lock (stateGate) { prior.Undone = undo; receipt = prior; }
            if (undo) { try { CorrectionUndone?.Invoke(new CorrectionNotice(prior.ReplacementPhrase, prior.OriginalPhrase, prior.SourceLanguage)); } catch { } }
            else { try { CorrectionApplied?.Invoke(new CorrectionNotice(prior.OriginalPhrase, prior.ReplacementPhrase, prior.SourceLanguage)); } catch { } }
            return true;
        }

        private bool TryFullValueEdit(NativeFocusSnapshot? focus, FieldSnapshot field, string newValue, long revision,
            long generation,
            string oldPhrase, string newPhrase, string source, string? targetLanguage = null,
            bool announce = true, bool allowRecovery = false)
        {
            if (focus == null || field == null || field.SelectionEnd != field.Value.Length || newValue.Length > 32768 ||
                !recovery.CanRetain(field) || !allowRecovery && recovery.Contains(field) ||
                !field.CanWrite || !focus.StillSame() || !CanMutate(generation, revision)) return false;
            lock (editGate)
            {
                if (!CanMutate(generation, revision) || !focus.StillSame()) return false;
                // Warm or restart the broker before the physical input lease starts.
                var preflight = broker.Capture(focus, 250);
                if (preflight.Outcome != BrokerOutcome.Success || preflight.Field == null ||
                    !preflight.Field.CanWrite || !preflight.Field.SameState(field) ||
                    !CanMutate(generation, revision) || !focus.StillSame()) return false;
                using (var fence = hook.BeginFence(revision))
                {
                    if (fence == null) { Publish("Безопасная запись сейчас недоступна.", false); return false; }
                    var remaining = (int)Math.Max(0, fence.DeadlineTicks - (long)Win32.GetTickCount64() - 10);
                    if (remaining < 30) return false;
                    if (!CanMutate(generation, revision)) return false;
                    var write = broker.WriteValue(focus, field, newValue, remaining);
                    if (!CanMutate(generation, revision))
                    {
                        if (write.Outcome != BrokerOutcome.Unsafe) recovery.Add(field, source, write.Field);
                        return false;
                    }
                    if (write.Outcome == BrokerOutcome.Success && !fence.Compromised &&
                        write.Field != null && write.Field.Value == newValue &&
                        write.Field.SelectionStart == write.Field.SelectionEnd && write.Field.SelectionEnd == newValue.Length)
                    {
                        bool sourceConfirmed = targetLanguage == null ||
                            KeyboardLayoutSource.RequestAndConfirm(focus, targetLanguage,
                                (int)Math.Min(20, Math.Max(0, fence.DeadlineTicks - (long)Win32.GetTickCount64())));
                        if (fence.Compromised)
                        {
                            recovery.Add(field, source, write.Field);
                            Publish("Результат изменения не подтверждён. Исходный текст сохранён в памяти для восстановления.", false);
                            return false;
                        }
                        lock (stateGate)
                        {
                            receipt = new CorrectionReceipt { Field = write.Field, Original = field.Value,
                                Replacement = newValue, SourceLanguage = source,
                                ResultLanguage = targetLanguage ?? source, OriginalPhrase = oldPhrase,
                                ReplacementPhrase = newPhrase, Undone = false };
                            sessionField = write.Field;
                            cachedField = write.Field;
                            cachedAtTicks = (long)Win32.GetTickCount64();
                            cachedAtRevision = revision;
                            unknownWord = false;
                            pendingTextKeys = 0;
                            lastSource = sourceConfirmed ? targetLanguage ?? source : null;
                            pendingSource = sourceConfirmed ? null : targetLanguage;
                        }
                        if (announce) try { CorrectionApplied?.Invoke(new CorrectionNotice(oldPhrase, newPhrase, source)); } catch { }
                        if (!sourceConfirmed) Publish("Текст исправлен; смена раскладки не подтверждена.", false);
                        return true;
                    }
                    if (write.Outcome != BrokerOutcome.Unsafe || fence.Compromised)
                    {
                        recovery.Add(field, source, write.Field);
                        Publish("Результат изменения не подтверждён. Исходный текст сохранён в памяти для восстановления.", false);
                    }
                    return false;
                }
            }
        }

        private bool TryNativeRangeEdit(NativeFocusSnapshot? focus, FieldSnapshot field, int start, int end,
            string replacement, long revision, long generation, string oldPhrase,
            string source, string targetLanguage, bool announce = true, bool allowRecovery = false)
        {
            Interlocked.Exchange(ref fixtureNativeCode, 1);
            Interlocked.Exchange(ref fixtureNativeBrokerOutcome, -1);
            Interlocked.Exchange(ref fixtureNativeBrokerStage, -1);
            Interlocked.Exchange(ref fixtureNativeBrokerPhase, -1);
            Interlocked.Exchange(ref fixtureNativeBudgetMilliseconds, -1);
            Interlocked.Exchange(ref fixtureNativeRpcMilliseconds, -1);
            if (focus == null || !field.NativeRangeWriter || start < 0 || end < start ||
                end > field.Value.Length || replacement.Length > 4096 ||
                !recovery.CanRetain(field) || !allowRecovery && recovery.Contains(field) ||
                !focus.StillSame() || !CanMutate(generation, revision))
            { Interlocked.Exchange(ref fixtureNativeCode, 2); return false; }
            var expected = field.Value.Substring(0, start) + replacement + field.Value.Substring(end);
            if (expected.Length > 32768)
            { Interlocked.Exchange(ref fixtureNativeCode, 2); return false; }
            lock (editGate)
            {
                if (!CanMutate(generation, revision) || !focus.StillSame())
                { Interlocked.Exchange(ref fixtureNativeCode, 3); return false; }
                var preflight = broker.Capture(focus, 250); // Broker startup stays outside the input fence.
                Interlocked.Exchange(ref fixtureNativeBrokerOutcome, (int)preflight.Outcome);
                Interlocked.Exchange(ref fixtureNativeBrokerStage, (int)preflight.Stage);
                Interlocked.Exchange(ref fixtureNativeBrokerPhase, (int)preflight.Phase);
                if (preflight.Outcome != BrokerOutcome.Success || preflight.Field == null ||
                    !preflight.Field.NativeRangeWriter || !preflight.Field.SameState(field) ||
                    !CanMutate(generation, revision))
                { Interlocked.Exchange(ref fixtureNativeCode, 4); return false; }
                using (var fence = hook.BeginFence(revision))
                {
                    if (fence == null)
                    { Interlocked.Exchange(ref fixtureNativeCode, 5); return false; }
                    var remaining = (int)Math.Max(0, fence.DeadlineTicks - (long)Win32.GetTickCount64() - 10);
                    Interlocked.Exchange(ref fixtureNativeBudgetMilliseconds, remaining);
                    if (remaining < 30 || !CanMutate(generation, revision))
                    { Interlocked.Exchange(ref fixtureNativeCode, 6); return false; }
                    var rpcStarted = (long)Win32.GetTickCount64();
                    var write = broker.ReplaceNativeRange(focus, field, start, end, replacement, remaining);
                    Interlocked.Exchange(ref fixtureNativeRpcMilliseconds,
                        (int)Math.Min(int.MaxValue, (long)Win32.GetTickCount64() - rpcStarted));
                    Interlocked.Exchange(ref fixtureNativeBrokerOutcome, (int)write.Outcome);
                    Interlocked.Exchange(ref fixtureNativeBrokerStage, (int)write.Stage);
                    Interlocked.Exchange(ref fixtureNativeBrokerPhase, (int)write.Phase);
                    if (!CanMutate(generation, revision) || fence.Compromised)
                    {
                        Interlocked.Exchange(ref fixtureNativeCode, 7);
                        if (write.Outcome != BrokerOutcome.Unsafe || fence.Compromised)
                            recovery.Add(field, source, write.Field);
                        return false;
                    }
                    if (write.Outcome == BrokerOutcome.Success && write.Field != null &&
                        write.Field.SameIdentity(field) && write.Field.Value == expected &&
                        write.Field.SelectionStart == write.Field.SelectionEnd &&
                        write.Field.SelectionEnd == start + replacement.Length)
                    {
                        bool sourceConfirmed = KeyboardLayoutSource.RequestAndConfirm(focus, targetLanguage,
                            (int)Math.Min(20, Math.Max(0, fence.DeadlineTicks - (long)Win32.GetTickCount64())));
                        if (fence.Compromised)
                        {
                            Interlocked.Exchange(ref fixtureNativeCode, 8);
                            recovery.Add(field, source, write.Field);
                            return false;
                        }
                        lock (stateGate)
                        {
                            receipt = new CorrectionReceipt { Field = write.Field, Original = field.Value,
                                Replacement = expected, OriginalPhrase = oldPhrase,
                                ReplacementPhrase = replacement, SourceLanguage = source,
                                ResultLanguage = targetLanguage, NativeRange = true, RangeStart = start };
                            sessionField = write.Field.SelectionEnd == write.Field.Value.Length ? write.Field : null;
                            cachedField = write.Field;
                            cachedAtTicks = (long)Win32.GetTickCount64();
                            cachedAtRevision = revision;
                            unknownWord = sessionField == null;
                            pendingTextKeys = 0;
                            lastSource = sourceConfirmed ? targetLanguage : null;
                            pendingSource = sourceConfirmed ? null : targetLanguage;
                        }
                        if (announce) try { CorrectionApplied?.Invoke(new CorrectionNotice(oldPhrase, replacement, source)); } catch { }
                        if (!sourceConfirmed) Publish("Текст исправлен; смена раскладки не подтверждена.", false);
                        Interlocked.Exchange(ref fixtureNativeCode, 20);
                        return true;
                    }
                    Interlocked.Exchange(ref fixtureNativeCode, write.Outcome == BrokerOutcome.Unsafe ? 9 :
                        write.Outcome == BrokerOutcome.Unknown ? 10 : 11);
                    if (write.Outcome != BrokerOutcome.Unsafe)
                    {
                        recovery.Add(field, source, write.Field);
                        Publish("Результат изменения не подтверждён. Исходный текст сохранён в памяти для восстановления.", false);
                    }
                    return false;
                }
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            Stop();
            disposed = true;
            broker.Dispose();
            lexicon?.Dispose();
        }
    }
}
