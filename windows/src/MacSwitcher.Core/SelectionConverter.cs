using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace MacSwitcher.Core;

public static class SelectionConverter
{
    private enum Script { Other, Latin, Cyrillic, Mixed }
    private enum Decision { Keep, Flip, Unresolved, Unavailable }
    private sealed class Token { public string Text = ""; public bool Word; public Decision Decision; public string Converted = ""; public Script Target; }
    private static readonly HashSet<string> RuShort = Set("не ты на он мы вы да но за бы же из ну по то от их ее её со ли ни об ей во им ко те та уж ок эй");
    private static readonly HashSet<string> EnShort = Set("to it of is in we me he my on do no be so go if up at as an us or by am ok hi oh ah um mr ya vs dj kb jr bp ye ds");
    private static readonly HashSet<char> RuOne = new HashSet<char>("явскоу аи".Where(c => c != ' '));
    private static readonly HashSet<char> EnOne = new HashSet<char>("ai");
    private static HashSet<string> Set(string text) => new HashSet<string>(text.Split(' '), StringComparer.Ordinal);

    public static string Convert(string text, PredictionLexicon lexicon, bool smart, string sourceLanguage, bool russianPriority = false)
    {
        if (text == null) throw new ArgumentNullException(nameof(text));
        if (lexicon == null) throw new ArgumentNullException(nameof(lexicon));
        var source = PredictionLexicon.LanguageCode(sourceLanguage);
        if (source != "en" && source != "ru") return text;
        if (!smart) return LayoutMap.ConvertBidirectional(text);
        if (text.Length > 4096 || text.IndexOf('\0') >= 0) return text;
        if (russianPriority && source == "en")
        {
            var exact = Tokenize(text); var words = exact.Where(t => t.Word).ToArray();
            if (words.Length > 0 && words.All(t => t.Text == "f" || t.Text == "to\\" || t.Text == "to`"))
                return string.Concat(exact.Select(t => t.Word ? t.Text == "f" ? "а" : "ещё" : t.Text));
        }
        var tokens = Tokenize(text); var flippedRu = 0; var flippedEn = 0;
        foreach (var token in tokens)
        {
            if (!token.Word) continue;
            Decide(token, lexicon);
            if (token.Decision == Decision.Unavailable) return text;
            if (token.Decision == Decision.Flip)
            {
                if (token.Target == Script.Cyrillic) flippedRu++; else flippedEn++;
            }
        }
        var signal = flippedRu > 0 && flippedEn == 0 ? Script.Cyrillic : flippedEn > 0 && flippedRu == 0 ? Script.Latin : Script.Other;
        var result = new StringBuilder(text.Length);
        foreach (var token in tokens)
        {
            if (token.Decision == Decision.Flip) result.Append(token.Converted);
            else if (token.Decision == Decision.Unresolved) result.Append(SignalFlip(token.Text, signal));
            else result.Append(token.Text);
        }
        return result.ToString();
    }
    private static void Decide(Token token, PredictionLexicon lexicon)
    {
        var word = token.Text; var core = LetterCore(word); var script = Dominant(core);
        if (core.Length == 0 || script != Script.Latin && script != Script.Cyrillic || IsAllCaps(core) || LooksLikeCode(core)) { token.Decision=Decision.Keep; return; }
        var source = script == Script.Latin ? "en" : "ru"; var target = source == "en" ? "ru" : "en";
        token.Target = script == Script.Latin ? Script.Cyrillic : Script.Latin;
        if (core.Length == 1) { token.Decision=Decision.Unresolved; return; }
        if (core.Length == 2)
        {
            if ((source == "en" ? EnShort : RuShort).Contains(core.ToLowerInvariant())) { token.Decision=Decision.Keep; return; }
            var flipped = LayoutMap.Convert(word,source); var flippedCore=LetterCore(flipped);
            if (flippedCore.Length==2 && (target=="en" ? EnShort : RuShort).Contains(flippedCore.ToLowerInvariant())) { token.Decision=Decision.Flip; token.Converted=flipped; return; }
            token.Decision=Decision.Unresolved; return;
        }
        var sourceKnown=Known(core,source,lexicon); if (!sourceKnown.HasValue) { token.Decision=Decision.Unavailable; return; }
        if (sourceKnown.Value) { token.Decision=Decision.Keep; return; }
        var whole=LayoutMap.Convert(word,source); var wholeCore=LetterCore(whole);
        if (wholeCore.Length>=2 && wholeCore.All(char.IsLetter))
        {
            var targetKnown=Known(wholeCore,target,lexicon); if (!targetKnown.HasValue) { token.Decision=Decision.Unavailable; return; }
            if (targetKnown.Value) { token.Decision=Decision.Flip; token.Converted=whole; return; }
        }
        var cut=word.Length; while (cut>0 && !char.IsLetter(word[cut-1])) cut--;
        if (cut>0 && cut<word.Length)
        {
            var body=LayoutMap.Convert(word.Substring(0,cut),source); var bodyCore=LetterCore(body);
            if (bodyCore.Length>=2 && bodyCore.All(char.IsLetter))
            {
                var targetKnown=Known(bodyCore,target,lexicon); if (!targetKnown.HasValue) { token.Decision=Decision.Unavailable; return; }
                if (targetKnown.Value) { token.Decision=Decision.Flip; token.Converted=body+word.Substring(cut); return; }
            }
        }
        token.Decision=Decision.Unresolved;
    }
    private static bool? Known(string word,string language,PredictionLexicon lexicon)
    {
        if (lexicon.IsProtectedTerm(word,language) || lexicon.Frequency(word,language)>0) return true;
        var full=lexicon.FullFrequency(word,language); var spelling=lexicon.HasSupplementalSpelling(word,language);
        if (!full.HasValue || !spelling.HasValue) return null;
        return full.Value>0 || spelling.Value;
    }
    private static string SignalFlip(string word,Script target)
    {
        if (target==Script.Other) return word;
        var start=0; while(start<word.Length && !char.IsLetter(word[start])) start++;
        var end=word.Length; while(end>start && !char.IsLetter(word[end-1])) end--;
        var core=word.Substring(start,end-start);
        if (core.Length==0 || core.Length>2 || Dominant(core)==target) return word;
        var converted=LayoutMap.Convert(core,target==Script.Cyrillic?"en":"ru");
        if (core.Length==1 && (converted.Length!=1 || !(target==Script.Cyrillic?RuOne:EnOne).Contains(char.ToLowerInvariant(converted[0])))) return word;
        return word.Substring(0,start)+converted+word.Substring(end);
    }
    private static string LetterCore(string value) => TrimNonLetters(value);
    private static string TrimNonLetters(string value) { var start=0; while(start<value.Length&&!char.IsLetter(value[start]))start++; var end=value.Length; while(end>start&&!char.IsLetter(value[end-1]))end--; return value.Substring(start,end-start); }
    private static Script Dominant(string value)
    {
        var latin=value.Any(LayoutMap.IsLatin); var cyr=value.Any(LayoutMap.IsCyrillic);
        return latin&&cyr?Script.Mixed:latin?Script.Latin:cyr?Script.Cyrillic:Script.Other;
    }
    private static bool IsAllCaps(string value) => value.Count(char.IsLetter)>1 && value.Where(char.IsLetter).All(char.IsUpper);
    private static bool LooksLikeCode(string value) => value.Contains('_') || value.Skip(1).Any(char.IsUpper) || value.Any(char.IsDigit);
    private static List<Token> Tokenize(string text)
    {
        var tokens=new List<Token>(); if(text.Length==0)return tokens;
        var start=0; var word=!char.IsWhiteSpace(text[0])&&text[0]!='-';
        for(var i=1;i<text.Length;i++)
        {
            var next=!char.IsWhiteSpace(text[i])&&text[i]!='-'; if(next==word)continue;
            tokens.Add(new Token{Text=text.Substring(start,i-start),Word=word}); start=i; word=next;
        }
        tokens.Add(new Token{Text=text.Substring(start),Word=word}); return tokens;
    }
}
