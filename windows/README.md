# MacSwitcher for Windows

Windows port of MacSwitcher with offline RU/EN correction and a tray menu. Current preview: `0.1.0-alpha.3`.

[Download Setup or portable](https://github.com/alexfisenkov/MacSwitcher/releases/tag/windows-v0.1.0-alpha.3). [Windows CI](https://github.com/alexfisenkov/MacSwitcher/actions/runs/41768189082) passed on source `e57592474d19bf2e93b73740fc32683542acc879`: 769 Core assertions and 44 runtime checks, including owned Edge input/textarea through the actual 90 ms runtime writer and per-user installation/data preservation. [Acceptance matrix and open work](../docs/windows-port/acceptance.md).

## Requirements and support

- Windows 7 SP1, Windows 8.1, Windows 10, or Windows 11 with .NET Framework 4.6.2 or later on x86 or x64.
- Windows 11 ARM64 may run the AnyCPU build through .NET compatibility. Physical ARM64 support has not been tested.
- Windows XP, Windows Vista, and Windows 8.0 are outside the supported range.
- The app runs as the signed-in user. It does not request administrator privileges or bypass Windows security boundaries.

The hosted Windows Server workflow is automated CI evidence. It does not establish physical Windows 7/8.1/10/11, ARM64, or third-party editor compatibility.

## Build

Install .NET SDK 10.0.403 and Python 3.11 or later. From the repository root:

```powershell
python windows/scripts/build-data.py --output windows/data
python windows/scripts/extract-icon.py
cd windows
dotnet build src/MacSwitcher.Windows/MacSwitcher.Windows.csproj -c Release
```

Run `dotnet` commands from `windows/` so `global.json` selects the pinned SDK. The dictionary builder checks the pinned source hashes in `dictionaries/manifest.json`. Generated dictionaries are local build inputs and are not committed.

## Packages

The per-user setup and portable ZIP are unsigned because this project has no Windows Authenticode certificate. Windows may display its normal publisher warning. Do not disable SmartScreen or other Windows protections to install the app. The installer checks for .NET Framework 4.6.2 and opens Microsoft's download page if the requirement is missing.

Personal settings and lexicon files live under `%LOCALAPPDATA%\MacSwitcherWindows`. Alpha.2 adds a separate `adaptive-rules.json`: two independent confirmed word choices activate a local preference; undo/redo does not add confirmations. Learning is enabled by default with a first-run explanation and can be disabled, reviewed, deleted or reset in Settings. Manual personal entries remain separate. No phrase or keystroke history is stored or synchronized. Recovery originals are kept in memory until explicitly exported by the user. See [the common contract](../docs/local-learning.md).

## Окна администратора

Для обычных программ повышенные права не нужны. Если сам редактор запущен от имени администратора, Windows ограничивает доступ обычного MacSwitcher. Только в таком случае: выберите «Выход» в меню MacSwitcher (сохраните предложенные исходные тексты), затем в меню «Пуск» найдите MacSwitcher, щёлкните правой кнопкой → «Дополнительно» → «Запуск от имени администратора» и самостоятельно подтвердите UAC.

Файл установленной программы находится в `%LOCALAPPDATA%\Programs\MacSwitcher\MacSwitcher.Windows.exe`; для portable-версии — в выбранной папке распаковки. Повышение не сохраняется и не включается автоматически. Парольные поля, экран UAC, блокировка и чужие пользовательские сеансы не обрабатываются.
