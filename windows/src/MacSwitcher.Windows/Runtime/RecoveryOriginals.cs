using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using MacSwitcher.Windows.Automation;

namespace MacSwitcher.Windows.Runtime
{
    [DataContract]
    internal sealed class RecoveryDocument
    {
        [DataMember(Name = "schema")] public int Schema = 1;
        [DataMember(Name = "savedUtc")] public string SavedUtc = "";
        [DataMember(Name = "originals")] public List<RecoveryEntry> Originals = new List<RecoveryEntry>();
    }

    [DataContract]
    internal sealed class RecoveryEntry
    {
        [DataMember(Name = "id")] public string Id = "";
        [DataMember(Name = "application")] public string Application = "";
        [DataMember(Name = "processId")] public uint ProcessId;
        [DataMember(Name = "threadId")] public uint ThreadId;
        [DataMember(Name = "foregroundHandle")] public long ForegroundHandle;
        [DataMember(Name = "focusHandle")] public long FocusHandle;
        [DataMember(Name = "runtimeId")] public int[] RuntimeId = Array.Empty<int>();
        [DataMember(Name = "selectionStart")] public int SelectionStart;
        [DataMember(Name = "selectionEnd")] public int SelectionEnd;
        [DataMember(Name = "sourceLanguage")] public string SourceLanguage = "";
        [DataMember(Name = "original")] public string Original = "";
        [DataMember(Name = "hasObservation")] public bool HasObservation;
        [DataMember(Name = "lastObserved")] public string LastObserved = "";
    }

    public sealed class RecoveryOriginalInfo
    {
        public string Id { get; }
        public string Label { get; }
        public string Original { get; }
        public uint ProcessId { get; }
        public int SelectionStart { get; }
        public int SelectionEnd { get; }
        public string SourceLanguage { get; }
        public bool HasObservation { get; }
        internal string LastObserved { get; }
        internal long ForegroundHandle { get; }
        internal long FocusHandle { get; }
        internal uint ThreadId { get; }
        internal int[] RuntimeId { get; }

        internal RecoveryOriginalInfo(RecoveryEntry entry)
        {
            Id = entry.Id; Label = entry.Application + " · исходник " + entry.Id.Substring(0, 4);
            Original = entry.Original; ProcessId = entry.ProcessId;
            SelectionStart = entry.SelectionStart; SelectionEnd = entry.SelectionEnd;
            SourceLanguage = entry.SourceLanguage;
            HasObservation = entry.HasObservation; LastObserved = entry.LastObserved;
            ForegroundHandle = entry.ForegroundHandle; FocusHandle = entry.FocusHandle;
            ThreadId = entry.ThreadId; RuntimeId = (int[])entry.RuntimeId.Clone();
        }

        internal bool Matches(FieldSnapshot field)
        {
            return field.ProcessId == ProcessId && field.ThreadId == ThreadId &&
                field.Foreground.ToInt64() == ForegroundHandle && field.Focus.ToInt64() == FocusHandle &&
                field.RuntimeId.SequenceEqual(RuntimeId);
        }

        internal bool MatchesLastObserved(FieldSnapshot field)
        { return HasObservation && Matches(field) && field.Value == LastObserved; }
    }

    internal sealed class RecoveryOriginals
    {
        private const int MaxFields = 8;
        private const int MaxTotalUtf16 = 1048576;
        private readonly object gate = new object();
        private readonly Dictionary<string, RecoveryEntry> entries = new Dictionary<string, RecoveryEntry>(StringComparer.Ordinal);
        private int total;

        internal int Count { get { lock (gate) return entries.Count; } }

        internal IReadOnlyList<RecoveryOriginalInfo> Snapshot()
        {
            lock (gate) return entries.Values.Select(x => new RecoveryOriginalInfo(x)).ToArray();
        }

        internal RecoveryOriginalInfo? FindForField(FieldSnapshot field)
        {
            lock (gate)
            {
                RecoveryEntry? entry;
                return entries.TryGetValue(Key(field), out entry) ? new RecoveryOriginalInfo(entry) : null;
            }
        }

        internal void RemoveConfirmed(string id)
        {
            lock (gate)
            {
                var match = entries.FirstOrDefault(x => x.Value.Id == id);
                if (match.Value == null) return;
                total -= match.Value.Original.Length + match.Value.LastObserved.Length;
                entries.Remove(match.Key);
            }
        }

        internal bool Contains(FieldSnapshot? field)
        {
            if (field == null) return false;
            lock (gate) return entries.ContainsKey(Key(field));
        }

        private static string Key(FieldSnapshot field)
        {
            return field.ProcessId + ":" + field.Focus.ToInt64() + ":" + string.Join(".", field.RuntimeId);
        }

        internal bool CanRetain(FieldSnapshot? field)
        {
            if (field == null || field.Value == null) return false;
            lock (gate)
            {
                var key = Key(field);
                return entries.ContainsKey(key) || entries.Count < MaxFields &&
                    total + field.Value.Length + 32768 <= MaxTotalUtf16;
            }
        }

        internal bool Add(FieldSnapshot? field, string sourceLanguage = "", FieldSnapshot? observed = null)
        {
            if (field == null || !CanRetain(field)) return false;
            lock (gate)
            {
                var key = Key(field);
                if (entries.ContainsKey(key)) return true; // First original is the recovery source.
                string application;
                try { application = Process.GetProcessById((int)field.ProcessId).ProcessName; }
                catch { application = "Приложение"; }
                bool hasObservation = observed != null && field.SameIdentity(observed);
                entries[key] = new RecoveryEntry { Id = Guid.NewGuid().ToString("N"),
                    Application = application, ProcessId = field.ProcessId, ThreadId = field.ThreadId,
                    ForegroundHandle = field.Foreground.ToInt64(), FocusHandle = field.Focus.ToInt64(),
                    RuntimeId = (int[])field.RuntimeId.Clone(), SelectionStart = field.SelectionStart,
                    SelectionEnd = field.SelectionEnd, SourceLanguage = sourceLanguage, Original = field.Value,
                    HasObservation = hasObservation,
                    LastObserved = hasObservation ? observed!.Value : "" };
                total += field.Value.Length + (hasObservation ? observed!.Value.Length : 0);
                return true;
            }
        }

        internal string Export(string directory)
        {
            if (string.IsNullOrWhiteSpace(directory)) throw new ArgumentException("Choose a local directory.", nameof(directory));
            RecoveryDocument document;
            lock (gate)
            {
                if (entries.Count == 0) throw new InvalidOperationException("No recovery originals are pending.");
                document = new RecoveryDocument { SavedUtc = DateTime.UtcNow.ToString("o"),
                    Originals = entries.Values.Select(x => new RecoveryEntry { Id = x.Id, Application = x.Application,
                        ProcessId = x.ProcessId, ThreadId = x.ThreadId,
                        ForegroundHandle = x.ForegroundHandle, FocusHandle = x.FocusHandle,
                        RuntimeId = (int[])x.RuntimeId.Clone(), SelectionStart = x.SelectionStart,
                        SelectionEnd = x.SelectionEnd, SourceLanguage = x.SourceLanguage,
                        Original = x.Original, HasObservation = x.HasObservation,
                        LastObserved = x.LastObserved }).ToList() };
            }
            var destination = Path.Combine(Path.GetFullPath(directory), "MacSwitcherWindows-Recovery-" + Guid.NewGuid().ToString("N"));
            var identity = WindowsIdentity.GetCurrent().User;
            if (identity == null) throw new UnauthorizedAccessException("Current user identity is unavailable.");
            var acl = new DirectorySecurity();
            acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new FileSystemAccessRule(identity, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None,
                AccessControlType.Allow));
            Directory.CreateDirectory(destination, acl);
            var existingAcl = Directory.GetAccessControl(destination);
            if (!existingAcl.AreAccessRulesProtected) throw new UnauthorizedAccessException("Recovery directory is not private.");
            var filename = "recovery-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".json";
            var final = Path.Combine(destination, filename);
            var temporary = final + ".tmp";
            try
            {
                byte[] expectedBytes;
                using (var memory = new MemoryStream())
                {
                    new DataContractJsonSerializer(typeof(RecoveryDocument)).WriteObject(memory, document);
                    if (memory.Length > 8 * 1024 * 1024) throw new IOException("Recovery size bound exceeded.");
                    expectedBytes = memory.ToArray();
                }
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                    FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    stream.Write(expectedBytes, 0, expectedBytes.Length);
                    stream.Flush(true);
                }
                var actualBytes = File.ReadAllBytes(temporary);
                if (actualBytes.Length != expectedBytes.Length) throw new IOException("Recovery read-back failed.");
                using (var sha = SHA256.Create())
                {
                    var before = sha.ComputeHash(expectedBytes);
                    var after = sha.ComputeHash(actualBytes);
                    if (!before.SequenceEqual(after)) throw new IOException("Recovery read-back failed.");
                }
                using (var stream = File.OpenRead(temporary))
                {
                    var read = (RecoveryDocument)new DataContractJsonSerializer(typeof(RecoveryDocument)).ReadObject(stream);
                    if (read == null || read.Schema != 1 || read.Originals == null ||
                        read.Originals.Count != document.Originals.Count ||
                        !read.Originals.Select(x => x.Id + ":" + x.Original + ":" + x.HasObservation + ":" + x.LastObserved)
                            .SequenceEqual(document.Originals.Select(x => x.Id + ":" + x.Original + ":" + x.HasObservation + ":" + x.LastObserved)))
                        throw new IOException("Recovery read-back failed.");
                }
                File.Move(temporary, final);
                return final;
            }
            catch
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
                throw;
            }
        }
    }
}
