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

- [ ] RED: legacy behavior до marker/failure; Shift ON после marker с raw master/combined OFF; snapshot `{present,value,type}`; остальные prefs неизменны.
- [ ] RED: initial auto/per-app = legacy effective state; Auto ON/OFF не меняет второй gate и Shift; без рекурсивных getters.
- [ ] RED: lifecycle/permission/health, shell explicit opt-in и cache reconfiguration остаются отдельными gates; Caps обычного ввода не перехватывается новой политикой.
- [ ] RED: backup read-back, write failure и идемпотентность; уже подтверждённая копия не заменяется.
- [ ] Запустить целевой тест в изолированном Foundation-профиле; подтвердить, что новые проверки падают до реализации.
- [ ] Реализовать Foundation-path preflight, права 0700/0600, atomic write и read-back; marker писать только после подтверждённой копии. Legacy prefs не менять.
- [ ] Подключить policy в startup, `KeyboardMonitor` caches/`TriggerConfig`, `PredictionCoordinatorPlatform`, health/lifecycle, shell и manual/auto consumers. При ошибке сообщить об этом, сохранить прежнее поведение и Recovery/consent state.
- [ ] Подтвердить targeted PASS; прогнать combined-shift execution/editing, settings, recovery и prediction regressions.

### Задача 2: Компактное окно и меню статуса

**Файлы:**
- Изменить: `macos/Sources/RuSwitcher/SettingsWindowController.swift` — заменить навигацию на три верхние `NSTabView` вкладки, сохранить существующие dictionary, exceptions и learning views.
- Изменить: `macos/Sources/RuSwitcher/AppDelegate.swift` — требуемое меню и доступ к прежним operator/recovery actions.
- Изменить: `macos/Sources/RuSwitcher/Localization.swift` — подписи/инструкции на поддерживаемых UI языках из `L10n.supportedLanguages`: en, ru, de, fr, es, pt, zh, ja, ko, uk, pl, be, el, bg, hy, ka.
- Тест: обновить `macos/Tests/RuSwitcherTests/SettingsNavigationTests.swift`; добавить нужные offscreen control/geometry assertions туда же.
- Test seam: `SettingsWindowController.makeSettingsContent(tabView:)` + supplied `NSTabView`/`NSView`, synthetic defaults; CFFIXED Foundation profile. `NSWindow` не показывать, TCC не вызывать, реальный текст пользователя не использовать.

**Интерфейсы:** сохранить нужные callbacks (`onAutoConvertChanged`, `onPredictionPreferencesChanged`, `onShellBridgeSetupRequested`, `onRuntimeCheckRequested`, `onRecoveryArchiveChanged`) и используемую menu sync. Переиспользовать `PersonalDictionaryView`, `ExceptionListEditor`, `AdaptiveRulesView`.

- [ ] Offscreen-тестом проверить три вкладки, первую выбранную вкладку, геометрию и доступность controls без показа окна.
- [ ] В menu refactor сохранить `inputSourceMenuTag`/`sourceRecoveryItemTag` и динамическое обновление выбора раскладки/отложенного source recovery в `menuWillOpen` либо эквивалент; сохранить их handlers, recovery originals/archive folder.
- [ ] Проверить меню: effective auto state, instructions/settings, conditional words/recovery, input-source recovery, archive, permissions/self-check, update, Quit.
- [ ] Первая вкладка объясняет Shift/Shift×2/undo и `ghbdtn → привет`; отделяет Auto от ручного действия.
- [ ] Переиспользовать dictionary/exceptions/learning views; Settings не предлагает legacy gesture controls или общий Shift master toggle.
- [ ] Запустить offscreen geometry/controls tests в CFFIXED synthetic profile; screenshots — только компонентные свидетельства, не physical UI acceptance.

### Задача 3: Полная проверка и фиксация границ

- [ ] Сверить gates, migration, recovery consent, startup order и menu read-back со spec.
- [ ] Запустить `CFFIXED_USER_HOME="$(mktemp -d -t macswitcher-tests)" swift test --package-path macos -j 4` и `swift build --package-path macos -c release -j 4`; перед запуском убедиться, что Foundation applicationSupportDirectory работает в свежем профиле.
- [ ] Запустить `/usr/bin/python3 script/check_public.py`, `git diff --check` и просмотреть diff на утечки/выход за T0; после coherent freeze — один финальный CI.

Один исполнитель `gpt-6-sol` ведёт все три задачи end-to-end; production code + tests — менее 3 000 строк. Owner уже утвердил T0: перед реализацией не запрашивать дополнительное подтверждение.

**Остаётся отдельной приёмкой:** живой вид нативного окна владельцем, реальная клавиатура/TCC, достоверность раннего preflight на целевом macOS-профиле, откат старой версии из резервной копии, если он понадобится. Ни hosted tests, ни HTML-прототип не закрывают эти пункты.

## Фактический статус · 13.11.2026

План реализован локально; код и тесты прошли два раунда критики. Финальная локальная проверка: 695 Swift-тестов, 0 отказов, один намеренный skip PNG-export без output directory; отдельный offscreen-export 10 PNG прошёл. Release build прошёл с ранее существовавшим AX cast warning. `script/check_public.py` прошёл на 326 файлах. R2 bounded-read finding исправлен лимитом 128 KiB, проверками приватного файла и дескриптора и ограниченным чтением max+1; targeted 10 и полный набор 695 прошли. Hosted CI и перечисленная выше живая приёмка ещё не выполнены. Следующие шаги — заморозить source, выполнить одну финальную CI и отдельно подготовить/принять подписанную сборку. Кандидат alpha.32 пока не опубликован и не установлен.
