using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text;

namespace MacSwitcher.Core;

public readonly struct PrefixEvidence
{
    public int MaximumFrequency { get; }
    public int Completions { get; }
    public PrefixEvidence(int maximumFrequency, int completions) { MaximumFrequency = maximumFrequency; Completions = completions; }
}

public sealed class PredictionLexicon : IDisposable
{
    private readonly Dictionary<string, TriggerIndex> triggers;
    private readonly Dictionary<string, BinaryLexicon> full;
    private readonly HashSet<string> protectedRu;
    private readonly HashSet<string> protectedEn;
    private readonly IPersonalLexicon personal;
    private bool disposed;
    private PredictionLexicon(Dictionary<string, TriggerIndex> triggers, Dictionary<string, BinaryLexicon> full,
        HashSet<string> protectedRu, HashSet<string> protectedEn, IPersonalLexicon personal)
    { this.triggers = triggers; this.full = full; this.protectedRu = protectedRu; this.protectedEn = protectedEn; this.personal = personal; }

    public static PredictionLexicon FromFixture(Dictionary<string, Dictionary<string,int>> triggerWords,
        Dictionary<string, Dictionary<string,int>>? fullWords = null,
        Dictionary<string, HashSet<string>>? spellingWords = null,
        Dictionary<string, HashSet<string>>? protectedTerms = null,
        IPersonalLexicon? personal = null)
    {
        // A fixture uses the same exact-query semantics and is never a production fallback.
        var binary = new Dictionary<string, BinaryLexicon>();
        foreach (var lang in new[] { "ru", "en" }) binary[lang] = BinaryLexicon.Fixture(
            fullWords != null && fullWords.TryGetValue(lang, out var fw) ? fw : new Dictionary<string,int>(),
            spellingWords != null && spellingWords.TryGetValue(lang, out var sw) ? sw : new HashSet<string>());
        return new PredictionLexicon(new Dictionary<string, TriggerIndex> {
            ["ru"] = new TriggerIndex(triggerWords.TryGetValue("ru", out var ru) ? ru : new Dictionary<string,int>()),
            ["en"] = new TriggerIndex(triggerWords.TryGetValue("en", out var en) ? en : new Dictionary<string,int>()) }, binary,
            NormalizeSet(protectedTerms != null && protectedTerms.TryGetValue("ru", out var pr) ? pr : Array.Empty<string>()),
            NormalizeSet(protectedTerms != null && protectedTerms.TryGetValue("en", out var pe) ? pe : Array.Empty<string>()),
            personal ?? new PersonalLexicon());
    }
    private static HashSet<string> NormalizeSet(IEnumerable<string> words) => new HashSet<string>(words.Select(Normalize), StringComparer.Ordinal);

    public static PredictionLexicon Load(string dataDirectory, IPersonalLexicon personal)
    {
        if (personal == null) throw new ArgumentNullException(nameof(personal));
        if (dataDirectory == null) throw new ArgumentNullException(nameof(dataDirectory));
        var manifestPath = Path.Combine(dataDirectory, "dictionary-manifest.json");
        if (new FileInfo(manifestPath).Length > 1024 * 1024) throw new InvalidDataException("Oversize manifest");
        Manifest manifest;
        using (var stream = File.OpenRead(manifestPath))
            manifest = (Manifest)(new DataContractJsonSerializer(typeof(Manifest), new DataContractJsonSerializerSettings { UseSimpleDictionaryFormat = true }).ReadObject(stream) ?? throw new InvalidDataException("Invalid manifest"));
        var required = new[] { "ru.tsv", "en.tsv", "protected-terms.tsv", "ru.lex", "en.lex" };
        foreach (var filename in required) VerifyFile(Path.Combine(dataDirectory, filename), filename, manifest);
        var binaries = new Dictionary<string, BinaryLexicon>();
        try
        {
            binaries["ru"] = new BinaryLexicon(Path.Combine(dataDirectory, "ru.lex"));
            binaries["en"] = new BinaryLexicon(Path.Combine(dataDirectory, "en.lex"));
            var terms = ReadTerms(Path.Combine(dataDirectory, "protected-terms.tsv"));
            return new PredictionLexicon(new Dictionary<string, TriggerIndex> {
                ["ru"] = new TriggerIndex(ReadTsv(Path.Combine(dataDirectory, "ru.tsv"))),
                ["en"] = new TriggerIndex(ReadTsv(Path.Combine(dataDirectory, "en.tsv"))) }, binaries,
                terms["ru"], terms["en"], personal);
        }
        catch { foreach (var file in binaries.Values) file.Dispose(); throw; }
    }
    private static void VerifyFile(string path, string name, Manifest manifest)
    {
        if (manifest.Files == null || !manifest.Files.TryGetValue(name, out var entry) || entry == null ||
            entry.Size < 0 || entry.Size > 512L * 1024 * 1024 || entry.Sha256 == null ||
            entry.Sha256.Length != 64 || entry.Sha256.Any(c => !Uri.IsHexDigit(c))) throw new InvalidDataException("Invalid manifest entry: " + name);
        var info = new FileInfo(path);
        if (info.Length != entry.Size) throw new InvalidDataException("Size mismatch: " + name);
        using var file = File.OpenRead(path);
        using var sha = SHA256.Create();
        var hash = BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
        if (!string.Equals(hash, entry.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Hash mismatch: " + name);
    }
    [DataContract] private sealed class Manifest
    { [DataMember(Name = "files")] public Dictionary<string, ManifestFile>? Files { get; set; } }
    [DataContract] private sealed class ManifestFile
    { [DataMember(Name = "sha256")] public string? Sha256 { get; set; } [DataMember(Name = "size")] public long Size { get; set; } }
    private static Dictionary<string,int> ReadTsv(string path)
    {
        var result = new Dictionary<string,int>(StringComparer.Ordinal); var row = 0;
        foreach (var line in File.ReadLines(path, new UTF8Encoding(false, true)))
        {
            row++; var parts = line.Split('\t');
            if (parts.Length != 2 || parts[0].Length == 0 || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var count) || count <= 0 || parts[0].Length > 160)
                throw new InvalidDataException("Invalid frequency row " + row);
            var key = Normalize(parts[0]); result[key] = Math.Max(result.TryGetValue(key, out var old) ? old : 0, count);
        }
        if (result.Count == 0) throw new InvalidDataException("Empty trigger list");
        return result;
    }
    private static Dictionary<string,HashSet<string>> ReadTerms(string path)
    {
        var result = new Dictionary<string,HashSet<string>> { ["ru"] = new HashSet<string>(StringComparer.Ordinal), ["en"] = new HashSet<string>(StringComparer.Ordinal) };
        foreach (var line in File.ReadLines(path, new UTF8Encoding(false, true)))
        {
            var parts = line.Split('\t');
            if (parts.Length != 3 || !result.ContainsKey(parts[0]) || parts[1].Length == 0 || parts[1].Length > 160 ||
                !(new[] { "brand", "name", "abbreviation", "word", "place" }).Contains(parts[2])) throw new InvalidDataException("Invalid protected term");
            result[parts[0]].Add(Normalize(parts[1]));
        }
        return result;
    }
    public int Frequency(string word, string language) => !disposed && triggers.TryGetValue(LanguageCode(language), out var index) ? index.Frequency(Normalize(word)) : 0;
    public int? FullFrequency(string word, string language) => !disposed && full.TryGetValue(LanguageCode(language), out var index) ? index.Lookup(Normalize(word))?.frequency : null;
    public bool? HasSupplementalSpelling(string word, string language)
    {
        if (disposed || !full.TryGetValue(LanguageCode(language), out var index)) return null;
        var record = index.Lookup(Normalize(word));
        return record == null ? null : (record.flags & 1) != 0;
    }
    public bool IsProtectedTerm(string word, string language)
    {
        var code = LanguageCode(language);
        return !disposed && ((code == "ru" ? protectedRu : protectedEn).Contains(Normalize(word)) ||
            personal.IsWord(word, code) || (full.TryGetValue(code, out var index) && (index.Lookup(Normalize(word))?.flags & 2) != 0));
    }
    public bool IsPersonalWord(string word, string language) => !disposed && personal.IsWord(word, language);
    public bool IsPhraseException(string original, string sourceLanguage) => !disposed && personal.IsPhraseException(original, sourceLanguage);
    public PrefixEvidence PrefixEvidence(string prefix, string language) => !disposed && triggers.TryGetValue(LanguageCode(language), out var index) ? index.Prefix(Normalize(prefix)) : default;
    public static string Normalize(string word) => (word ?? "").ToLowerInvariant().Normalize(NormalizationForm.FormC);
    public static string LanguageCode(string language) => (language ?? "").ToLowerInvariant().Substring(0, Math.Min(2, (language ?? "").Length));
    public void Dispose() { if (disposed) return; disposed = true; foreach (var file in full.Values) file.Dispose(); }

    private sealed class TriggerIndex
    {
        private readonly Dictionary<string,int> words;
        private readonly string[] keys;
        private readonly int[] tree;
        private readonly int leaves;
        public TriggerIndex(Dictionary<string,int> input)
        {
            words = new Dictionary<string,int>(StringComparer.Ordinal);
            foreach (var pair in input) if (pair.Value > 0) { var key = Normalize(pair.Key); words[key] = Math.Max(words.TryGetValue(key, out var old) ? old : 0, pair.Value); }
            keys = words.Keys.OrderBy(x => x, StringComparer.Ordinal).ToArray(); leaves = 1; while (leaves < keys.Length) leaves *= 2;
            tree = new int[leaves * 2]; for (var i = 0; i < keys.Length; i++) tree[leaves + i] = words[keys[i]];
            for (var i = leaves - 1; i > 0; i--) tree[i] = Math.Max(tree[i*2], tree[i*2+1]);
        }
        public int Frequency(string key) => words.TryGetValue(key, out var count) ? count : 0;
        public PrefixEvidence Prefix(string prefix)
        {
            if (prefix.Length == 0) return default;
            var lower = Lower(prefix); var upper = Lower(prefix + char.ConvertFromUtf32(0x10ffff)); var count = upper - lower;
            var max = 0; lower += leaves; upper += leaves;
            while (lower < upper) { if ((lower & 1) != 0) max = Math.Max(max, tree[lower++]); if ((upper & 1) != 0) max = Math.Max(max, tree[--upper]); lower /= 2; upper /= 2; }
            return new PrefixEvidence(max, count);
        }
        private int Lower(string key)
        {
            var lo = 0; var hi = keys.Length;
            while (lo < hi) { var mid = lo + (hi-lo)/2; if (string.CompareOrdinal(keys[mid], key) < 0) lo = mid+1; else hi = mid; }
            return lo;
        }
    }

    private sealed class LexRecord { public int frequency; public byte flags; public LexRecord(int frequency,byte flags) { this.frequency=frequency; this.flags=flags; } }
    private sealed class BinaryLexicon : IDisposable
    {
        private readonly FileStream? stream;
        private readonly object gate = new object();
        private readonly string[] firstWords = Array.Empty<string>();
        private readonly long[] offsets = Array.Empty<long>();
        private readonly int[] counts = Array.Empty<int>();
        private readonly Dictionary<string,LexRecord>? fixture;
        private bool failed;
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);
        private BinaryLexicon(Dictionary<string,LexRecord> fixture) { this.fixture = fixture; }
        public static BinaryLexicon Fixture(Dictionary<string,int> full, HashSet<string> spelling)
        {
            var data = new Dictionary<string,LexRecord>(StringComparer.Ordinal);
            foreach (var pair in full) data[Normalize(pair.Key)] = new LexRecord(pair.Value, 0);
            foreach (var word in spelling) { var key = Normalize(word); data[key] = new LexRecord(data.TryGetValue(key, out var old) ? old.frequency : 0, 1); }
            return new BinaryLexicon(data);
        }
        public BinaryLexicon(string path)
        {
            stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            try
            {
                using var reader = new BinaryReader(stream, StrictUtf8, true);
                if (stream.Length < 24 || stream.Length > 512L * 1024 * 1024 || Encoding.ASCII.GetString(reader.ReadBytes(8)) != "MSLEXW01" || reader.ReadUInt32() != 128)
                    throw new InvalidDataException("Invalid MSLEXW01 header");
                var blocks = reader.ReadUInt32(); var records = reader.ReadUInt64();
                if (blocks == 0 || blocks > 5_000_000 || records == 0 || records > blocks * 128UL || records < blocks) throw new InvalidDataException("Invalid MSLEXW01 counts");
                firstWords = new string[blocks]; offsets = new long[blocks]; counts = new int[blocks];
                ulong sum = 0; string? previous = null;
                for (var i = 0; i < blocks; i++)
                {
                    var word = ReadWord(reader); var offset = reader.ReadInt64(); var count = reader.ReadUInt32();
                    if (count == 0 || count > 128 || offset <= 0 || offset >= stream.Length || previous != null && string.CompareOrdinal(previous, word) >= 0)
                        throw new InvalidDataException("Invalid MSLEXW01 index");
                    firstWords[i] = word; offsets[i] = offset; counts[i] = (int)count; sum += count; previous = word;
                }
                if (sum != records || offsets[0] != stream.Position) throw new InvalidDataException("Invalid MSLEXW01 record offsets");
                previous = null;
                for (var i = 0; i < blocks; i++)
                {
                    if (offsets[i] != stream.Position) throw new InvalidDataException("Noncontinuous MSLEXW01 payload");
                    for (var j = 0; j < counts[i]; j++)
                    {
                        var word = ReadWord(reader); var frequency = reader.ReadInt32(); var flags = reader.ReadByte();
                        if (frequency < 0 || (flags & ~3) != 0 || previous != null && string.CompareOrdinal(previous, word) >= 0 || j == 0 && word != firstWords[i])
                            throw new InvalidDataException("Invalid MSLEXW01 record");
                        previous = word;
                    }
                }
                if (stream.Position != stream.Length) throw new InvalidDataException("Trailing MSLEXW01 payload");
            }
            catch { stream.Dispose(); throw; }
        }
        private static string ReadWord(BinaryReader reader)
        {
            var len = reader.ReadUInt16(); if (len == 0 || len > 160) throw new InvalidDataException("Invalid MSLEXW01 word length");
            var bytes = reader.ReadBytes(len); if (bytes.Length != len) throw new EndOfStreamException();
            var word = StrictUtf8.GetString(bytes);
            if (word != Normalize(word) || word.Any(char.IsControl)) throw new InvalidDataException("Invalid MSLEXW01 word");
            return word;
        }
        public LexRecord? Lookup(string key)
        {
            if (failed) return null;
            if (fixture != null) return fixture.TryGetValue(key, out var entry) ? entry : new LexRecord(0, 0);
            lock (gate)
            {
                try
                {
                    if (stream == null || firstWords.Length == 0) return null;
                    var lo = 0; var hi = firstWords.Length;
                    while (lo < hi) { var mid = lo + (hi-lo)/2; if (string.CompareOrdinal(firstWords[mid], key) <= 0) lo = mid+1; else hi = mid; }
                    var block = lo-1; if (block < 0) return new LexRecord(0, 0);
                    stream.Position = offsets[block]; using var reader = new BinaryReader(stream, StrictUtf8, true);
                    for (var i = 0; i < counts[block]; i++)
                    {
                        var word = ReadWord(reader); var frequency = reader.ReadInt32(); var flags = reader.ReadByte();
                        var comparison = string.CompareOrdinal(word, key);
                        if (comparison == 0) return new LexRecord(frequency, flags);
                        if (comparison > 0) break;
                    }
                    return new LexRecord(0, 0);
                }
                catch { failed = true; return null; }
            }
        }
        public void Dispose() => stream?.Dispose();
    }
}
