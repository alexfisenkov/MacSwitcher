# Windows contracts v1

## Build

SDK10.0.403. Core project target `net462;net10.0`, app `net462` AnyCPU, tests `net10.0`; Microsoft.NETFramework.ReferenceAssemblies.net462 1.0.3 build-only. No other NuGet dependencies expected. C# plain BCL API available net462; no nativeSQLite dependency.

## Core names

Namespace MacSwitcher.Core. Core worker defines these public interfaces first and sends names to other workers.

- AppSettings: bool Enabled=true, AutomaticCorrection=true, RussianPriority=true, StartWithWindows=false; int DoubleShiftMilliseconds=180; string[] ExcludedApplications=[]; validate range80..400.
- IPersonalLexicon: bool IsWord(string word,string language); bool IsPhraseException(string original,string sourceLanguage). PersonalLexicon mutable thread-safe in-memory implementation exposes snapshot/replace arrays for store, not automatic learning.
- PredictionLexicon.Load(string dataDirectory, IPersonalLexicon personal); IDisposable; Frequency(word,language), FullFrequency(nullable on failedread), HasSupplementalSpelling(nullable), IsProtectedTerm, PrefixEvidence.
- PredictionEngine(PredictionLexicon).Evaluate(string suffix,string sourceLanguage,bool atBoundary=false,string[] precedingWords=null,bool russianPriority=false) returns PredictionProposal {OriginalSuffix,ReplacementSuffix,TargetLanguage,Reason}. Preserve all495 gold and addalpha24coreexamples.
- LayoutMap.Convert(string text,string sourceLanguage), ConvertBidirectional(stringtext) (language inferred scriptperchar); ShiftGesture Press/Release/Interrupt with monotonicmilliseconds and captured LayoutDirection {SourceId,TargetId}, twoactions SwitchLayout/Convert. Defaults250mshold/180msdouble.
- SmartSelection conversion method preserving valid/protectedwords vs explicit fullflip; `SelectionConverter.Convert(text,lexicon,boolsmart, sourceLanguage)` ifAPIsettledworkerupdateconsumers.

## Dictionary binary MSLEXW01

Each language has `<lang>.lex` generated from existing full+spelling+protected. Little-endian header: magic8bytesASCII MSLEXW01; uint32 stride128; uint32 blockCount; uint64 recordCount. Index entries: ushort utf8firstWordByteLength, wordbytes, int64 absoluteDataOffset, uint32 blockRecordCount. Records perblock: ushort wordByteLength<=160, wordbytesstrictUTF8, int32 fullFrequency>=0, byte flags (1=normative spelling,2=protectedterm); fullfrequency0meansknownabsence. SortedbinaryUTF8ordinal words. No overflow/varints. Sparseindex fully memoryloaded, each query reads<=128boundedrecords atknownoffset; boundedoptionalpagecache. Corruptheader/index/payload/hash gives unavailable/exceptionfailclosed.

Data folder also ru.tsv/en.tsv (top200k), protected-terms.tsv, prediction-benchmark.json, licences, dictionary-manifest.json with SHA256/size/counts/source hashes. generated data notgittracked. Builder `windows/scripts/build-data.py --output windows/data` owned UI/package worker. Core reader/testworker followsformat.

## Runtime bridge for UI

Namespace MacSwitcher.Windows.Runtime; Runtime worker owns these types. `WindowsSwitcherRuntime(AppSettings settings, IPersonalLexicon personal, string dataDirectory)` IDisposable. Public `Start()`, `Stop()`, `ApplySettings(AppSettings)`, `bool HasRecoveryOriginals`, `string ExportRecovery(string directory)`, `bool UndoLastCorrection()` (actualsafechecked), `bool AddLastCorrectionAsException()`? Better expose `CorrectionUndone` event with old/newphrase and let UI explicitsave. Events `Action<RuntimeStatus> StatusChanged`, `Action<CorrectionNotice> CorrectionApplied`, `Action<CorrectionNotice> CorrectionUndone`; RuntimeStatus properties Message, Ready, NeedsAdministrator (humantext no textpayload), CorrectionNotice Original/Replacement/SourceLanguage (RAMonly). These events neverlogged; UI optionalofferexplicitexception.

UI worker implements `ConfigurationStore(string directory)` with `AppSettings Settings`, `PersonalLexicon Personal`, `Load()`, `SaveSettings(AppSettings)`, word/exception operations Import/Export/Add/Delete; and `SwitcherContext(WindowsSwitcherRuntime runtime, ConfigurationStore store, bool showSettings)` : ApplicationContext. Program owned runtimeworker createsstore.Load thenruntime/dataDirfromAppContext.BaseDirectory/data, createscontext, runtime.Start and Application.Run(context). Runtime worker synchronizes with UIworkerbeforechangingconstructor. UI closes runtime on Quit only after localrecoveryexport success/cancel.

## Update

Windows-specific version `windows/version.json` initial0.1.0-alpha.1/build1, tag `windows-v0.1.0-alpha.1`; macOS untouched. Installer/ZIP names MacSwitcher-Windows-0.1.0-alpha.1-Setup.exe / portable.zip. Initial updater cancheckownversionJSON/signatures, opens/downloads verifiedowninstaller onlyafterexplicitclick. No arbitraryURL, no disablingTLS/security. Parent coordinates crypto/signing schema before updaterimplementation.

## Фактический writer и update schema

Глобальный SendInput удалён: NativeRangeWriter работает по проверенному HWND Edit/RichEdit; generic UIA full-value только для доказанного plain Edit/конца поля. Unsafe/Unknown не запускают fallback. Перед restore сверяется lastObservedValue, а при его отсутствии доступен только Copy/Export.

Feed: https://raw.githubusercontent.com/alexfisenkov/MacSwitcher/main/windows/updates/windows.json. RSA-SHA256 envelope algorithm/payload/signature; payload schema1/version/build/tag/sourceRevision/assets, exact allowed own GitHub download URLs. Source package manifest schema1 содержит sourceRevision40hex и sourceSha25664hex (canonical source-digest.py), package hashes/sizes. Signer требует этот manifest и сверяет source digest и файлы.
