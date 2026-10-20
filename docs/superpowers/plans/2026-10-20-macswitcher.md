# MacSwitcher Implementation Plan

**Goal:** публичная проверяемая alpha с ранней RU/EN коррекцией и привычными Shift.
**Architecture:** immutable snapshots → pure engine → verified PID/AX suffix executor.
**Tech Stack:** Swift 6, SwiftPM, AppKit/Carbon/AX, Python только для build-time tooling.
**Spec:** ../specs/2026-10-20-macswitcher-design.md

## Ограничения
- macOS 13+, без новых runtime-зависимостей и отправки набранного текста.
- Один writer на файл; старое приложение не трогать при разработке.
- Публичный код MIT; FrequencyWords TSV CC BY-SA 4.0.
- Actions только ручной финальный запуск.

## Задачи и доказательства

- [x] Создать самостоятельный root, AGENTS и экспорт native-кода без приватной Git-истории.
- [x] Импортировать pinned частоты до 200k словоформ каждого языка; hashes/лицензия сверены.
- [x] Engine: `evaluate(suffix:sourceLanguage:atBoundary:precedingWords:)` возвращает точное
  предложение. Регрессии: `ghbdtn`, `levf.`, `xnj-nj`, `f привет`; отказы для
  `f(x)`, `press f`, API, MacSwitcher, email, URL, валидного English.
- [x] Runtime: invalidate pending edit после нового ввода/навигации/фокуса;
  проверять PID/поле/caret/revision/exact suffix; тесты stale/focus/cancel.
- [x] Product: своё имя/ID/icon/updater, dry-run migration, подписанная сборка
  с source SHA, проверка ресурсов внутри bundle вне исходного дерева.
- [x] Локальные регрессии: 71 Swift-тест; clipboard ownership, mixed TypedKey,
  event-linked caret и фактические карты раскладок включены в набор.
- [x] Public gate: secret/path scan, независимый review и подтверждённые исправления.
- [ ] Финальный выпуск: fresh test/build/CI, GitHub publication/read-back.
  Доказательства финального SHA — в GitHub Actions и metadata подписанного bundle;
  до их получения этот пункт остаётся открытым.
- [ ] Runtime/physical acceptance отмечать отдельно от unit/build; незакрытое — roadmap.

## На что смотреть при review
IME/secure input; переключение поля в том же PID; новый ввод в debounce window;
смешанная раскладка и paste; русское слово после намеренной клавиши `f`.
