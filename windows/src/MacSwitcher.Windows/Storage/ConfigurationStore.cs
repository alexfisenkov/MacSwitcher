using System;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;
using MacSwitcher.Core;

namespace MacSwitcher.Windows.Storage;

public sealed class ConfigurationStore
{
    private const int CurrentSchema = 1;
    private const int MaximumBytes = 1024 * 1024;
    private readonly string directory;
    private readonly string settingsPath;
    private readonly string personalPath;
    private bool settingsWritable = true;
    private bool personalWritable = true;

    public AppSettings Settings { get; private set; } = new AppSettings();
    public PersonalLexicon Personal { get; } = new PersonalLexicon();
    public AdaptiveRulesStore Adaptive { get; }
    public bool LearningExplanationPending { get; private set; }
    public bool CanSaveSettings => settingsWritable;
    public bool CanSavePersonal => personalWritable;
    public string SettingsProblem { get; private set; } = "";
    public string PersonalProblem { get; private set; } = "";

    public ConfigurationStore(string directory)
    {
        this.directory = directory ?? throw new ArgumentNullException(nameof(directory));
        settingsPath = Path.Combine(directory, "settings.json");
        personalPath = Path.Combine(directory, "personal.json");
        Adaptive = new AdaptiveRulesStore(directory);
    }

    public void Load()
    {
        var settingsDocument = LoadFile(settingsPath, new SettingsDocument(), out var sWritable, out var sProblem);
        Settings = settingsDocument;
        LearningExplanationPending = sWritable && settingsDocument.RememberCorrections == null;
        settingsWritable = sWritable;
        SettingsProblem = sProblem;
        try { Settings.Validate(); }
        catch
        {
            Settings = SafePausedSettings();
            settingsWritable = false;
            SettingsProblem = "Файл настроек содержит недопустимые значения. Он сохранён без изменений.";
        }

        var document = LoadFile(personalPath, new PersonalDocument(), out var pWritable, out var pProblem);
        personalWritable = pWritable;
        PersonalProblem = pProblem;
        try { Personal.ReplaceSnapshot(ToSnapshot(document)); }
        catch
        {
            personalWritable = false;
            PersonalProblem = "Личный словарь повреждён или содержит недопустимые записи. Файл сохранён без изменений.";
        }

        if (!settingsWritable || !personalWritable)
        {
            Settings.Enabled = false;
            Settings.AutomaticCorrection = false;
        }
        Adaptive.Load(Settings.RememberCorrections);
    }

    public void SaveSettings(AppSettings settings)
    {
        if (!settingsWritable) throw new InvalidOperationException(SettingsProblem);
        if (settings == null) throw new ArgumentNullException(nameof(settings));
        if (!personalWritable)
        {
            settings.Enabled = false;
            settings.AutomaticCorrection = false;
        }
        settings.Validate();
        var previousStartSetting = Settings.StartWithWindows;
        var changedStartup = previousStartSetting != settings.StartWithWindows;
        if (changedStartup) UpdateLoginRegistration(settings.StartWithWindows);
        try { SaveFile(settingsPath, new SettingsDocument(settings)); }
        catch
        {
            if (changedStartup)
            {
                try { UpdateLoginRegistration(previousStartSetting); } catch { }
            }
            throw;
        }
        Settings = Copy(settings);
        Adaptive.SetEnabled(Settings.RememberCorrections);
        LearningExplanationPending = false;
    }

    public void AddWord(string value, string language) => ChangePersonal(copy => copy.AddWord(value, language));
    public void RemoveWord(string value, string language) => ChangePersonal(copy => copy.RemoveWord(value, language));
    public void AddException(string value, string language) => ChangePersonal(copy => copy.AddPhraseException(value, language));
    public void RemoveException(string value, string language) => ChangePersonal(copy => copy.RemovePhraseException(value, language));

    public void ImportPersonal(string path)
    {
        EnsurePersonalWritable();
        var imported = ReadDocument<PersonalDocument>(path);
        if (imported.Schema != CurrentSchema) throw new SerializationException("Файл словаря создан в неподдерживаемом формате.");
        var snapshot = ToSnapshot(imported);
        SavePersonalSnapshot(snapshot);
        Personal.ReplaceSnapshot(snapshot);
    }

    public void ExportPersonal(string path)
    {
        EnsurePersonalWritable();
        SaveFile(path, FromSnapshot(Personal.ExportSnapshot()));
    }

    public string[] RecoverUnreadableFiles()
    {
        var preserved = new System.Collections.Generic.List<string>();
        var suffix = ".recovery-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N");
        if (!settingsWritable)
        {
            if (File.Exists(settingsPath))
            {
                var destination = settingsPath + suffix + ".json";
                File.Move(settingsPath, destination);
                preserved.Add(destination);
            }
            UpdateLoginRegistration(false);
            Settings = SafePausedSettings();
            settingsWritable = true;
            SettingsProblem = "";
        }
        if (!personalWritable)
        {
            if (File.Exists(personalPath))
            {
                var destination = personalPath + suffix + ".json";
                File.Move(personalPath, destination);
                preserved.Add(destination);
            }
            Personal.ReplaceSnapshot(new PersonalLexiconSnapshot());
            personalWritable = true;
            PersonalProblem = "";
        }
        preserved.AddRange(Adaptive.RecoverUnreadable(Settings.RememberCorrections));
        return preserved.ToArray();
    }

    private void ChangePersonal(Action<PersonalLexicon> change)
    {
        EnsurePersonalWritable();
        var next = new PersonalLexicon();
        next.ReplaceSnapshot(Personal.ExportSnapshot());
        change(next);
        var snapshot = next.ExportSnapshot();
        SavePersonalSnapshot(snapshot);
        Personal.ReplaceSnapshot(snapshot);
    }

    private void SavePersonalSnapshot(PersonalLexiconSnapshot snapshot) => SaveFile(personalPath, FromSnapshot(snapshot));

    private void EnsurePersonalWritable()
    {
        if (!personalWritable) throw new InvalidOperationException(PersonalProblem);
    }

    private static T LoadFile<T>(string path, T defaults, out bool writable, out string problem) where T : class
    {
        writable = true;
        problem = "";
        if (!File.Exists(path)) return defaults;
        try
        {
            var loaded = ReadDocument<T>(path);
            var version = loaded is SettingsDocument settings ? settings.Schema : ((PersonalDocument)(object)loaded).Schema;
            if (version > CurrentSchema) throw new FutureSchemaException();
            if (version != CurrentSchema) throw new SerializationException("Unsupported schema");
            return loaded;
        }
        catch (FutureSchemaException)
        {
            writable = false;
            problem = "Файл создан более новой версией приложения. Он открыт только для чтения и не будет заменён.";
            return defaults;
        }
        catch
        {
            writable = false;
            problem = "Не удалось прочитать файл. Он сохранён без изменений; новые данные в этот файл не записываются.";
            return defaults;
        }
    }

    private static T ReadDocument<T>(string path) where T : class
    {
        var info = new FileInfo(path);
        if (info.Length > MaximumBytes) throw new SerializationException("File exceeds the size limit");
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var serializer = new DataContractJsonSerializer(typeof(T), new DataContractJsonSerializerSettings { MaxItemsInObjectGraph = 50000 });
        return (T)(serializer.ReadObject(stream) ?? throw new SerializationException("Empty file"));
    }

    private static void SaveFile<T>(string path, T document) where T : class
    {
        var parent = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(parent);
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        var rollback = path + ".rollback-" + Guid.NewGuid().ToString("N");
        var existed = File.Exists(path);
        var committed = false;
        try
        {
            var serializer = new DataContractJsonSerializer(typeof(T), new DataContractJsonSerializerSettings { MaxItemsInObjectGraph = 50000 });
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                serializer.WriteObject(stream, document);
                stream.Flush(true);
                if (stream.Length > MaximumBytes) throw new InvalidDataException("Local data exceeds the 1 MiB limit.");
            }
            var beforeHash = HashFile(temporary);
            var readBack = ReadDocument<T>(temporary);
            ValidateReadBack(readBack);
            if (existed) File.Replace(temporary, path, rollback);
            else File.Move(temporary, path);
            var persisted = ReadDocument<T>(path);
            ValidateReadBack(persisted);
            var afterHash = HashFile(path);
            if (!String.Equals(beforeHash, afterHash, StringComparison.Ordinal)) throw new IOException("Local data read-back hash mismatch.");
            committed = true;
            if (File.Exists(rollback)) File.Delete(rollback);
        }
        catch
        {
            if (existed && File.Exists(rollback))
            {
                try { File.Replace(rollback, path, null); } catch { }
            }
            else if (!existed && File.Exists(path))
            {
                try { File.Delete(path); } catch { }
            }
            throw;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            if (committed && File.Exists(rollback)) File.Delete(rollback);
        }
    }

    private static void ValidateReadBack<T>(T document) where T : class
    {
        if (document is SettingsDocument settings)
        {
            if (settings.Schema != CurrentSchema) throw new SerializationException("Unsupported settings schema");
            AppSettings value = settings;
            value.Validate();
        }
        else if (document is PersonalDocument personal)
        {
            if (personal.Schema != CurrentSchema) throw new SerializationException("Unsupported personal data schema");
            var validated = new PersonalLexicon();
            validated.ReplaceSnapshot(ToSnapshot(personal));
        }
        else throw new SerializationException("Unexpected local data type");
    }

    private static string HashFile(string path)
    {
        using var sha = SHA256.Create();
        using var stream = File.OpenRead(path);
        return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
    }

    private static AppSettings SafePausedSettings() => new AppSettings { Enabled = false, AutomaticCorrection = false, StartWithWindows = false };

    private static PersonalLexiconSnapshot ToSnapshot(PersonalDocument source) => new PersonalLexiconSnapshot
    {
        RussianWords = source.RussianWords ?? Array.Empty<string>(),
        EnglishWords = source.EnglishWords ?? Array.Empty<string>(),
        RussianPhraseExceptions = source.RussianPhraseExceptions ?? Array.Empty<string>(),
        EnglishPhraseExceptions = source.EnglishPhraseExceptions ?? Array.Empty<string>()
    };

    private static PersonalDocument FromSnapshot(PersonalLexiconSnapshot snapshot) => new PersonalDocument
    {
        RussianWords = snapshot.RussianWords,
        EnglishWords = snapshot.EnglishWords,
        RussianPhraseExceptions = snapshot.RussianPhraseExceptions,
        EnglishPhraseExceptions = snapshot.EnglishPhraseExceptions
    };

    private static AppSettings Copy(AppSettings value) => new AppSettings
    {
        Enabled = value.Enabled,
        AutomaticCorrection = value.AutomaticCorrection,
        RememberCorrections = value.RememberCorrections,
        RussianPriority = value.RussianPriority,
        StartWithWindows = value.StartWithWindows,
        DoubleShiftMilliseconds = value.DoubleShiftMilliseconds,
        ExcludedApplications = value.ExcludedApplications.ToArray(),
        AlwaysConvertWords = value.AlwaysConvertWords.ToArray(),
        SmartSelection = value.SmartSelection
    };

    private static void UpdateLoginRegistration(bool enabled)
    {
        const string keyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        using var key = Registry.CurrentUser.CreateSubKey(keyPath, true);
        if (key == null) throw new InvalidOperationException("Не удалось сохранить запуск вместе с Windows.");
        if (enabled) key.SetValue("MacSwitcher", "\"" + System.Reflection.Assembly.GetEntryAssembly()!.Location + "\"");
        else key.DeleteValue("MacSwitcher", false);
    }

    [DataContract]
    private sealed class SettingsDocument
    {
        [DataMember(Order = 1)] public int Schema { get; set; } = CurrentSchema;
        [DataMember(Order = 2)] public bool Enabled { get; set; } = true;
        [DataMember(Order = 3)] public bool AutomaticCorrection { get; set; } = true;
        [DataMember(Order = 4)] public bool RussianPriority { get; set; } = true;
        [DataMember(Order = 5)] public bool StartWithWindows { get; set; }
        [DataMember(Order = 6)] public int DoubleShiftMilliseconds { get; set; } = 180;
        [DataMember(Order = 7)] public string[] ExcludedApplications { get; set; } = Array.Empty<string>();
        [DataMember(Order = 8)] public string[] AlwaysConvertWords { get; set; } = Array.Empty<string>();
        [DataMember(Order = 9)] public bool SmartSelection { get; set; }
        [DataMember(Order = 10, EmitDefaultValue = false)] public bool? RememberCorrections { get; set; }
        public SettingsDocument() { }
        public SettingsDocument(AppSettings value)
        {
            Enabled = value.Enabled; AutomaticCorrection = value.AutomaticCorrection; RussianPriority = value.RussianPriority;
            StartWithWindows = value.StartWithWindows; DoubleShiftMilliseconds = value.DoubleShiftMilliseconds;
            ExcludedApplications = value.ExcludedApplications.ToArray();
            AlwaysConvertWords = value.AlwaysConvertWords.ToArray();
            SmartSelection = value.SmartSelection;
            RememberCorrections = value.RememberCorrections;
        }
        public static implicit operator AppSettings(SettingsDocument value) => new AppSettings { Enabled = value.Enabled, AutomaticCorrection = value.AutomaticCorrection, RussianPriority = value.RussianPriority, StartWithWindows = value.StartWithWindows, DoubleShiftMilliseconds = value.DoubleShiftMilliseconds, ExcludedApplications = value.ExcludedApplications, AlwaysConvertWords = value.AlwaysConvertWords ?? Array.Empty<string>(), SmartSelection = value.SmartSelection, RememberCorrections = value.RememberCorrections ?? true };
    }

    [DataContract]
    private sealed class PersonalDocument
    {
        [DataMember(Order = 1)] public int Schema { get; set; } = CurrentSchema;
        [DataMember(Order = 2)] public string[] RussianWords { get; set; } = Array.Empty<string>();
        [DataMember(Order = 3)] public string[] EnglishWords { get; set; } = Array.Empty<string>();
        [DataMember(Order = 4)] public string[] RussianPhraseExceptions { get; set; } = Array.Empty<string>();
        [DataMember(Order = 5)] public string[] EnglishPhraseExceptions { get; set; } = Array.Empty<string>();
    }

    private sealed class FutureSchemaException : Exception { }
}
