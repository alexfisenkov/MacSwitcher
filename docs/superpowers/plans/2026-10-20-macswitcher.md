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
- [ ] Импортировать pinned частоты до 200k словоформ каждого языка; сверить hashes/лицензию.
- [ ] Engine: `evaluate(suffix:sourceLanguage:atBoundary:precedingWords:)` возвращает точное
  предложение. Регрессии: `ghbdtn`, `levf.`, `xnj-nj`, `f привет`; отказы для
  `f(x)`, `press f`, API, MacSwitcher, email, URL, валидного English.
- [ ] Runtime: invalidate pending edit после нового ввода/навигации/фокуса;
  проверять PID/поле/caret/revision/exact suffix; тесты stale/focus/cancel.
- [ ] Product: своё имя/ID/icon/updater, dry-run migration, подписанная сборка
  с source SHA, проверка ресурсов внутри bundle вне исходного дерева.
- [ ] Public gate: secret/path scan, независимый code/risk/skeptic review,
  исправления, fresh swift test/build, GitHub publication/read-back.
- [ ] Runtime/physical acceptance отмечать отдельно от unit/build; незакрытое — roadmap.

## На что смотреть при review
IME/secure input; переключение поля в том же PID; новый ввод в debounce window;
смешанная раскладка и paste; русское слово после намеренной клавиши `f`.
