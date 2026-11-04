using System;
using MacSwitcher.Windows.Native;
using MacSwitcher.Windows.Automation;
using MacSwitcher.Core;
using System.IO;
using System.Text;
using System.Linq;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Threading;
using MacSwitcher.Windows.Storage;

namespace MacSwitcher.Windows.Runtime
{
    internal static class RuntimeContractChecks
    {
        internal static int Run()
        {
            var context = WindowsSwitcherRuntime.BuildPredictionContext("press f yt");
            if (context == null || context.Suffix != "f yt" || context.PrecedingWords.Length != 1 ||
                context.PrecedingWords[0] != "press") return 1;
            context = WindowsSwitcherRuntime.BuildPredictionContext("one two three ");
            if (context == null || context.Suffix != "two three " || context.PrecedingWords.Length != 1 ||
                context.PrecedingWords[0] != "one") return 2;
            if (WindowsSwitcherRuntime.ResultLanguage("ghbdtn", "привет", "en") != "ru") return 3;
            if (WindowsSwitcherRuntime.ResultLanguage("abcабв", "фывагп", "en") != "ru") return 4;
            if (WindowsSwitcherRuntime.ResultLanguage("abcабв", "фывxyz", "en") != "en") return 5;
            if (WindowsSwitcherRuntime.ActualWordLanguage("ghbdtn", "ru") != "en" ||
                WindowsSwitcherRuntime.ActualWordLanguage("привет", "en") != "ru" ||
                LayoutMap.ConvertBidirectional("ghbdtn") != "привет") return 18;
            var manualSpan = WindowsSwitcherRuntime.LastWordSpan("one ghbdtn ");
            if (manualSpan == null || manualSpan.Start != 4 || manualSpan.End != 11 ||
                manualSpan.WordText != "ghbdtn" || manualSpan.OriginalRange != "ghbdtn " ||
                manualSpan.ReplacementRange("привет") != "привет " ||
                "one ghbdtn ".Substring(manualSpan.Start, manualSpan.End - manualSpan.Start)
                    != manualSpan.OriginalRange) return 19;
            manualSpan = WindowsSwitcherRuntime.LastWordSpan("one ghbdtn  ");
            if (manualSpan == null || manualSpan.Start != 4 || manualSpan.End != 12 ||
                manualSpan.ReplacementRange("привет") != "привет  " ||
                WindowsSwitcherRuntime.LastWordSpan("ghbdtn" + new string(' ', 4091)) != null)
                return 20;
            manualSpan = WindowsSwitcherRuntime.LastWordSpan("one ghbdtn\t\r\n\u00a0");
            if (manualSpan == null || manualSpan.Start != 4 ||
                manualSpan.End != "one ghbdtn\t\r\n\u00a0".Length ||
                manualSpan.TrailingWhitespace != "\t\r\n\u00a0" ||
                manualSpan.ReplacementRange("привет") != "привет\t\r\n\u00a0")
                return 22;
            manualSpan = WindowsSwitcherRuntime.LastWordSpan("one ghbdtn! ");
            if (manualSpan == null || manualSpan.Start != 4 || manualSpan.End != 12 ||
                manualSpan.OriginalRange != "ghbdtn! " ||
                manualSpan.ReplacementRange(LayoutMap.ConvertBidirectional(manualSpan.WordText))
                    != "привет! ") return 21;
            if (!WindowsSwitcherRuntime.PermitMutation(true, true, false, 4, 4, 10, 10) ||
                WindowsSwitcherRuntime.PermitMutation(true, true, false, 5, 4, 10, 10) ||
                WindowsSwitcherRuntime.PermitMutation(false, true, false, 4, 4, 10, 10) ||
                WindowsSwitcherRuntime.PermitMutation(true, false, false, 4, 4, 10, 10) ||
                WindowsSwitcherRuntime.PermitMutation(true, true, true, 4, 4, 10, 10)) return 6;
            if (!PhysicalHookHost.IsPassiveMouseMessage(Win32.WM_MOUSEMOVE) ||
                PhysicalHookHost.IsPassiveMouseMessage(0x0201) ||
                PhysicalHookHost.IsPassiveMouseMessage(0x020A)) return 7;
            if (BrokerWire.IsWellFormedUtf16("\ud800") ||
                BrokerWire.IsWellFormedUtf16("\udc00") ||
                !BrokerWire.IsWellFormedUtf16("\ud83d\ude00") ||
                BrokerWire.IsScalarBoundary("\ud83d\ude00", 1) ||
                !BrokerWire.IsScalarBoundary("\ud83d\ude00", 2)) return 8;
            bool malformedRejected = false, splitRejected = false;
            try { BrokerWire.EncodeFrame(w => BrokerWire.WriteText(w, "\ud800")); }
            catch (EncoderFallbackException) { malformedRejected = true; }
            try
            {
                BrokerWire.EncodeFrame(w => BrokerWire.WriteField(w, new FieldSnapshot
                {
                    Foreground = new IntPtr(1), Focus = new IntPtr(2), ProcessId = 3, ThreadId = 4,
                    RuntimeId = new[] { 5 }, Value = "\ud83d\ude00",
                    SelectionStart = 1, SelectionEnd = 1
                }));
            }
            catch (InvalidDataException) { splitRejected = true; }
            if (!malformedRejected || !splitRejected) return 12;
            var entry = new RecoveryEntry { Id = "abcd", Application = "fixture", ProcessId = 12,
                ThreadId = 13, ForegroundHandle = 14, FocusHandle = 15,
                RuntimeId = new[] { 1, 2 }, Original = "original", HasObservation = true,
                LastObserved = "observed" };
            var field = new FieldSnapshot { ProcessId = 12, ThreadId = 13,
                Foreground = new IntPtr(14), Focus = new IntPtr(15),
                RuntimeId = new[] { 1, 2 }, Value = "observed" };
            if (!new RecoveryOriginalInfo(entry).MatchesLastObserved(field)) return 9;
            if (BrokerWire.PreparationOutcome(false, false, false) != BrokerOutcome.Unsafe ||
                BrokerWire.PreparationOutcome(true, true, false) != BrokerOutcome.Unsafe ||
                BrokerWire.PreparationOutcome(true, false, false) != BrokerOutcome.Unknown ||
                BrokerWire.PreparationOutcome(true, true, true) != BrokerOutcome.Unknown)
                return 17;
            field.Value = "newer work";
            if (new RecoveryOriginalInfo(entry).MatchesLastObserved(field)) return 10;
            entry.HasObservation = false; field.Value = "observed";
            if (new RecoveryOriginalInfo(entry).MatchesLastObserved(field)) return 11;
            var direction = new LayoutDirection("en", "ru");
            var delayed = new ShiftGesture(180);
            delayed.Press(ShiftSide.Left, PhysicalHookHost.ExtendEventTime(100000, 100000), direction);
            if (delayed.Release(ShiftSide.Left, PhysicalHookHost.ExtendEventTime(100020, 100120))?.Kind
                != ShiftActionKind.SwitchLayout) return 13;
            delayed.Press(ShiftSide.Right, PhysicalHookHost.ExtendEventTime(100190, 100190), direction);
            if (delayed.Release(ShiftSide.Right, PhysicalHookHost.ExtendEventTime(100210, 100210))?.Kind
                != ShiftActionKind.SwitchLayout) return 14;
            const ulong wrap = 4294967296UL;
            var aroundWrap = new ShiftGesture(180);
            aroundWrap.Press(ShiftSide.Left, PhysicalHookHost.ExtendEventTime(0xFFFFFFE0, wrap + 10), direction);
            if (aroundWrap.Release(ShiftSide.Left, PhysicalHookHost.ExtendEventTime(0xFFFFFFF0, wrap + 20))?.Kind
                != ShiftActionKind.SwitchLayout) return 15;
            aroundWrap.Press(ShiftSide.Right, PhysicalHookHost.ExtendEventTime(10, wrap + 20), direction);
            if (aroundWrap.Release(ShiftSide.Right, PhysicalHookHost.ExtendEventTime(30, wrap + 50))?.Kind
                != ShiftActionKind.Convert) return 16;
            if (!AdaptiveStoreFixture()) return 23;
            if (!UndoFrontierFixture()) return 24;
            if (!UndoFrontierResetFixture()) return 25;
            return 0;
        }
        private static bool UndoFrontierResetFixture()
        {
            var bound = new FieldSnapshot { Value = "MacSwitcher f", SelectionStart = 13, SelectionEnd = 13 };
            var frontier = new ConfirmedUndoFrontier(bound.Value);
            FieldSnapshot? field = bound;
            ConfirmedUndoFrontier? state = frontier;
            var keep = WindowsSwitcherRuntime.PreserveUndoFrontierForInput(0x41,true,true);
            WindowsSwitcherRuntime.ResetUndoFrontier(ref field,ref state,keep);
            if (!keep || !ReferenceEquals(field,bound) || !ReferenceEquals(state,frontier)) return false;
            bool MustClear(int key, bool shift, bool commands)
            {
                field = bound; state = frontier;
                keep = WindowsSwitcherRuntime.PreserveUndoFrontierForInput(key,shift,commands);
                WindowsSwitcherRuntime.ResetUndoFrontier(ref field,ref state,keep);
                return !keep && field == null && state == null;
            }
            return MustClear(0x25,true,true) && MustClear(0x41,true,false) &&
                MustClear(0x41,false,true);
        }
        private static bool UndoFrontierFixture()
        {
            foreach (var native in new[] { true, false })
            {
                var bound = new FieldSnapshot { Foreground = new IntPtr(1), Focus = new IntPtr(2),
                    ProcessId = 3, ThreadId = 4, RuntimeId = new[] { 5 },
                    Value = "MacSwitcher f", SelectionStart = 13, SelectionEnd = 13,
                    NativeRangeWriter = native };
                var frontier = new ConfirmedUndoFrontier(bound.Value);
                var current = new FieldSnapshot { Foreground = bound.Foreground, Focus = bound.Focus,
                    ProcessId = bound.ProcessId, ThreadId = bound.ThreadId, RuntimeId = new[] { 5 },
                    Value = "MacSwitcher f ", SelectionStart = 14, SelectionEnd = 14,
                    NativeRangeWriter = native };
                if (!WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,frontier,out var text) ||
                    text != null) return false;
                current.Value = "MacSwitcher f yt ";
                current.SelectionStart = current.SelectionEnd = current.Value.Length;
                if (!WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,frontier,out text) ||
                    text != "yt ") return false;
                foreach (var spaces in new[] { 2, 3, 8 })
                {
                    current.Value = "MacSwitcher f" + new string(' ',spaces) + "yt ";
                    current.SelectionStart = current.SelectionEnd = current.Value.Length;
                    if (!WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,frontier,out text) ||
                        text != "yt " ||
                        WindowsSwitcherRuntime.BuildPredictionContext(text)?.Suffix != "yt " ||
                        current.Value.Substring(0,current.Value.Length-text.Length)+"не " !=
                            "MacSwitcher f"+new string(' ',spaces)+"не ") return false;
                }
                current.Value = "MacSwitcher f f";
                current.SelectionStart = current.SelectionEnd = current.Value.Length;
                if (!WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,frontier,out text) ||
                    text != "f") return false;
                current.SelectionStart--;
                if (WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,frontier,out _)) return false;
                current.SelectionStart = current.SelectionEnd;
                current.Value = "MacSwitcher g yt ";
                current.SelectionStart = current.SelectionEnd = current.Value.Length;
                if (WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,frontier,out _)) return false;
                current.Value = "MacSwitcher f yt ";
                current.SelectionStart = current.SelectionEnd = current.Value.Length;
                current.RuntimeId = new[] { 6 };
                if (WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,frontier,out _)) return false;
                var closed = new ConfirmedUndoFrontier("MacSwitcher yt ");
                current.RuntimeId = new[] { 5 };
                current.Value = "MacSwitcher yt ghbdtn";
                current.SelectionStart = current.SelectionEnd = current.Value.Length;
                if (!WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,closed,out text) ||
                    text != "ghbdtn") return false;
                foreach (var extra in new[] { 1, 2, 7 })
                {
                    current.Value = "MacSwitcher yt " + new string(' ',extra) + "ghbdtn";
                    current.SelectionStart = current.SelectionEnd = current.Value.Length;
                    if (!WindowsSwitcherRuntime.TryUndoPredictionText(current,bound,closed,out text) ||
                        text != "ghbdtn" ||
                        WindowsSwitcherRuntime.BuildPredictionContext(text)?.Suffix != "ghbdtn") return false;
                }
            }
            return true;
        }
        private static bool AdaptiveStoreFixture()
        {
            var directory=Path.Combine(Path.GetTempPath(),"MacSwitcher-adaptive-fixture-"+Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var settingsDirectory=Path.Combine(directory,"settings-case");
                Directory.CreateDirectory(settingsDirectory);
                var settingsFile=Path.Combine(settingsDirectory,"settings.json");
                var legacySettings="{\"Schema\":1,\"Enabled\":true,\"AutomaticCorrection\":true,"+
                    "\"RussianPriority\":true,\"StartWithWindows\":false,\"DoubleShiftMilliseconds\":180,"+
                    "\"ExcludedApplications\":[],\"AlwaysConvertWords\":[],\"SmartSelection\":false";
                File.WriteAllText(settingsFile,legacySettings+"}");
                var migrated=new ConfigurationStore(settingsDirectory); migrated.Load();
                if(!migrated.Settings.RememberCorrections || !migrated.LearningExplanationPending) return false;
                File.WriteAllText(settingsFile,legacySettings+",\"RememberCorrections\":false}");
                var optedOut=new ConfigurationStore(settingsDirectory); optedOut.Load();
                if(optedOut.Settings.RememberCorrections || optedOut.Adaptive.Learning.Enabled ||
                    optedOut.LearningExplanationPending) return false;
                var store=new AdaptiveRulesStore(directory); store.Load(true);
                var first=new AdaptiveEvent(Guid.NewGuid().ToString("N"),"ghbdtn ","привет ",
                    AdaptiveOrigin.Manual,AdaptiveAction.Applied,true);
                store.Submit(first);
                if(!SpinWait.SpinUntil(()=>store.Snapshot().Length==1,5000)) return false;
                var file=Path.Combine(directory,"adaptive-rules.json");
                if(!File.Exists(file)||store.Snapshot()[0].Count!=1) return false;
                using(var entered=new ManualResetEventSlim(false))
                using(var release=new ManualResetEventSlim(false))
                {
                    var blocked=new AdaptiveRulesStore(directory,()=>{entered.Set(); release.Wait(5000);});
                    blocked.Load(true);
                    blocked.Submit(new AdaptiveEvent(Guid.NewGuid().ToString("N"),"ghbdtn","привет",
                        AdaptiveOrigin.Manual,AdaptiveAction.Applied,true));
                    if(!entered.Wait(5000)) return false;
                    var watch=Stopwatch.StartNew();
                    blocked.Submit(new AdaptiveEvent(Guid.NewGuid().ToString("N"),"привет","ghbdtn",
                        AdaptiveOrigin.Manual,AdaptiveAction.Applied,true));
                    watch.Stop(); release.Set();
                    if(watch.ElapsedMilliseconds>80 || !SpinWait.SpinUntil(()=>
                        blocked.Snapshot().Length==1 && blocked.Snapshot()[0].PreferredLanguage=="en",5000)) return false;
                    if(blocked.Snapshot()[0].Count!=1) return false;
                }
                var restarted=new AdaptiveRulesStore(directory); restarted.Load(true);
                if(restarted.Snapshot().Length!=1||restarted.Snapshot()[0].Count!=1 ||
                    restarted.Snapshot()[0].PreferredLanguage!="en") return false;
                var cleanupFault=new AdaptiveRulesStore(directory,null,()=>throw new IOException("fixture cleanup failure"));
                cleanupFault.Load(true);
                cleanupFault.Submit(new AdaptiveEvent(Guid.NewGuid().ToString("N"),"привет","ghbdtn",
                    AdaptiveOrigin.Manual,AdaptiveAction.Applied,true));
                if(!SpinWait.SpinUntil(()=>cleanupFault.Snapshot().Length==1 &&
                    cleanupFault.Snapshot()[0].Count==2,5000) || !cleanupFault.CanWrite ||
                    cleanupFault.CleanupProblem.Length==0) return false;
                cleanupFault.Delete("ghbdtn","привет");
                if(cleanupFault.Snapshot().Length!=0 || cleanupFault.CleanupProblem.Length==0) return false;
                cleanupFault.Reset();
                if(cleanupFault.Snapshot().Length!=0 || cleanupFault.CleanupProblem.Length==0) return false;
                restarted.Load(true); // Startup retries only exact .tmp-/.rollback- names.
                if(restarted.Snapshot().Length!=0 || restarted.CleanupProblem.Length!=0) return false;
                using(var enteredOff=new ManualResetEventSlim(false))
                using(var releaseOff=new ManualResetEventSlim(false))
                {
                    var blockedOff=new AdaptiveRulesStore(directory,()=>{enteredOff.Set(); releaseOff.Wait(5000);});
                    blockedOff.Load(true);
                    blockedOff.Submit(new AdaptiveEvent(Guid.NewGuid().ToString("N"),"ghbdtn","привет",
                        AdaptiveOrigin.Manual,AdaptiveAction.Applied,true));
                    if(!enteredOff.Wait(5000)) { releaseOff.Set(); return false; }
                    blockedOff.Submit(new AdaptiveEvent(Guid.NewGuid().ToString("N"),"ghbdtn","привет",
                        AdaptiveOrigin.Manual,AdaptiveAction.Applied,true));
                    var offTask=Task.Run(()=>blockedOff.SetEnabled(false));
                    if(!SpinWait.SpinUntil(()=>!blockedOff.FixtureAccepting,1000))
                    { releaseOff.Set(); return false; }
                    releaseOff.Set();
                    if(!offTask.Wait(5000) || !SpinWait.SpinUntil(()=>blockedOff.FixtureIdle,5000) ||
                        blockedOff.Snapshot().Length!=1 || blockedOff.Snapshot()[0].Count!=1) return false;
                }
                restarted.Load(true);
                if(restarted.Snapshot().Length!=1 || restarted.Snapshot()[0].Count!=1) return false;
                restarted.Reset();
                if(restarted.Snapshot().Length!=0) return false;
                var writeFault=new AdaptiveRulesStore(directory,()=>throw new IOException("fixture disk failure"));
                writeFault.Load(true);
                writeFault.Submit(new AdaptiveEvent(Guid.NewGuid().ToString("N"),"ghbdtn","привет",
                    AdaptiveOrigin.Manual,AdaptiveAction.Applied,true));
                if(!SpinWait.SpinUntil(()=>!writeFault.CanWrite,5000) ||
                    writeFault.Snapshot().Length!=0) return false;
                restarted.Load(true);
                if(restarted.Snapshot().Length!=0) return false;
                var bytes=Encoding.UTF8.GetBytes("{\"Schema\":99,\"Rules\":[]}");
                File.WriteAllBytes(file,bytes);
                var future=new AdaptiveRulesStore(directory); future.Load(true);
                if(future.CanWrite||future.Learning.Enabled||future.Snapshot().Length!=0||
                    !File.ReadAllBytes(file).SequenceEqual(bytes)) return false;
                File.WriteAllBytes(file,new byte[512*1024+1]);
                var oversized=new AdaptiveRulesStore(directory); oversized.Load(true);
                return !oversized.CanWrite && !oversized.Learning.Enabled &&
                    new FileInfo(file).Length==512*1024+1;
            }
            finally { try { Directory.Delete(directory,true); } catch { } }
        }
    }
}
