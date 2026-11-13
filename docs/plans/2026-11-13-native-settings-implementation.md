# Нативные настройки MacSwitcher · план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task by task. Steps use checkbox syntax for tracking.

**Цель:** заменить перегруженную поверхность настроек компактным AppKit-окном, которое учит пользоваться единым Shift и сохраняет пользовательские данные.

**Архитектура:** сохранить `SettingsWindowController`/`AppDelegate`; вынести переход к единому Shift в migration helper, не перезаписывая legacy UserDefaults. Переиспользовать панели словаря, исключений и обучения.

**Стек:** Swift, AppKit, UserDefaults, XCTest; без зависимостей и перехода на SwiftUI.

**Спецификация:** `docs/plans/2026-11-13-native-settings-design.md`.

## Общие ограничения

- Окно компактное; три верхние вкладки: «Как пользоваться», «Слова и исключения», «Настройки»; первая выбрана при открытии.
- Разнести gates `manualShift`, `automaticText`, `perAppBackground`, `monitorLifecycle`; исключить общий master-gate и recursive getters.
- До marker создать verified raw gesture/master snapshot с отсутствием/типом ключей: app-support directory 0700, file 0600, atomic write/read-back; без filesystem I/O в keyboard callbacks.
- После marker Shift ON; initial Auto/per-app равны legacy effective states; Auto ON/OFF меняет только Auto. До marker/backup failure действует прежний runtime, UI показывает неприменённый переход.
- Сохранить личные данные, permissions/consent и onboarding. T0 исключает оплату, новые input languages и выпуск.

## Риски и тесты

- Тестировать failure/idempotence, absent/wrong-type prefs, master=false + autoConvert=true, Auto ON/OFF, lifecycle/permission, shell opt-in, cache refresh и узкую/локализованную геометрию.

---

### Задача 1: Единая политика Shift и безопасный переход настроек

**Файлы:**
- Создать: `macos/Sources/RuSwitcher/ShiftBehaviorPolicy.swift` — effective policy и одноразовый backup/marker.
- Изменить: `macos/Sources/RuSwitcher/SettingsManager.swift` — независимые effective states/overrides, рассчитанные из raw snapshot без взаимно-рекурсивных getters.
- Изменить: `macos/Sources/RuSwitcher/KeyboardMonitor.swift` — `TriggerConfig` и cache в `start()`/reconfigure path используют effective policy; не делать filesystem IO в callback.
- Изменить: `macos/Sources/RuSwitcher/Editing/PredictionCoordinatorPlatform.swift` — разделить automatic-text и per-app background gates.
- Изменить: `macos/Sources/RuSwitcher/AppDelegate.swift` — startup migration и отдельные gates для lifecycle/health, shell, manual Shift и auto; failure сохраняет legacy path и показывает честный статус.
- Тест: `macos/Tests/RuSwitcherTests/ShiftBehaviorPolicyTests.swift`.
- Тест: дополнить `macos/Tests/RuSwitcherTests/CombinedShiftSettingsTests.swift`.

**Behavior contract:** до marker/failure getters и consumers ведут себя ровно как раньше. После verified marker manual Shift = ON; `automaticText` baseline = `raw.autoSwitch && raw.autoConvert`; `perAppBackground` baseline = `raw.autoSwitch && raw.perAppLayout`; monitor lifecycle по-прежнему зависит от permissions/health. Узкие V2 effective snapshot/overrides сохраняют раздельные состояния; исходные raw UserDefaults не перезаписывать. Явное Auto ON/OFF меняет только automatic-text override. Sol выбирает конкретную реализацию этих состояний.

- [x] RED: legacy behavior до marker/failure; Shift ON после marker с raw master/combined OFF; snapshot `{present,value,type}`; остальные prefs неизменны.
- [x] RED: initial auto/per-app = legacy effective state; Auto ON/OFF не меняет второй gate и Shift; без рекурсивных getters.
- [x] RED: lifecycle/permission/health, shell explicit opt-in и cache reconfiguration остаются отдельными gates; Caps обычного ввода не перехватывается новой политикой.
- [x] RED: backup read-back, write failure и идемпотентность; уже подтверждённая копия не заменяется.
- [x] Запустить целевой тест в изолированном Foundation-профиле; подтвердить, что новые проверки падают до реализации.
- [x] Реализовать Foundation-path preflight, права 0700/0600, atomic write и read-back; marker писать только после подтверждённой копии. Legacy prefs не менять.
- [x] Подключить policy в startup, `KeyboardMonitor` caches/`TriggerConfig`, `PredictionCoordinatorPlatform`, health/lifecycle, shell и manual/auto consumers. При ошибке сообщить об этом, сохранить прежнее поведение и Recovery/consent state.
- [x] Подтвердить targeted PASS; прогнать combined-shift execution/editing, settings, recovery и prediction regressions.

### Задача 2: Компактное окно и меню статуса

**Файлы:**
- Изменить: `macos/Sources/RuSwitcher/SettingsWindowController.swift` — заменить навигацию на три верхние `NSTabView` вкладки, сохранить существующие dictionary, exceptions и learning views.
- Изменить: `macos/Sources/RuSwitcher/AppDelegate.swift` — требуемое меню и доступ к прежним operator/recovery actions.
- Изменить: `macos/Sources/RuSwitcher/Localization.swift` — подписи/инструкции на поддерживаемых UI языках из `L10n.supportedLanguages`: en, ru, de, fr, es, pt, zh, ja, ko, uk, pl, be, el, bg, hy, ka.
- Тест: обновить `macos/Tests/RuSwitcherTests/SettingsNavigationTests.swift`; добавить нужные offscreen control/geometry assertions туда же.
- Test seam: `SettingsWindowController.makeSettingsContent(tabView:)` + supplied `NSTabView`/`NSView`, synthetic defaults; CFFIXED Foundation profile. `NSWindow` не показывать, TCC не вызывать, реальный текст пользователя не использовать.

**Интерфейсы:** сохранить нужные callbacks (`onAutoConvertChanged`, `onPredictionPreferencesChanged`, `onShellBridgeSetupRequested`, `onRuntimeCheckRequested`, `onRecoveryArchiveChanged`) и используемую menu sync. Переиспользовать `PersonalDictionaryView`, `ExceptionListEditor`, `AdaptiveRulesView`.

- [x] Offscreen-тестом проверить три вкладки, первую выбранную вкладку, геометрию и доступность controls без показа окна.
- [x] В menu refactor сохранить `inputSourceMenuTag`/`sourceRecoveryItemTag` и динамическое обновление выбора раскладки/отложенного source recovery в `menuWillOpen` либо эквивалент; сохранить их handlers, recovery originals/archive folder.
- [x] Проверить меню: effective auto state, instructions/settings, conditional words/recovery, input-source recovery, archive, permissions/self-check, update, Quit.
- [x] Первая вкладка объясняет Shift/Shift×2/undo и `ghbdtn → привет`; отделяет Auto от ручного действия.
- [x] Переиспользовать dictionary/exceptions/learning views; Settings не предлагает legacy gesture controls или общий Shift master toggle.
- [x] Запустить offscreen geometry/controls tests в CFFIXED synthetic profile; screenshots — только компонентные свидетельства, не physical UI acceptance.

### Задача 3: Полная проверка и фиксация границ

- [x] Сверить gates, migration, recovery consent, startup order и menu read-back со spec.
- [x] Запустить `CFFIXED_USER_HOME="$(mktemp -d -t macswitcher-tests)" swift test --package-path macos -j 4` и `swift build --package-path macos -c release -j 4`; перед запуском убедиться, что Foundation applicationSupportDirectory работает в свежем профиле.
- [x] Запустить `/usr/bin/python3 script/check_public.py`, `git diff --check` и просмотреть diff на утечки/выход за T0; после coherent freeze — один финальный CI.

Один исполнитель `gpt-6-sol` ведёт все три задачи end-to-end; production code + tests — менее 3 000 строк. Owner уже утвердил T0: перед реализацией не запрашивать дополнительное подтверждение.

**Остаётся отдельной приёмкой:** физические клавиатурные жесты, Terminal live bridge (понадобится новый настроенный zsh prompt), Spotlight и совместимость с приложениями вне наблюдённого тестового охвата. CUA осмотр реального установленного окна прошёл; hosted tests и HTML-прототип сами по себе не подтверждают физический ввод или всю app matrix.

## Фактический статус · 13.11.2026

План реализован и прошёл два раунда критики; R2 bounded-read finding исправлен лимитом 128 KiB и проверкой файла/дескриптора, после чего targeted 10 и полный suite прошли. Финальная CI `43385000693` на source `176c3919b8b23db1f097cd4e234286f69db3c92c`: 695 Swift (0 failures, 1 intentional PNG-export skip), 36 Python, gold495. Отдельный offscreen-export 10 PNG прошёл. Universal ZIP 43,415,986 bytes, SHA-256 `8b1e8818d5dc9ce32b3a248cf66fdd3dcc3ec9a506c3f731fa4a1fae20f5d3f1`; Developer ID/notarization/staple/Gatekeeper/codesign/Sparkle checks PASS. Штатная установка работает: 34 прежних настроек неизменны, user data hashes unchanged; backup 11 gesture keys verified; Auto ON, double Shift 200 ms. CUA осмотр реального AppKit окна прошёл; internal checks 4/4 и keyboard monitor connected. GitHub prerelease и assets проверены публично. Не проверены физические клавиатурные жесты и весь app matrix; Terminal live bridge не подключён, личные редакторы слов не открывались, поэтому ручные CRUD-сценарии с персональными данными не наблюдались. Signed feed и Pages deployment/read-back остаются pending.
