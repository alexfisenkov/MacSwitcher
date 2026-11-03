# Windows contracts v1

## Build

SDK10.0.403. Core project target `net462;net10.0`, app `net462` AnyCPU, tests `net10.0`; Microsoft.NETFramework.ReferenceAssemblies.net462 1.0.3 build-only. No other NuGet dependencies expected. C# plain BCL API available net462; no nativeSQLite dependency.

## Core names

Namespace `MacSwitcher.Core`; ниже приведены реализованные интерфейсы.

- AppSettings: bool Enabled=true, AutomaticCorrection=true, RussianPriority=true, StartWithWindows=false, SmartSelection=false; int DoubleShiftMilliseconds=180; string[] ExcludedApplications=[], AlwaysConvertWords=[]; validate range80..400.
- IPersonalLexicon: bool IsWord(string word,string language); bool IsPhraseException(string original,string sourceLanguage). PersonalLexicon mutable thread-safe in-memory implementation exposes snapshot/replace arrays for store, not automatic learning.
- PredictionLexicon.Load(string dataDirectory, IPersonalLexicon personal); IDisposable; Frequency(word,language), FullFrequency(nullable on failedread), HasSupplementalSpelling(nullable), IsProtectedTerm, PrefixEvidence.
- PredictionEngine(PredictionLexicon).Evaluate(string suffix,string sourceLanguage,bool atBoundary=false,string[] precedingWords=null,bool russianPriority=false,IEnumerable<string> alwaysConvertWords=null) returns nullable PredictionProposal {OriginalSuffix,ReplacementSuffix,TargetLanguage,Reason}. Проверки включают все 495 общих gold-примеров и дополнения alpha.24.
- LayoutMap.Convert(string text,string sourceLanguage), ConvertBidirectional(stringtext) (language inferred scriptperchar); ShiftGesture Press/Release/Interrupt with monotonicmilliseconds and captured LayoutDirection {SourceId,TargetId}, twoactions SwitchLayout/Convert. Defaults250mshold/180msdouble.
- SmartSelection сохраняет правильные/защищённые слова; false задаёт явное полное преобразование. `SelectionConverter.Convert(string text,PredictionLexicon lexicon,bool smart,string sourceLanguage,bool russianPriority=false)`.

## Dictionary binary MSLEXW01

Each language has `<lang>.lex` generated from existing full+spelling+protected. Little-endian header: magic8bytesASCII MSLEXW01; uint32 stride128; uint32 blockCount; uint64 recordCount. Index entries: ushort utf8firstWordByteLength, wordbytes, int64 absoluteDataOffset, uint32 blockRecordCount. Records perblock: ushort wordByteLength<=160, wordbytesstrictUTF8, int32 fullFrequency>=0, byte flags (1=normative spelling,2=protectedterm); fullfrequency0meansknownabsence. SortedbinaryUTF8ordinal words. No overflow/varints. Sparseindex fully memoryloaded, each query reads<=128boundedrecords atknownoffset; boundedoptionalpagecache. Corruptheader/index/payload/hash gives unavailable/exceptionfailclosed.

Data folder also ru.tsv/en.tsv (top200k), protected-terms.tsv, prediction-benchmark.json, licences, dictionary-manifest.json with SHA256/size/counts/source hashes. Generated data not git tracked. Builder из корня: `python3 windows/scripts/build-data.py --output windows/data`.

## Runtime bridge for UI

Namespace `MacSwitcher.Windows.Runtime`. `WindowsSwitcherRuntime(AppSettings settings, IPersonalLexicon personal, string dataDirectory)` implements IDisposable. Public `Start()`, `Stop()`, `ApplySettings(AppSettings)`, `bool TrySwitchLayout(string language)`, `bool HasRecoveryOriginals`, `string ExportRecovery(string directory)`, `GetRecoveryOriginalsSnapshot()`, `bool TryRestoreRecovery(string id)`, `bool UndoLastCorrection()`. Сохранение исключения выполняет UI после явного выбора, через `CorrectionUndone`. Events `Action<RuntimeStatus> StatusChanged`, `Action<CorrectionNotice> CorrectionApplied`, `Action<CorrectionNotice> CorrectionUndone`; RuntimeStatus properties Message, Ready, NeedsAdministrator (humantext no textpayload), CorrectionNotice Original/Replacement/SourceLanguage (RAMonly). These events are never logged.

`ConfigurationStore(string directory)` exposes `AppSettings Settings`, `PersonalLexicon Personal`, `Load()`, `SaveSettings(AppSettings)`, word/exception operations Import/Export/Add/Delete. `SwitcherContext(WindowsSwitcherRuntime runtime, ConfigurationStore store, bool showSettings)` extends ApplicationContext. Program загружает store, создаёт runtime с `AppDomain.CurrentDomain.BaseDirectory/data` и UI-контекст; контекст запускает обработку, Program выполняет `Application.Run(context)`. При выходе UI сначала предлагает сохранить recovery-исходники; отмена оставляет приложение открытым.

## Update

Windows-specific version `windows/version.json` initial0.1.0-alpha.1/build1, tag `windows-v0.1.0-alpha.1`; macOS untouched. Installer/ZIP names MacSwitcher-Windows-0.1.0-alpha.1-Setup.exe / portable.zip. Updater проверяет подписанный манифест, точную принадлежность URL, SHA-256 и размер пакета; загрузка и запуск установщика требуют явного выбора. Запуск использует одноразовое разрешение и штатный безопасный выход. No arbitrary URL, no disabling TLS/security.

## Фактический writer и update schema

Глобальный SendInput удалён: NativeRangeWriter работает по проверенному HWND Edit/RichEdit; generic UIA full-value только для доказанного plain Edit/конца поля. Unsafe/Unknown не запускают fallback. Перед restore сверяется lastObservedValue, а при его отсутствии доступен только Copy/Export.

Ручной двойной Shift преобразует последнее слово по фактическим буквам через `ConvertBidirectional`, даже если текущая раскладка уже отличается от раскладки его набора. Языки исходника и результата в receipt определяются по тексту; отмена восстанавливает исходный язык слова. Автокоррекционная политика от этого правила не меняется. Короткая native-транзакция и восстановление выделения описаны в [design.md](design.md#границы-короткой-native-транзакции).

Feed: https://raw.githubusercontent.com/alexfisenkov/MacSwitcher/main/windows/updates/windows.json. RSA-SHA256 envelope algorithm/payload/signature; payload schema1/version/build/tag/sourceRevision/assets, exact allowed own GitHub download URLs. Source package manifest schema1 содержит sourceRevision40hex и sourceSha25664hex (canonical source-digest.py), package hashes/sizes. Signer требует этот manifest и сверяет source digest и файлы.
