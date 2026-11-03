using System;
using System.Collections.Generic;
using System.Linq;

namespace MacSwitcher.Core;
public static class LayoutMap
{
    private const string English = "qwertyuiop[]asdfghjkl;'zxcvbnm,./\\`QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?|~";
    private const string Russian = "йцукенгшщзхъфывапролджэячсмитьбю.ёёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,ЁЁ";
    private static readonly Dictionary<char, char> EnRu = Build(English, Russian);
    private static readonly Dictionary<char, char> RuEn = Build(Russian, English);
    static LayoutMap() { RuEn['ё'] = '`'; RuEn['Ё'] = '~'; }
    private static Dictionary<char, char> Build(string from, string to)
    {
        if (from.Length != to.Length) throw new InvalidOperationException("Layout map length mismatch");
        var map = new Dictionary<char, char>(); for (var i = 0; i < from.Length; i++) map[from[i]] = to[i]; return map;
    }
    public static string Convert(string text, string sourceLanguage)
    {
        if (text == null) throw new ArgumentNullException(nameof(text));
        var language = PredictionLexicon.LanguageCode(sourceLanguage);
        if (language != "ru" && language != "en") return text;
        return Map(text, language == "en" ? EnRu : RuEn);
    }
    public static string ConvertBidirectional(string text)
    {
        if (text == null) throw new ArgumentNullException(nameof(text));
        var hasCyrillic = text.Any(IsCyrillic); var hasLatin = text.Any(IsLatin);
        if (!hasCyrillic && !hasLatin) return text;
        if (hasCyrillic && hasLatin) return new string(text.Select(c => IsCyrillic(c) ? Lookup(RuEn, c) : IsLatin(c) ? Lookup(EnRu, c) : c).ToArray());
        return Map(text, hasCyrillic ? RuEn : EnRu);
    }
    internal static char MapChar(char c, string sourceLanguage) => Lookup(sourceLanguage == "en" ? EnRu : RuEn, c);
    private static string Map(string text, Dictionary<char,char> map) => new string(text.Select(c => Lookup(map,c)).ToArray());
    private static char Lookup(Dictionary<char,char> map, char c) => map.TryGetValue(c, out var value) ? value : c;
    internal static bool IsLatin(char c) => c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z';
    internal static bool IsCyrillic(char c) => c >= '\u0400' && c <= '\u04ff';
}
