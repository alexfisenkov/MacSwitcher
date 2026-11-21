# Происхождение MacSwitcher

MacSwitcher — независимый публичный проект Александра Фисенкова.
Нативная macOS-основа взята из [RuSwitcher](https://github.com/rashn/RuSwitcher),
MIT, Copyright (c) 2025 Rashns, release v3.4.0,
commit `2273b01ebb2f5e5f6ce5c729e1fdfaf3f165ace5`.
Уведомление и лицензия сохранены в `LICENSE`. Локальные доработки жестов Shift
экспортированы из проверяемого дерева `1448abf` без личной истории и настроек.

MacSwitcher имеет собственные имя и иконку и не является официальной сборкой
исходного проекта. Внутреннее имя Swift-модуля сохранено для совместимости тестов.
Частотные словари лицензируются отдельно: `dictionaries/NOTICE.md`.

## Идеи из Keyboop

Обнаружение чужого перехватчика клавиш (`RivalKeyboardTapWatch`) и предохранитель
от зацикливания автоисправления (`AutoCorrectionLoopGuard`) построены по идеям
[Keyboop](https://github.com/iffuno/keyboop) (`RivalTapWatch.swift`,
`AntiResonanceGuard.swift`), MIT, Copyright (c) 2026 Keyboop contributors:
перечень признаков чужого перехватчика, список системных путей и значения порогов
(0,7 с, шесть исправлений, пауза 2,5 с). Код написан заново для этого проекта.
