# MacSwitcher

Публичный macOS-проект: https://github.com/alexfisenkov/MacSwitcher.
Назначение: ранняя локальная коррекция RU/EN, один Shift меняет раскладку,
два Shift исправляют последнее слово или выделение. Основа — MIT-код RuSwitcher
v3.4.0 и ранее разработанный native combined-Shift режим. Собственное имя и иконка.

## Маршрутизация агентов
- Владелец текущей задачи координирует интеграцию и выпуск.
- Routine execution и весь цикл критиков для этого проекта назначаются на актуальный `gpt-6-luna`.
- Задачи исполнения, затрагивающие security или чувствительные данные, назначаются на `gpt-6-sol`.

## Источники истины
- docs/architecture.md — границы модулей и контракт безопасного ввода.
- docs/roadmap.md — незавершённое и критерии приёмки.
- macos/Package.swift и script/ — реальные команды сборки/проверки.
- dictionaries/NOTICE.md и manifest.json — происхождение и лицензии данных.
- LICENSE и NOTICE.md — лицензия кода и происхождение.

## Карта
- macos/Sources/RuSwitcher/ — существующее внутреннее имя модуля сохранено.
- PredictionEngine.swift, PredictionLexicon.swift — чистая политика и словари.
- KeyboardMonitor.swift, PredictionCoordinator.swift — события и bounded context.
- TextConverter.swift, CombinedShift*.swift — проверенная запись в конкретный PID/AX field.
- AppDelegate.swift — соединение обработчиков, без словарной политики.
- UpdateChecker.swift, LocalUpdateBridge.swift — обновления только из MacSwitcher.
- macos/Tests/ — синтетические регрессии, без пользовательских текстов.
- script/ — сборка, импорт словарей и проверка публикации.
- .критики/, .черновики/, .журналы/, .сборки/ — приватное, в git не входит.

## Проверка
- swift test --package-path macos -j 4
- swift build --package-path macos -c release -j 4
- git diff --check
- /usr/bin/python3 script/check_public.py
- GitHub Actions только workflow_dispatch, одна финальная CI после локальных проверок.

## Ограничения
- Никаких логов набранного текста, клавиш, clipboard, фоновой отправки или скрытого обучения.
- Auto-edit только после повторной проверки PID, точного поля, caret, revision и исходного суффикса.
- Не копировать vendor-иконку, маркетинг, донат-ссылки и автоматическую публикацию в каналы.
- Лицензия частотных данных отдельна от MIT кода. Не публиковать личные словари и настройки.
- Работающий RuSwitcher Local сохраняется до проверенной сборки/миграции.
- Workers не устанавливают GUI, не меняют права и не перезаписывают чужие файлы.
- Единственный writer общих файлов — назначенный владелец; согласовать интерфейсы перед интеграцией.

## Готовность и долг
Разделять unit/build, подпись/публикацию, runtime и физическую клавиатуру.
Первый выпуск — проверяемая базовая предиктивная обработка; полноценная языковая
модель и самообучение требуют отдельной проверки точности, не объявлять реализованными.

<!-- AISPA_CONTEXT_BEGIN_V1 -->
## AISpa: проектный контекст

Если `.aispa/context/INDEX.md` существует, прочитайте его и `.aispa/context/memory.md`.
В чистом Git-клоне приватного `.aispa/context/` может не быть: тогда читайте
существующие `README.md`, публичные документы в `docs/` и корневые правила проекта.
Отсутствующие файлы не считайте доказательством отсутствия контекста;
сверяйте фактические файлы и сохранённый бриф доступного прогона.
При локальном прогоне бриф, спецификация, план, решения и прогресс — в `.aispa/context/`.
Это производные представления: источники истины — неизменные источники и
журнал `.aispa/runs/`; их ссылки и контрольные суммы — в `source-map.json`.
Не редактируйте представления вручную; изменения фиксируются движком AISpa.
Правила проекта вне этого блока сохраняют силу.
<!-- AISPA_CONTEXT_END_V1 -->

## Windows-порт

- Windows-компонент — `windows/`, правила — `windows/AGENTS.md`; канон — `docs/windows-port/design.md` и `contracts.md`.
- Фактическая приёмка и долг — `docs/windows-port/acceptance.md`; выпуск Windows alpha.1 закреплён `windows-v0.1.0-alpha.1`, источник `7892dc51b8b80cb7628f272da436fce1b58ff875`, CI22 `41618728418`. Не приравнивать hosted fixture к физической клавиатуре/всем приложениям.
- Core C# target `net462;net10.0`, GUI WinForms target `net462`; macOS Swift/version.json/updates/appcast.xml не меняются при Windows-выпуске.
- Windows-only версия/пакеты — `windows/version.json`, tag `windows-v…`, канал `windows/updates/windows.json`; не назначать Windows-релиз global latest macOS.
- Подпись собственного update manifest RSA не заменяет Authenticode; EXE пока unsigned. Приватный signer вне Git.
- Из корня: `python3 windows/scripts/build-data.py --output windows/data`, `python3 windows/scripts/extract-icon.py`. Затем из каталога `windows/`, где действует SDK pin в global.json: `dotnet run --project tests/MacSwitcher.Core.Tests -c Release`, `dotnet build src/MacSwitcher.Windows -c Release`. Runtime/installer — только собственные fixture-поля в Windows workflow_dispatch.
- Hosted Windows Server CI не доказывает physical Windows7/8.1/10/11/ARM или чужие редакторы.

## Локальное обучение · решение владельца 03.11.2026

- Канон новой функции — `docs/local-learning.md`. Владелец разрешил обе платформы и два независимых подтверждения одного слова; обратный выбор снимает выученное правило.
- Владелец выбрал default ON с понятным пояснением при первом запуске; явный off сохраняется. При миграции отсутствующий новый ключ означает ON.
- Разрешены только локальные ограниченные word-only адаптивные записи с видимой настройкой и управлением. Запрет истории текста/клавиш, сети, личных данных в Git и скрытого обучения сохраняется.
- Выученное отделено от ручного словаря; Unknown/auto-apply/повторный undo-redo не дают новые голоса. Транспорт редактирования и тайминги Shift не меняются.
- Выпущено: macOS alpha.25 и Windows alpha.2 из `58a529f0dcff6aa3cde5439f028d257ee023420a`; CI `41630893348` (502 Swift/35 Python/gold495) и `41630906057` (626 Core/gold495/runtime44) PASS. Штатное обновление Mac установлено, настройки/ручной словарь сохранены, обучение ON и пояснение показано. Физическое обучение пользователя отдельно не тестировалось.
