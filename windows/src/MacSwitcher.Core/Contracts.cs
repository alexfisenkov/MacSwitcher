using System;
using System.Collections.Generic;
using System.Linq;

namespace MacSwitcher.Core;

public sealed class AppSettings
{
    public bool Enabled { get; set; } = true;
    public bool AutomaticCorrection { get; set; } = true;
    public bool RussianPriority { get; set; } = true;
    public bool StartWithWindows { get; set; }
    public bool SmartSelection { get; set; }
    public int DoubleShiftMilliseconds { get; set; } = 180;
    public string[] ExcludedApplications { get; set; } = Array.Empty<string>();
    public string[] AlwaysConvertWords { get; set; } = Array.Empty<string>();
    public void Validate()
    {
        if (DoubleShiftMilliseconds < 80 || DoubleShiftMilliseconds > 400) throw new ArgumentOutOfRangeException(nameof(DoubleShiftMilliseconds));
        if (ExcludedApplications == null || ExcludedApplications.Length > 256 ||
            ExcludedApplications.Any(x => string.IsNullOrWhiteSpace(x) || x.Length > 260))
            throw new ArgumentException("Invalid excluded applications", nameof(ExcludedApplications));
        if (AlwaysConvertWords == null || AlwaysConvertWords.Length > 10000 ||
            AlwaysConvertWords.Any(x => string.IsNullOrWhiteSpace(x) || x.Length > 96 || x.Any(char.IsControl)))
            throw new ArgumentException("Invalid forced words", nameof(AlwaysConvertWords));
    }
}

public interface IPersonalLexicon
{
    bool IsWord(string word, string language);
    bool IsPhraseException(string original, string sourceLanguage);
}

public sealed class PersonalLexiconSnapshot
{
    public string[] RussianWords { get; set; } = Array.Empty<string>();
    public string[] EnglishWords { get; set; } = Array.Empty<string>();
    public string[] RussianPhraseExceptions { get; set; } = Array.Empty<string>();
    public string[] EnglishPhraseExceptions { get; set; } = Array.Empty<string>();
}

public sealed class PersonalLexicon : IPersonalLexicon
{
    private readonly object gate = new object();
    private HashSet<string> ru = new HashSet<string>(StringComparer.Ordinal);
    private HashSet<string> en = new HashSet<string>(StringComparer.Ordinal);
    private HashSet<string> ruExceptions = new HashSet<string>(StringComparer.Ordinal);
    private HashSet<string> enExceptions = new HashSet<string>(StringComparer.Ordinal);
    public bool IsWord(string word, string language)
    {
        lock (gate) return (PredictionLexicon.LanguageCode(language) == "ru" ? ru : en).Contains(PredictionLexicon.Normalize(word));
    }
    public bool IsPhraseException(string original, string sourceLanguage)
    {
        lock (gate) return (PredictionLexicon.LanguageCode(sourceLanguage) == "ru" ? ruExceptions : enExceptions).Contains(PredictionLexicon.Normalize(original));
    }
    public void AddWord(string word, string language) { lock (gate) Words(language).Add(Checked(word)); }
    public void RemoveWord(string word, string language) { lock (gate) Words(language).Remove(Checked(word)); }
    public void AddPhraseException(string phrase, string sourceLanguage) { lock (gate) Exceptions(sourceLanguage).Add(Checked(phrase)); }
    public void RemovePhraseException(string phrase, string sourceLanguage) { lock (gate) Exceptions(sourceLanguage).Remove(Checked(phrase)); }
    public PersonalLexiconSnapshot ExportSnapshot()
    {
        lock (gate) return new PersonalLexiconSnapshot { RussianWords = ru.OrderBy(x => x, StringComparer.Ordinal).ToArray(), EnglishWords = en.OrderBy(x => x, StringComparer.Ordinal).ToArray(), RussianPhraseExceptions = ruExceptions.OrderBy(x => x, StringComparer.Ordinal).ToArray(), EnglishPhraseExceptions = enExceptions.OrderBy(x => x, StringComparer.Ordinal).ToArray() };
    }
    public void ReplaceSnapshot(PersonalLexiconSnapshot snapshot)
    {
        if (snapshot == null) throw new ArgumentNullException(nameof(snapshot));
        var nr = CheckedSet(snapshot.RussianWords); var ne = CheckedSet(snapshot.EnglishWords);
        var nre = CheckedSet(snapshot.RussianPhraseExceptions); var nee = CheckedSet(snapshot.EnglishPhraseExceptions);
        lock (gate) { ru = nr; en = ne; ruExceptions = nre; enExceptions = nee; }
    }
    private HashSet<string> Words(string language) => PredictionLexicon.LanguageCode(language) == "ru" ? ru : en;
    private HashSet<string> Exceptions(string language) => PredictionLexicon.LanguageCode(language) == "ru" ? ruExceptions : enExceptions;
    private static HashSet<string> CheckedSet(string[]? values)
    {
        if (values == null || values.Length > 10000) throw new ArgumentException("Invalid lexicon snapshot");
        return new HashSet<string>(values.Select(Checked), StringComparer.Ordinal);
    }
    private static string Checked(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 512 || value.Any(char.IsControl)) throw new ArgumentException("Invalid personal entry");
        return PredictionLexicon.Normalize(value);
    }
}

public enum ShiftSide { Left, Right }
public enum ShiftActionKind { SwitchLayout, Convert }
public sealed class LayoutDirection
{
    public string SourceId { get; }
    public string TargetId { get; }
    public LayoutDirection(string sourceId, string targetId) { SourceId = sourceId ?? throw new ArgumentNullException(nameof(sourceId)); TargetId = targetId ?? throw new ArgumentNullException(nameof(targetId)); }
}
public sealed class ShiftAction
{
    public ShiftActionKind Kind { get; }
    public LayoutDirection Direction { get; }
    public ShiftAction(ShiftActionKind kind, LayoutDirection direction) { Kind = kind; Direction = direction; }
}
public sealed class ShiftGesture
{
    private sealed class PressState { public ShiftSide side; public long time; public LayoutDirection direction = null!; }
    private sealed class TapState { public long time; public LayoutDirection direction = null!; }
    private readonly int window;
    private PressState? pressed;
    private TapState? first;
    public ShiftGesture(int doubleShiftMilliseconds = 180)
    {
        if (doubleShiftMilliseconds < 80 || doubleShiftMilliseconds > 400) throw new ArgumentOutOfRangeException(nameof(doubleShiftMilliseconds));
        window = doubleShiftMilliseconds;
    }
    public void Press(ShiftSide side, long timestampMilliseconds, LayoutDirection direction)
    {
        if (direction == null) throw new ArgumentNullException(nameof(direction));
        if (pressed != null || first != null && timestampMilliseconds < first.time) { Interrupt(); return; }
        pressed = new PressState { side=side, time=timestampMilliseconds, direction=direction };
    }
    public ShiftAction? Release(ShiftSide side, long timestampMilliseconds)
    {
        if (pressed == null || pressed.side != side || timestampMilliseconds < pressed.time || timestampMilliseconds - pressed.time > 250) { Interrupt(); return null; }
        var current = pressed; pressed = null;
        if (first != null && timestampMilliseconds >= first.time && timestampMilliseconds - first.time <= window)
        {
            var direction = first.direction; first = null; return new ShiftAction(ShiftActionKind.Convert, direction);
        }
        first = new TapState { time=timestampMilliseconds, direction=current.direction };
        return new ShiftAction(ShiftActionKind.SwitchLayout, current.direction);
    }
    public void Interrupt() { pressed = null; first = null; }
}
