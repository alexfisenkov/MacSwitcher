using System;
using System.Collections.Generic;
using System.Linq;

namespace MacSwitcher.Core;

public enum AdaptiveOrigin { Manual, Automatic }
public enum AdaptiveAction { Applied, Undone }

public sealed class AdaptiveEvent
{
    public string OccurrenceId { get; }
    public string Original { get; }
    public string Replacement { get; }
    public AdaptiveOrigin Origin { get; }
    public AdaptiveAction Action { get; }
    public bool SourceConfirmed { get; }
    public long? LearningGeneration { get; }
    public AdaptiveEvent(string occurrenceId, string original, string replacement,
        AdaptiveOrigin origin, AdaptiveAction action, bool sourceConfirmed,long? learningGeneration=null)
    { OccurrenceId=occurrenceId; Original=original; Replacement=replacement;
      Origin=origin; Action=action; SourceConfirmed=sourceConfirmed; LearningGeneration=learningGeneration; }
}

public sealed class AdaptiveRule
{
    public string Russian { get; set; } = "";
    public string English { get; set; } = "";
    public string PreferredLanguage { get; set; } = "";
    public int Count { get; set; }
    public DateTime LastConfirmedUtc { get; set; }
    public string LastOccurrenceId { get; set; } = "";
    public AdaptiveRule Copy() => new AdaptiveRule { Russian=Russian, English=English,
        PreferredLanguage=PreferredLanguage, Count=Count, LastConfirmedUtc=LastConfirmedUtc,
        LastOccurrenceId=LastOccurrenceId };
}

public interface IAdaptiveLexicon
{
    string? PreferredConversion(string word, string language);
    bool IsPreferredPrefix(string word, string language);
}

// The retained record is one pair, not a typing or correction history.
public sealed class AdaptiveLearning
{
    private readonly object gate = new object();
    private List<AdaptiveRule> rules = new List<AdaptiveRule>();
    private long generation;
    private readonly Dictionary<string, VoteState> occurrences = new Dictionary<string, VoteState>(StringComparer.Ordinal);
    private readonly Queue<string> occurrenceOrder = new Queue<string>();
    private sealed class VoteState { public string Pair = ""; public string Direction = ""; public bool Live; }
    public bool Enabled { get; private set; }
    public long Generation { get { lock(gate) return generation; } }
    public void SetEnabled(bool enabled) { lock (gate) { if(Enabled!=enabled) generation++; Enabled=enabled; } }
    public AdaptiveRule[] Snapshot() { lock (gate) return rules.Select(x=>x.Copy()).ToArray(); }
    public void Replace(IEnumerable<AdaptiveRule> source)
    {
        var next=source.Select(x=>x.Copy()).ToList();
        Validate(next);
        lock (gate) { generation++; rules=next; occurrences.Clear(); occurrenceOrder.Clear(); }
    }
    public static void Validate(IReadOnlyList<AdaptiveRule> entries)
    {
        if (entries == null || entries.Count > 2000) throw new ArgumentException("Invalid adaptive rule count");
        var keys=new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in entries)
        {
            if (row == null || row.Count < 1 || row.Count > 2 ||
                !TryPair(row.English,row.Russian,out var en,out var ru) || en!=row.English || ru!=row.Russian ||
                row.PreferredLanguage != "en" && row.PreferredLanguage != "ru" ||
                row.LastConfirmedUtc.Kind != DateTimeKind.Utc || row.LastConfirmedUtc > DateTime.UtcNow.AddDays(1) ||
                row.LastOccurrenceId.Length != 32 || !row.LastOccurrenceId.All(Uri.IsHexDigit) ||
                !keys.Add(en+"\n"+ru)) throw new ArgumentException("Invalid adaptive rule");
        }
    }
    public bool TryApply(AdaptiveEvent change, DateTime utcNow, out AdaptiveRule[] next)
    {
        lock (gate)
        {
            next=rules.Select(x=>x.Copy()).ToArray();
            if (!Enabled || change.LearningGeneration.HasValue && change.LearningGeneration.Value!=generation ||
                !change.SourceConfirmed || change.OccurrenceId.Length!=32 ||
                !change.OccurrenceId.All(Uri.IsHexDigit) ||
                !TryPair(change.Original,change.Replacement,out var en,out var ru)) return false;
            var pair=en+"\n"+ru;
            var direction=PreferredDirection(change, en, ru);
            if (direction==null) return false;
            if (occurrences.TryGetValue(change.OccurrenceId,out var prior))
            {
                if (prior.Pair!=pair || prior.Direction!=direction) return false;
                // A repeated callback or redo cannot recreate a revoked vote.
                if (change.Origin==AdaptiveOrigin.Manual && change.Action==AdaptiveAction.Undone && prior.Live ||
                    change.Origin==AdaptiveOrigin.Automatic && change.Action==AdaptiveAction.Applied && prior.Live)
                {
                    var row=next.FirstOrDefault(x=>x.English==en && x.Russian==ru);
                    if (row!=null && row.PreferredLanguage==direction)
                    {
                        if (row.Count==1) next=next.Where(x=>x!=row).ToArray();
                        else
                        {
                            row.Count=1;
                            if(row.LastOccurrenceId==change.OccurrenceId)
                            {
                                var survivor=occurrences.FirstOrDefault(x=>x.Key!=change.OccurrenceId &&
                                    x.Value.Live && x.Value.Pair==pair && x.Value.Direction==direction);
                                if(survivor.Key!=null) row.LastOccurrenceId=survivor.Key;
                            }
                        }
                        return true;
                    }
                }
                return false;
            }
            if (next.Any(x=>x.LastOccurrenceId==change.OccurrenceId)) return false;
            var vote=change.Origin==AdaptiveOrigin.Manual && change.Action==AdaptiveAction.Applied ||
                change.Origin==AdaptiveOrigin.Automatic && change.Action==AdaptiveAction.Undone;
            if (!vote) return false;
            var existing=next.FirstOrDefault(x=>x.English==en && x.Russian==ru);
            if (existing==null)
            {
                if (next.Length>=2000) return false;
                next=next.Concat(new[]{new AdaptiveRule{English=en,Russian=ru,PreferredLanguage=direction,
                    Count=1,LastConfirmedUtc=utcNow,LastOccurrenceId=change.OccurrenceId}}).ToArray();
            }
            else
            {
                var sameDirection=existing.PreferredLanguage==direction;
                existing.PreferredLanguage=direction;
                existing.Count=sameDirection?Math.Min(2,existing.Count+1):1;
                existing.LastConfirmedUtc=utcNow; existing.LastOccurrenceId=change.OccurrenceId;
            }
            return true;
        }
    }
    public void Commit(AdaptiveEvent change, AdaptiveRule[] next)
    {
        lock (gate)
        {
            Validate(next);
            TryPair(change.Original,change.Replacement,out var oldEn,out var oldRu);
            var previousDirection=rules.FirstOrDefault(x=>x.English==oldEn && x.Russian==oldRu)?.PreferredLanguage;
            rules=next.Select(x=>x.Copy()).ToList();
            if (!occurrences.ContainsKey(change.OccurrenceId))
            {
                TryPair(change.Original,change.Replacement,out var en,out var ru);
                var pair=en+"\n"+ru;
                if(previousDirection!=
                    next.FirstOrDefault(x=>x.English==en && x.Russian==ru)?.PreferredLanguage)
                    foreach(var state in occurrences.Values.Where(x=>x.Pair==pair)) state.Live=false;
                occurrences[change.OccurrenceId]=new VoteState { Pair=en+"\n"+ru,
                    Direction=PreferredDirection(change,en,ru) ?? "",Live=true };
                occurrenceOrder.Enqueue(change.OccurrenceId);
                while (occurrenceOrder.Count>4096) occurrences.Remove(occurrenceOrder.Dequeue());
            }
            else if (change.Origin==AdaptiveOrigin.Manual && change.Action==AdaptiveAction.Undone ||
                     change.Origin==AdaptiveOrigin.Automatic && change.Action==AdaptiveAction.Applied)
                occurrences[change.OccurrenceId].Live=false;
        }
    }
    public void Delete(string english,string russian)
    { lock (gate) { generation++; rules.RemoveAll(x=>x.English==english && x.Russian==russian);
        foreach(var state in occurrences.Values.Where(x=>x.Pair==english+"\n"+russian)) state.Live=false; } }
    public void Reset()
    { lock (gate) { generation++; rules.Clear(); foreach(var state in occurrences.Values) state.Live=false; } }
    public string? PreferredConversion(string word,string language)
    {
        var key=PredictionLexicon.Normalize(word);
        lock (gate)
        {
            if(!Enabled) return null;
            var row=rules.FirstOrDefault(x=>x.Count==2 && (language=="en" ? x.English==key && x.PreferredLanguage=="ru" : x.Russian==key && x.PreferredLanguage=="en"));
            return row==null ? null : LayoutMap.Convert(word,language);
        }
    }
    public bool IsPreferredWord(string word,string language)
    { var key=PredictionLexicon.Normalize(word); lock (gate) return Enabled && rules.Any(x=>x.Count==2 && x.PreferredLanguage==language && (language=="en"?x.English:x.Russian)==key); }
    public bool IsPreferredPrefix(string word,string language)
    { var key=PredictionLexicon.Normalize(word); lock (gate) return Enabled && rules.Any(x=>x.Count==2 && x.PreferredLanguage==language && (language=="en"?x.English:x.Russian).StartsWith(key,StringComparison.Ordinal)); }
    private static string? PreferredDirection(AdaptiveEvent change,string en,string ru)
    {
        var replacement=PredictionLexicon.Normalize(CanonicalWord(change.Replacement));
        if (change.Origin==AdaptiveOrigin.Manual) return replacement==en?"en":replacement==ru?"ru":null;
        var original=PredictionLexicon.Normalize(CanonicalWord(change.Original));
        return original==en?"en":original==ru?"ru":null;
    }
    public static bool TryPair(string first,string second,out string english,out string russian)
    {
        english=russian="";
        if (first==null||second==null) return false;
        var firstEnd=first.Length; var secondEnd=second.Length;
        while(firstEnd>0 && secondEnd>0 && first[firstEnd-1]==second[secondEnd-1] &&
            (char.IsWhiteSpace(first[firstEnd-1]) || "!?;:".Contains(first[firstEnd-1])))
        { firstEnd--; secondEnd--; }
        first=first.Substring(0,firstEnd); second=second.Substring(0,secondEnd);
        if (String.IsNullOrEmpty(first)||String.IsNullOrEmpty(second)||first.Length>64||second.Length>64 ||
            first.Length>=24 && first.Count(char.IsUpper)>=3 || second.Length>=24 && second.Count(char.IsUpper)>=3 ||
            first.Any(char.IsControl)||second.Any(char.IsControl)) return false;
        var a=PredictionLexicon.Normalize(first); var b=PredictionLexicon.Normalize(second);
        var aRu=a.Any(LayoutMap.IsCyrillic); var bRu=b.Any(LayoutMap.IsCyrillic);
        if (aRu==bRu || a.Any(c=>LayoutMap.IsCyrillic(c)) && a.Any(LayoutMap.IsLatin) ||
            b.Any(c=>LayoutMap.IsCyrillic(c)) && b.Any(LayoutMap.IsLatin)) return false;
        english=aRu?b:a; russian=aRu?a:b;
        if (!ValidWord(russian,true) || !ValidMappedEnglish(english) ||
            LayoutMap.Convert(english,"en")!=russian && LayoutMap.Convert(russian,"ru")!=english) return false;
        return true;
    }
    private static string CanonicalWord(string value)
    { return value.TrimEnd(' ','\t','\r','\n','!','?',';',':'); }
    private static bool ValidWord(string value,bool cyrillic)
    {
        if (value.Length<1||value.Length>64 || !value.Any(cyrillic?LayoutMap.IsCyrillic:LayoutMap.IsLatin)) return false;
        for(int i=0;i<value.Length;i++)
        {
            var c=value[i]; if ((cyrillic?LayoutMap.IsCyrillic(c):LayoutMap.IsLatin(c))) continue;
            if ((c=='-'||c=='\'') && i>0 && i<value.Length-1 &&
                (cyrillic?LayoutMap.IsCyrillic(value[i-1]):LayoutMap.IsLatin(value[i-1])) &&
                (cyrillic?LayoutMap.IsCyrillic(value[i+1]):LayoutMap.IsLatin(value[i+1]))) continue;
            return false;
        }
        return true;
    }
    private static bool ValidMappedEnglish(string value)
    {
        if (value.Contains(":")||value.Contains("@")||value.Contains(".")||value.Contains("/") ||
            value.Contains("[") && value.Contains("]")) return false;
        if (value.Contains("\\") && (value.Count(c=>c=='\\')!=1 || value[value.Length-1]!='\\')) return false;
        return value.All(c=>LayoutMap.IsLatin(c)||"[];',\\`-".Contains(c));
    }
}

public sealed class AdaptivePersonalLexicon : IPersonalLexicon, IAdaptiveLexicon
{
    private readonly IPersonalLexicon explicitWords;
    private readonly AdaptiveLearning learned;
    public AdaptivePersonalLexicon(IPersonalLexicon explicitWords,AdaptiveLearning learned)
    { this.explicitWords=explicitWords; this.learned=learned; }
    public bool IsWord(string word,string language) => explicitWords.IsWord(word,language)||learned.IsPreferredWord(word,language);
    public bool IsPhraseException(string original,string sourceLanguage) => explicitWords.IsPhraseException(original,sourceLanguage);
    public string? PreferredConversion(string word,string language) => learned.PreferredConversion(word,language);
    public bool IsPreferredPrefix(string word,string language) => learned.IsPreferredPrefix(word,language);
    public bool IsExplicitWord(string word,string language) => explicitWords.IsWord(word,language);
}
