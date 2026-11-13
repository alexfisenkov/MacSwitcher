# Самодиагностика и безопасное восстановление · Implementation Plan

> **For agentic workers:** use superpowers:subagent-driven-development with the project's existing ownership and critic-review rules. Steps use checkbox (`- [x]`) syntax. Project overrides: sensitive writer Sol, critics Luna, at most two review rounds, no deletion of the working checkout, one final hosted CI for the coherent iteration.

**Goal:** MacSwitcher сам замечает проверяемые сбои своих обработчиков, безопасно восстанавливает их после временной блокировки и понятно показывает состояния, которые требуют пользователя.

**Architecture:** чистые metadata snapshot/classifier и внутренний offline self-check; production-адаптер использует существующий двухсекундный опрос AppDelegate и единственный MonitoringTapRecovery. Возобновление после Secure Input, wake или возврата доступа сбрасывает устаревший контекст и один раз перевооружает перехватчик вне активного редактирования. Консольная часть получает metadata-health, безопасную очистку только закрытых peers и ограниченный повтор только доказанно временного сбоя.

**Tech Stack:** существующие Swift/AppKit/Foundation/CoreGraphics, без новых зависимостей или сервисов.

**Spec:** разделы «Требования» и «Границы» этого документа; исходные контракты docs/architecture.md и docs/plans/2026-11-10-input-adapters.md.

## Требования

Владелец 10.11 попросил автоматическую самопроверку и восстановление, в том
числе после защищённого ввода и иных временных блокировок. Он продолжает
текущую задачу совместимости; это дополнение входит в тот же кандидат alpha.31.
Ранее выбранный владельцем способ работы — самостоятельная реализация через
субагентов с проверками, без повторного интервью по рутинным решениям.

Решения реализации главного агента: один существующий опрос вместо второго
watchdog; состояние «перехват подключён» вместо обещания «все приложения
проверены»; автоматическое обслуживание не вводит текст и не захватывает экран.

Уже есть MonitoringTapRecovery с одним отложенным повтором через 3 секунды,
проверки tap present/enabled/fence и опрос каждые 2 секунды. Отсутствие ввода
не доказывает поломку: молчащий, но enabled tap нельзя отличить от простоя по
одному такому сигналу. Возобновление после известного системного перехода
может выполнить один безопасный re-arm через существующий контроллер.
Принятое после R1 уточнение: не более пяти неудачных запусков перехватчика
на эпизод с прежним трёхсекундным интервалом. Обычный двухсекундный опрос не
сбрасывает исчерпанный бюджет; новая ручная проверка, настройка или известное
системное возобновление могут начать новую серию. Для короткого Secure Input
используется также закрытый sticky-сигнал из существующей проверки на границе
события, без хранения события или текста.
Уточнение R2: если после уже замеченного системного перехода нормальный
клавиатурный callback подтвердил, что tap и нужный fence исправны, отложенный
профилактический перезапуск становится лишним. Он не должен позже сбрасывать
уже начатое новое слово. Mouse/scroll не являются подтверждением доставки
клавиатуры. Реальная структурная поломка и явно отложенная настройка остаются
самостоятельными основаниями для guarded recovery.

## Global Constraints

- macOS 13+, текущий SwiftPM/AppKit, без дополнительных демонов и зависимостей.
- Сохранить пользовательские 200 мс, заводские 180 мс, словари, обучение, исключения и recovery opt-in.
- Не вводить тестовые слова в реальные поля, не читать содержимое полей/clipboard/команд при health poll и не записывать клавиши.
- Нет автоматических запросов прав, изменений `.zshrc`, открытия/закрытия приложений, принудительного завершения MacSwitcher или повторной отправки замены.
- Secure Input, недоступные разрешения, user pause и readonly — ожидаемые ограничения, не повод обходить защиту или бесконечно перезапускаться.
- При активной native lease или shell CAS/ACK отложить recovery; RAM-исходники и неизвестные line locks не очищать.
- Статусы и диагностика — закрытые enum/счётчики без текста, PID/TTY/путей в пользовательском отчёте. Автоматические проверки не показывают повторные alert/toast.
- Проверки используемых возможностей не доказывают доставку текста во всех редакторах; это отдельная физическая приёмка.

## Review Focus

1. Secure Input ON→OFF и sleep→wake не оставляют старые ключи/предсказание или бесконечный pause; один re-arm после безопасной границы.
2. Одновременно активная native lease/shell ACK не прерывается watchdog; отложенное восстановление выполняется один раз после завершения.
3. Отозванные права и master OFF не вызывают prompt/restart storm; после возврата прав используются те же guarded recovery API.
4. Закрытые shell peers удаляются только по точному EOF; pending bytes и заменившее соединение сохраняются, неизвестные исходники/locks остаются.
5. Внутренний self-check/ручная проверка не обращаются к пользовательским полям, TIS selection, настройке профиля или сети и не выдают passive readiness за проверенный ввод.

## Task 1: единый health-контур

**Files:**
- Create: macos/Sources/RuSwitcher/RuntimeHealth/RuntimeHealth.swift (pure state, controller and injected actions; split neighbouring pure self-check if needed).
- Create: macos/Sources/RuSwitcher/RuntimeHealth/RuntimeSelfCheck.swift.
- Modify: AppDelegate.swift, KeyboardMonitor.swift, MonitoringTapRecovery.swift only if existing gates need a minimal extension; SettingsWindowController.swift for one manual self-check action.
- Test: RuntimeHealthTests.swift, RuntimeSelfCheckTests.swift and relevant existing monitor tests.

**Interfaces:**
- Consumes: MonitoringTapRecovery.request()/poll(needsRecovery:)/retryScheduled; KeyboardMonitor structural tap/fence metadata and lease state; non-prompt permission preflight; AutoSwitchPolicy.secureInputActive.
- Produces: text-free RuntimeHealthSnapshot/State and a main-actor RuntimeHealthController.poll(reason:) through injected observation/action/clock closures; manual check calls the same runner and classification.
- RuntimeSelfCheck.run() returns closed check IDs and pass/fail only, using production pure CombinedShiftGesture, KeyMapping.convert, shell wire codec and profile preview/transform on synthetic memory Data. No live adapters.

- [x] Write failing tests for classification, idle, expected listen-only mode, pause/permissions, Secure Input transitions, wake, lease/CAS deferral, one coalesced repair, no automatic UI/typing and failed self-check status.
- [x] Implement the pure controller and offline runner with injectable dependencies. Keep provider observation separate from policy and UI.
- [x] Wire the existing 2-second loop and NSWorkspace sleep/wake notifications. Gate both immediate and scheduled tap recovery on permission/secure/edit-safe conditions. Invalidate stale context outside an active edit.
- [x] Show one quiet conditional status/tooltip for abnormal state and one manual «Проверить работу…» action in settings. Normal status/menu remains minimal; RU/EN copy is plain and differentiates internal checks from real editor compatibility.
- [x] Run focused isolated Swift tests and diff-check; record command/results. No Git/GUI/install by writer.

## Task 2: состояние shell-службы и закрытые peers

**Files:**
- Modify: TerminalBridge/GenericShellEditorBroker.swift, ManualShellCoordinator.swift and focused tests.
- Integrate metadata into RuntimeHealth controller and settings report; no extra polling timer.

**Interfaces:**
- GenericShellEditorBroker.pruneClosedSessions() reports counts only. Use connection.try-lock, application pending-buffer guard and recv(MSG_PEEK|MSG_DONTWAIT)==0; remove only the same registry connection identity. No SDEF/AX or payload logging in pruning.
- ManualShellCoordinator exposes text-free health metadata, closed startup fault and guarded safe-restart capability. Error classification distinguishes transient socket start failure from unsafe/active path and normal waiting for shell session.

- [x] Add failing tests for exact EOF, unread/pending bytes, replacement identity, stale sessions before expensive focus proof, restart deferral during pending/in-flight/unknown edits and preserving originals.
- [x] Prune closed sessions before prepareFocused's SDEF work and on bounded off-input health maintenance. Keep live/indeterminate peers; do not inspect command text.
- [x] Retain closed startup fault. Retry only transient service startup failures with bounded attempts/backoff (maximum 3 per episode, at least 30 seconds apart); unsafe path/active listener/consent/setup absence require explicit action. Do not restart a healthy broker just because no shell is connected.
- [x] Run focused tests and read-back. Existing orphan socket identity/owner-lock and profile backup/atomic-exchange protections remain unchanged.

## Task 3: общий gate и доставка

**Files:** docs/architecture.md, roadmap.md, compatibility.md, release candidate notes and AGENTS.md; private reports in .критики/ and .журналы/.

- [x] Independent Luna code/risk and skeptic reviews of this health addition, maximum two rounds; one Sol writer for accepted fixes.
- [x] Isolated full Swift suite, release build, Python/public/website/plist/zsh checks and staged secret scan. Existing input-adapter gate before this addition passed Swift606/Python36/gold495 and release build.
- [ ] Commit/push coherent source, one final hosted CI, exact signed/notarized candidate. Do not deploy website links before actual release availability.
- [ ] Normal update preserves RAM originals and user settings. Shell setup/TCC remain an explicit user action; real Secure Input/sleep/Spotlight/Terminal keyboard acceptance is recorded separately from synthetic tests.

## Открытые границы

Программа не может сама выдать системное разрешение, отключить чужой Secure
Input, гарантировать доставку в каждом чужом редакторе или безопасно
перезапустить зависший процесс с несохранёнными исходниками. Текущее prompt zsh
после перезапуска может требовать следующего приглашения/нового окна; health
сообщает это, не выполняет команду за пользователя. Если provider
программно меняет вкладку, переиспользуя точный AX-элемент без физического
события, first-tap TTY остаётся условной до реальной проверки провайдера.

Если ОС не передала ни одного события и весь короткий Secure Input прошёл
между двумя опросами, точный переход не наблюдаем. Sticky-сигнал закрывает
случаи, замеченные существующей проверкой события, но не превращает отсутствие
сигнала в доказательство отсутствия защиты. Реальные переходы и доставка
текста требуют отдельной приёмки; парольные поля не используются как тестовые.

## Локальная фиксация перед hosted CI

После R2 BLOCK и его адресных исправлений объединённый source прошёл
изолированный full Swift642 и release build. Главный агент отдельно выполнил
80 критических regressions и Python36/public/websiteJS/plist/zsh/diff gate.
Code/risk R2 закрыл принятые находки; skeptic R2 выявил late-context-reset,
его исправление проверено root по исходнику и RED/GREEN regression без R3.
CI, подпись, установка и реальная системная приёмка не подменяются этими
результатами. Остаточные OS-наблюдения и границы остаются выше.
