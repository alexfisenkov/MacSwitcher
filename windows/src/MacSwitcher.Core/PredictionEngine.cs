using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace MacSwitcher.Core;

public sealed class PredictionProposal
{
    public string OriginalSuffix { get; }
    public string ReplacementSuffix { get; }
    public string TargetLanguage { get; }
    public string Reason { get; }
    public PredictionProposal(string originalSuffix, string replacementSuffix, string targetLanguage, string reason)
    { OriginalSuffix = originalSuffix; ReplacementSuffix = replacementSuffix; TargetLanguage = targetLanguage; Reason = reason; }
}

public sealed class PredictionEngine
{
    private readonly PredictionLexicon lexicon;
    public PredictionEngine(PredictionLexicon lexicon) { this.lexicon = lexicon ?? throw new ArgumentNullException(nameof(lexicon)); }
    private static readonly HashSet<string> TechnicalContext = Set("press key keys keyboard button function variable symbol нажми нажмите клавиша клавишу клавиши клавишей буква букву буквы символ символа символом функция функцию переменная витамин");
    private static readonly HashSet<string> DomainContext = Set("сайт сайта сайте домен домена домене ссылка ссылке адрес адресу хост хосте domain url website site host hostname link visit browse");
    private static readonly HashSet<string> PeopleModifiers = Set("эти все наши другие многие некоторые добрые хорошие новые молодые");
    private static readonly HashSet<string> HostSuffixes = Set("com org net edu gov mil int info biz name mobi online site app dev tech shop store cloud website xyz pro one top club live news world design space blog wiki video social email work agency digital studio today travel support solutions systems network company center zone link click tools pages рф xn--p1ai");
    private static readonly HashSet<string> PriorityWords = Set("а ну не да нет но же бы ли вот уже ещё это как что или где там тут без для");
    private static readonly HashSet<string> ImmediateLetters = Set("а и в к с у о я");
    private static readonly HashSet<string> TechnicalCues = Set("press key keys keyboard button function variable symbol code script command shortcut url domain host path file folder directory нажми нажмите клавиша клавишу буква букву символ символа переменная путь файл");
    private static readonly Dictionary<string,string> ContextWords = new Dictionary<string,string> { ["ns"]="ты",["jy"]="он",["vs"]="мы",["ds"]="вы",["dct"]="все",["dfc"]="вас",["jn"]="от",["yfi"]="наш",["vbh"]="мир",["yb"]="ни",["fuf"]="ага" };
    private static HashSet<string> Set(string values) => new HashSet<string>(values.Split(' '), StringComparer.Ordinal);

    public PredictionProposal? Evaluate(string suffix, string sourceLanguage, bool atBoundary = false, string[]? precedingWords = null, bool russianPriority = false, IEnumerable<string>? alwaysConvertWords = null)
    {
        var source = PredictionLexicon.LanguageCode(sourceLanguage); precedingWords ??= Array.Empty<string>();
        if (source != "en" && source != "ru" || string.IsNullOrEmpty(suffix) || suffix.Length > 512 || suffix.Any(c => c == '\r' || c == '\n' || c == '\t') || lexicon.IsPhraseException(suffix, source)) return null;
        var words = Regex.Matches(suffix, @"\S+").Cast<Match>().ToArray(); if (words.Length == 0) return null;
        var current = words[words.Length-1].Value; var target = source == "en" ? "ru" : "en";
        var cues = precedingWords.Concat(words.Take(words.Length-1).Select(x => x.Value)).TakeLastCompat(3).ToArray();
        var hasDomain = cues.Any(x => DomainContext.Contains(ContextKey(x)));
        var hasPeople = cues.Length > 0 && PeopleModifiers.Contains(ContextKey(cues[cues.Length-1]));
        var previous = words.Length >= 2 ? words[words.Length-2].Value : null;
        var paired = previous == "f" && (current == "yt" || current == "to\\" || current == "to`");
        var priorityContext = precedingWords.Concat(words.Take(words.Length - (paired ? 2 : 1)).Select(x => x.Value)).ToArray();
        var exactYo = source == "en" && (current == "to\\" || current == "to`");
        string? priority = null;
        if (russianPriority && (exactYo || !ProtectedToken(current))) priority = PriorityReplacement(current, previous, source, priorityContext, atBoundary || char.IsWhiteSpace(suffix[suffix.Length-1]));
        if (russianPriority && exactYo && priority == null) return null;
        var corrected = priority ?? Correction(current, source, target, atBoundary || char.IsWhiteSpace(suffix[suffix.Length-1]), hasDomain, hasPeople, russianPriority, russianPriority && ProtectsEnglishContext(cues), alwaysConvertWords);
        var resulting = corrected ?? current;
        if (words.Length >= 2)
        {
            var prevMatch = words[words.Length-2];
            var earlier = words.Take(words.Length-2).Select(x => x.Value).ToArray();
            var technical = precedingWords.Concat(earlier).TakeLastCompat(3).Any(x => TechnicalContext.Contains(ContextKey(x)));
            if (previous == "f" && !technical && (!russianPriority || !lexicon.IsPersonalWord("f","en")) && StrongRussianContext(resulting))
            {
                var replacement = ReplacePair(suffix, prevMatch, "а", words[words.Length-1], resulting);
                return new PredictionProposal(suffix,replacement,"ru","contextWord");
            }
            if (priority == "не" && previous == "f" && !technical && (!russianPriority || !lexicon.IsPersonalWord("f","en")))
                return new PredictionProposal(suffix,ReplacePair(suffix,prevMatch,"а",words[words.Length-1],"не"),"ru","contextWord");
            if (russianPriority && source == "en" && corrected != null && corrected != current && StrongRussianContext(corrected))
            {
                var contextual = ContextualReplacement(previous!, precedingWords.Concat(earlier).ToArray());
                if (contextual != null) return new PredictionProposal(suffix,ReplacePair(suffix,prevMatch,contextual,words[words.Length-1],corrected),"ru","contextWord");
            }
        }
        if (corrected == null || corrected == current) return null;
        var last = words[words.Length-1];
        return new PredictionProposal(suffix,suffix.Substring(0,last.Index)+corrected+suffix.Substring(last.Index+last.Length),target,"currentWord");
    }
    private static string ReplacePair(string text, Match previous, string prevReplacement, Match current, string currentReplacement) =>
        text.Substring(0,previous.Index)+prevReplacement+text.Substring(previous.Index+previous.Length,current.Index-(previous.Index+previous.Length))+currentReplacement+text.Substring(current.Index+current.Length);
    private string? Correction(string word,string source,string target,bool atBoundary,bool hasDomain,bool hasPeople,bool russianPriority,bool protectedEnglishContext,IEnumerable<string>? alwaysConvertWords)
    {
        var split = StripPunctuation(word); var core=split.core; var suffix=split.suffix;
        var mapped = LayoutMap.Convert(word,source);
        var candidates = suffix.Length == 0 ? new[] { new Candidate(mapped, "") } : new[] { new Candidate(mapped, ""), new Candidate(LayoutMap.Convert(core,source),suffix) };
        var forcedSet = alwaysConvertWords == null ? null : new HashSet<string>(alwaysConvertWords.Select(PredictionLexicon.Normalize),StringComparer.Ordinal);
        var forced = atBoundary && forcedSet != null ? candidates.FirstOrDefault(c => Lexical(c.Core) && forcedSet.Contains(c.Core.ToLowerInvariant()) && c.Core+c.Suffix != word) : null;
        var knownTarget = candidates.Any(c => lexicon.IsProtectedTerm(c.Core,target));
        var protectedHostname = HasHostnameShape(core);
        var exactDot = source == "en" && !hasDomain && candidates.Any(c => Lexical(c.Core) && (!protectedHostname || hasPeople && c.Core.ToLowerInvariant() == "люди") &&
            (lexicon.Frequency(c.Core,"ru") >= 50000 || russianPriority && !protectedHostname && !protectedEnglishContext && core.Contains(".,") && lexicon.Frequency(c.Core,"ru") >= 10000 || lexicon.IsProtectedTerm(c.Core,"ru")));
        if (ProtectedToken(word,knownTarget || forced != null,forced != null,exactDot)) return null;
        if (forced != null) return forced.Core+forced.Suffix;
        if (lexicon.IsProtectedTerm(core,source) || word.Length < 2 || lexicon.Frequency(word,source)>0 || lexicon.Frequency(core,source)>0) return null;
        if (atBoundary)
        {
            foreach (var c in candidates) if (c.Core.Length >= 3 && Lexical(c.Core) && lexicon.IsPersonalWord(c.Core,target)) return c.Core+c.Suffix;
        }
        var spelling = lexicon.HasSupplementalSpelling(core,source); if (!spelling.HasValue || spelling.Value) return null;
        var fullWord = lexicon.FullFrequency(word,source); var fullCore = suffix.Length == 0 ? fullWord : lexicon.FullFrequency(core,source);
        if (!fullWord.HasValue || !fullCore.HasValue) return null;
        var rareSource = Math.Max(fullWord.Value,fullCore.Value);
        foreach (var candidate in candidates)
        {
            var value = candidate.Core; if (!Lexical(value) || value.Length < 2) continue;
            var sourcePrefix = lexicon.PrefixEvidence(core,source); var frequency = lexicon.Frequency(value,target);
            if (rareSource > 0)
            {
                var minimum = atBoundary ? 50000 : 100000;
                if (rareSource > (atBoundary ? 50 : 10) || frequency < minimum || frequency / rareSource < 10000) continue;
                if (!atBoundary && value.Count(char.IsLetter) < 4) continue;
            }
            if (rareSource == 0 && lexicon.IsProtectedTerm(value,target) && value.Count(char.IsLetter) >= (atBoundary ? 3 : 4) && sourcePrefix.MaximumFrequency <= 50) return value+candidate.Suffix;
            if (atBoundary) { if (frequency >= 500) return value+candidate.Suffix; continue; }
            if (value.Count(char.IsLetter) < 4) continue;
            var targetPrefix = lexicon.PrefixEvidence(value,target); var strength = Math.Max(frequency,targetPrefix.MaximumFrequency);
            if (strength >= 5000 && sourcePrefix.MaximumFrequency <= 50 && strength / Math.Max(1,sourcePrefix.MaximumFrequency) >= 100 &&
                (frequency >= 5000 || candidate.Suffix.Length == 0 && targetPrefix.Completions > 0)) return value+candidate.Suffix;
        }
        if (atBoundary && rareSource == 0)
        {
            var matches = new HashSet<string>(StringComparer.Ordinal);
            foreach (var candidate in candidates) if (Lexical(candidate.Core) && candidate.Core.Count(char.IsLetter)>=4)
            {
                var match = lexicon.HasSupplementalSpelling(candidate.Core,target); if (!match.HasValue) return null;
                if (match.Value) matches.Add(candidate.Core+candidate.Suffix);
            }
            if (matches.Count == 1) return matches.First();
        }
        return null;
    }
    private bool StrongRussianContext(string word)
    {
        if (ProtectedToken(word)) return false;
        var core = StripPunctuation(word).core;
        if (core.Length < 3 || !core.All(c => LayoutMap.IsCyrillic(c) || c=='-')) return false;
        if (lexicon.Frequency(core,"ru") >= 5000) return true;
        var prefix = lexicon.PrefixEvidence(core,"ru");
        return core.Length >= 4 && prefix.MaximumFrequency >= 20000 && prefix.Completions > 0;
    }
    private static bool ProtectedToken(string word,bool allowKnownTargetCase=false,bool allowAllCaps=false,bool allowMappedInteriorDot=false)
    {
        if (word.Length == 0 || word.Length > 96 || word.Any(c => char.IsDigit(c) || "@_/:\\=+(){}<>#".Contains(c))) return true;
        var letters = word.Where(char.IsLetter).ToArray(); if (letters.Length == 0) return true;
        if (!allowAllCaps && letters.Length > 1 && new string(letters) == new string(letters).ToUpperInvariant()) return true;
        if (!allowKnownTargetCase && word.Skip(1).Any(char.IsUpper)) return true;
        var latin = letters.Any(LayoutMap.IsLatin); var cyr = letters.Any(LayoutMap.IsCyrillic); if (latin && cyr) return true;
        var dot = word.IndexOf('.'); if (latin && !allowMappedInteriorDot && dot >= 0 && word.Skip(dot+1).Any(char.IsLetter)) return true;
        return false;
    }
    private static bool HasHostnameShape(string word)
    {
        var labels = word.ToLowerInvariant().Split('.'); if (labels.Length < 2 || labels.Any(x => x.Length==0 || x[0]=='-' || x[x.Length-1]=='-' || x.Any(c => !char.IsLetterOrDigit(c) && c!='-'))) return false;
        var ending = labels[labels.Length-1]; return ending.Length==2 && ending.All(char.IsLetter) || HostSuffixes.Contains(ending);
    }
    private static bool Lexical(string word) => word.Length>0 && char.IsLetter(word[0]) && char.IsLetter(word[word.Length-1]) && word.All(c => char.IsLetter(c) || c=='-') && !word.Contains("--");
    private sealed class Candidate { public string Core; public string Suffix; public Candidate(string core,string suffix) { Core=core; Suffix=suffix; } }
    private sealed class SplitWord { public string core; public string suffix; public SplitWord(string core,string suffix) { this.core=core; this.suffix=suffix; } }
    private static SplitWord StripPunctuation(string word)
    {
        var i=word.Length; while (i>0 && ",.!?;:)".Contains(word[i-1])) i--; return new SplitWord(word.Substring(0,i),word.Substring(i));
    }
    private static string ContextKey(string value)
    {
        var text=value.ToLowerInvariant(); var start=0; while(start<text.Length && char.IsPunctuation(text[start]))start++;
        var end=text.Length; while(end>start && char.IsPunctuation(text[end-1]))end--; return text.Substring(start,end-start);
    }
    private bool ProtectsEnglishContext(string[] words) => words.TakeLastCompat(3).Any(word => {
        var key=ContextKey(word); return word.Skip(1).Any(char.IsUpper) || TechnicalCues.Contains(key) || lexicon.IsProtectedTerm(key,"en") || lexicon.Frequency(key,"en")>=5000;
    });
    private string? ContextualReplacement(string previous,string[] preceding)
    {
        if (previous != previous.ToLowerInvariant() || !ContextWords.TryGetValue(previous,out var expected) || lexicon.IsProtectedTerm(previous,"en") || ProtectsEnglishContext(preceding)) return null;
        return LayoutMap.Convert(previous,"en") == expected ? expected : null;
    }
    private string? PriorityReplacement(string current,string? previous,string source,string[] preceding,bool atBoundary)
    {
        if (source != "en" || current != current.ToLowerInvariant() || lexicon.IsPersonalWord(current,"en")) return null;
        var mapped=LayoutMap.Convert(current,"en");
        var exactYo=(current=="to\\" || current=="to`") && mapped=="ещё";
        var immediate=current.Length==1 && ImmediateLetters.Contains(mapped);
        var paired=current=="yt" && previous=="f" && mapped=="не";
        if (!(PriorityWords.Contains(mapped) || immediate) || !(current=="ye" || exactYo || immediate || paired || atBoundary) || ProtectsEnglishContext(preceding)) return null;
        return mapped;
    }
}
internal static class EnumerableCompat
{
    public static IEnumerable<T> TakeLastCompat<T>(this IEnumerable<T> values,int count)
    {
        var queue=new Queue<T>(); foreach(var value in values) { queue.Enqueue(value); if(queue.Count>count) queue.Dequeue(); } return queue;
    }
}
