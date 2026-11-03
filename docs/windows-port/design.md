# Windows port — рабочий контракт

Основа: пользователь просит поведение macOS alpha.24 один в один: оба Shift, мгновенный одиночный, быстрый двойной 180 мс для последнего слова/выделения, повторное undo/redo, ранняя офлайн-коррекция, русский приоритет, локальные исключения и словарь, минимальное tray-меню. Windows 10 Intel/AMD — явная целевая машина; дополнительно нужны широкие версии Windows и проверки GitHub.

Решения исполнителя: одна Windows-ветка в существующем публичном репозитории, macOS не устанавливать/не менять. Windows GUI target net462 (Windows7SP1/8.1/10/11 при наличии .NET4.6.2+), Core multi-target net462;net10.0, cross-platform console tests net10.0, SDK10.0.403. AnyCPU exe для x86/x64; ARM64 только совместимость .NET4.8.1/эмуляции с отдельной непроверенной приёмкой. Windows8.0/XP/Vista не заявляются; не скрывать эту границу.

## Границы

- Core: чистые C# жесты/карта RU-EN/PredictionEngine (gold495 совместимость), словари и smart-selection. Частотные TSV и защищённые термины прежние; full/spelling SQLite преобразуются domain-script в sorted binary MSLEXW01 без внешней native-SQLite зависимости. Формат описывает отдельный файл contracts.md.
- Windows runtime: dedicated keyboard/mouse hook thread + быстрые callbacks, отдельный UIA broker process с ограниченными командами чтения и проверяемой адресной записи с ограниченным IPC/timeout. Пользовательский текст не пишется в лог/на диск, кроме явного локального recovery/export. Не блокировать hook ожиданием UIA. Пароль/secure desktop/read-only/unavailable/elevated target отсекаются до чтения/записи. Неподдерживаемые редакторы дают честный отказ.
- Native replacement: подготовить атомарную установку значения конкретного plain-text поля через UIA ValuePattern (или Win32 Edit) под кратким физическим read/write lease, сверив ту же HWND/PID/runtimeID/caret/revision/source. Выделение и последнее слово заменяются через адресный Win32 Edit/RichEdit range writer под кратким допуском: EM_SETSEL, подтверждение диапазона и EM_REPLACESEL; глобальный SendInput fallback не используется. Не использовать неподтверждённую клавиатурную навигацию для auto/последнего слова. Если ни atomically-addressed value writer, ни адресный range-writer недоступны — честный отказ, а не опасный fallback. Не подавлять физические буквы/не строить собственную replay-очередь. При частичном/неизвестном результате сохранить bounded RAM original и не повторять/не пробовать другой writer. Перед записью нет удерживаемых Command/Ctrl/Alt/Win/Shift.
- Source: выбрать RU/EN HKL адресно для captured foreground thread/window, подтвердить фактический GetKeyboardLayout. Не считать запрошенную раскладку фактом.
- UI/storage: WinForms family icon, минимальное tray-меню, доступные русские тексты без технических плашек. Settings/dictionary/exceptions в LocalAppData/MacSwitcherWindows; atomic validate/read-back/import/export. Никакой фоновой истории или обучения. Pause/quit/export должны сохранять pending originals.
- Permissions: asInvoker/uiAccess=false; обычным окнам админ не нужен; UIPI блокирует более высокий уровень. Только явная per-run команда может вызвать UAC, либо инструкция; никаких security bypass, скрытых admin tasks, служб. Start at login только user opt-in HKCU.
- Supply: per-user setup + portable zip, licences/sourceSHA/hash/version metadata, Windows-specific release tag/channel (не менять macOS version.json/appcast/release). Без Windows Authenticode-сертификата packages честно unsigned, не советовать отключать защиту.

## Приёмка

Итоговый workflow_dispatch Windows CI: core gold/gesture/safety tests, net462 app build, own synthetic WinForms edit/selection/undo/fast input/focus/password/failure probes on Windows runner, installer install/reinstall/uninstall preserving userdata, integrity/package checks and artifacts. Повторный прогон допустим после конкретного исправления обнаруженного отказа; история неудачных прогонов сохраняется. Physical Windows7/8.1/10/11/ARM and actual third-party apps NOT_RUN, hosted Windows Server is not that proof. No user Mac windows/key input tests.

Fixture регистрирует настоящие keyboard/mouse hooks, но изолирует их посторонние события от управляемого синтетического потока. Фиксированные команды проходят через production обработчик; отдельно проверяются отмена жеста сочетанием клавиш и последующее восстановление. Это интеграция runtime/UIA/native writer, а не доказательство физической доставки HID-событий.

## Владение

Parent owns root .gitignore, windows/AGENTS.md, docs/windows-port/, workflow/release coordination. Core worker owns windows/src/MacSwitcher.Core, windows/tests/MacSwitcher.Core.Tests and common core contracts. Runtime worker owns windows/src/MacSwitcher.Windows/{Native,Automation,Runtime}, Program.cs and windows/tests/MacSwitcher.Runtime.Tests. UI/package worker owns windows/src/MacSwitcher.Windows/{UI,Storage}, app csproj/manifest, windows/scripts/resources/installer, windows/README. No overlapping writers; interfaces agree before edits.

## Ограничения фактической Windows-реализации

Запись использует UIA ValuePattern для проверяемого plain Edit в конце поля либо HWND-адресный Edit/RichEdit range writer с подтверждением диапазона. Редакторы, которые не предоставляют точный текст/каретку/безопасный writer, дают отказ; наличие Windows-порта не означает универсальную совместимость всех приложений. Generic UIA выделение в середине поля без native range writer пока не поддержано. Стандартные раскладки: English US QWERTY и Russian ЙЦУКЕН; нестандартные варианты и IME не принимаются за них.

Исходники неизвестного результата хранятся только в bounded RAM. Явное восстановление требует полного выделения того же поля и точного совпадения с последним наблюдавшимся значением; неизвестное состояние или новые правки не перезаписываются старым исходником. Copy/Export доступны явно через меню. При аварийном завершении до экспорта RAM-исходник может потеряться; скрытого сохранения истории нет. Брокер не является read-only: он исполняет только ограниченные команды capture/verified value/range replacement по приватным дочерним IPC-потокам, с проверкой field/security/deadline и без логов текста.

Windows обновления — RSA-SHA256 signed manifest в windows/updates/windows.json, приватный ключ вне репозитория; подпись манифеста не является доверенной Authenticode-подписью Windows EXE. Запуск нового setup — только одноразовое явное согласие, обычный выход его не запускает. Источник пакета подтверждается ревизией Git и каноническим SHA-256 blob-дерева, не зависящим от ZIP-компрессии.

Windows workflow uses pinned official action commit SHAs, SDK10.0.403 via windows/global.json and run working-directory windows. Package output sourceSha256 is the canonical immutable Git tree digest, not ZIP serialization.

Упаковка требует чистого source checkout; generated data/bin/obj/publish/artifacts игнорируются. Бинарник проверяется в Windows CI отдельно от доказательства хеша Git-дерева. SDK global.json запрещает неявный roll-forward.

Hash-pinned dictionaries/resources are marked -text in .gitattributes so Windows autocrlf cannot alter TSV/notice/manifest bytes before validation.

## Границы короткой native-транзакции

В Windows CI полный повтор UIA-захвата внутри физического допуска превысил его бюджет: RPC занял 93 мс при допуске 90 мс. Бюджет не увеличивается. Для native Edit/RichEdit broker использует один собственный полный preflight не старше 500 мс, сверяет его с ожидаемым состоянием и потребляет однократно. Внутри допуска проверяет тот же HWND/PID/TID, раскладку, класс, доступность, password/read-only styles, полный native-текст и выделение; RuntimeId UIA проверяется до и после изменения. Исходный текст и позиции обычного Edit читаются через Unicode Win32 API одного HWND. Повторные дорогие чтения содержимого через UIA остаются снаружи допуска.

После попытки EM_SETSEL отказ уже не считается доказанным отсутствием изменений состояния поля. Если доставка самого EM_SETSEL неопределённа, дополнительные команды восстановления не отправляются. После подтверждённого изменения выделения его восстановление разрешено только до того же deadline, в том же поле и при точном совпадении текста, с ACK. Если подтверждения нет — Unknown, сохранение исходника и запрет повторной записи. Новые запросы восстановления после deadline не отправляются.

SendMessageTimeout не отменяет уже исполняемый обработчик чужого окна: при зависании он может завершиться после timeout. Поэтому Unknown не означает доказанного отсутствия изменения текста или выделения; исходник сохраняется в RAM, автоматическая повторная запись запрещена. Гарантия отмены уже отправленного сообщения не заявляется.
