using System;
using MacSwitcher.Windows.Native;
using MacSwitcher.Windows.Automation;
using MacSwitcher.Core;
using System.IO;
using System.Text;

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
                manualSpan.Token != "ghbdtn" || manualSpan.OriginalRange != "ghbdtn " ||
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
                manualSpan.ReplacementRange(LayoutMap.ConvertBidirectional(manualSpan.Token))
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
            return 0;
        }
    }
}
