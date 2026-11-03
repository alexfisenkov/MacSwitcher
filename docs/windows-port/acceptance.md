# Windows: приёмка и оставшаяся совместимость

Первый предварительный выпуск: [windows-v0.1.0-alpha.1](https://github.com/alexfisenkov/MacSwitcher/releases/tag/windows-v0.1.0-alpha.1), build1, source `7892dc51b8b80cb7628f272da436fce1b58ff875`. [CI22](https://github.com/alexfisenkov/MacSwitcher/actions/runs/41618728418) полностью прошёл. EXE/Setup unsigned в смысле Windows Authenticode; собственный update manifest подписан RSA-SHA256.

## Подтверждено

| Сценарий | Результат и граница |
| --- | --- |
| Core и словари | 562 assertions, включая все 495 gold-примеров; SHA/состав ресурсов проверены |
| Runtime | PASS44; регистрация hooks, controlled synthetic observer, UIA/native writer, отказ паролям/read-only/смене поля |
| Ручные жесты | Оба Shift, double180, слово/выделение, повторные undo/redo, неправильная текущая раскладка, без ожидания timer cache |
| Границы слова | Точный префикс, punctuation, trailing space/tab/CRLF, каретка и undo/redo; проверка oldPhrase==range |
| Автокоррекция | До пробела, продолжение слова, повтор после подтверждённого clear, быстрый burst и смена поля |
| Edge input/textarea | Собственные новые локальные страницы; direct broker и actual runtime PASS; DOM input/value/focus ACK; RPC31/16мс при прежнем бюджете90мс |
| Пакеты | Setup и portable, чистый source tree, AnyCPU IL-only/net462, SHA-256, MIT/словари/лицензии |
| Установка | Per-user install/reinstall/uninstall exit0, сохранение данных, welcome/settings/reopen, один primary+owned broker, normal quit0 |
| Публикация | Release packages и подписанный feed проверяются оператором по исходному manifest; журнал выпуска хранит read-back |

## Что не доказано

| Поверхность | Статус |
| --- | --- |
| Физический Shift/быстрый набор | NOT_RUN: controlled adapter не является HID-доставкой |
| Физические Windows 7 SP1/8.1/10/11 | NOT_RUN; net462/AnyCPU — совместимость по target/API, CI — hosted Windows Server2025 |
| x86 и ARM64 hardware | NOT_RUN; ARM64 не объявлен принятой платформой |
| Chrome, Codex, Claude, Telegram, Word, прочие реальные редакторы | NOT_RUN; одинаковый framework не доказывает работу конкретного поля |
| DPI125/150%, IME, нестандартные раскладки | NOT_RUN; поддерживаются только стандартные US QWERTY и Russian ЙЦУКЕН |
| Styled rich text и сложные multi-thread/native-focus proxies | NOT_RUN; generic middle-selection без native range writer не поддерживается |

XP/Vista/Windows8.0 не входят в первый выпуск. Secure desktop/UAC/password/read-only/иной пользовательский сеанс не обходятся. Для elevated target требуется явный запуск той же программы с соответствующими правами. Если editor не предоставляет точный безопасный writer, применяется отказ, а не глобальный SendInput.

## Следующая проверка владельцем

На целевой Windows10 Intel/AMD: оба коротких Shift, неверно набранное слово с пробелом и без него, выделенная фраза, несколько undo/redo, следующее слово, быстрое продолжение ввода. Далее конкретные ежедневные приложения и поля; результаты фиксировать отдельно от общего CI. Длительный рабочий сеанс остаётся обязательным до заявления о стабильности.

## Открытый долг

- Физическая матрица ОС/архитектур/приложений и длительный сеанс.
- Authenticode code-signing и репутация распространения Windows; сертификат не приобретён.
- Отдельная приёмка форматированного текста, multi-thread GUI и нестандартных layout variants.
- UI пока предлагает управление исключениями через настройки; автоматическое предложение исключения после Undo — отдельная доработка parity.
- Source остаётся в PR #3 до просмотра владельцем; релиз закреплён immutable tag, каналы платформ разделены.

Неудачные CI до22 сохраняются; CI15 PASS30 не считается выпуском из-за найденного позже trailing-space source-span bug. Разбор критиков не заменяет проверки артефакта, подписи и факта публикации.
