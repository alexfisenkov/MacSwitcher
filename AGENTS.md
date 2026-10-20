# MacSwitcher

Публичный macOS-проект: https://github.com/alexfisenkov/MacSwitcher.
Назначение: ранняя локальная коррекция RU/EN, один Shift меняет раскладку,
два Shift исправляют последнее слово или выделение. Основа — MIT-код RuSwitcher
v3.4.0 и ранее разработанный native combined-Shift режим. Собственное имя и иконка.

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
