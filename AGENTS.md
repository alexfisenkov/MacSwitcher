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
- Локальные Swift tests изолировать от личного словаря: `CFFIXED_USER_HOME="$(mktemp -d -t macswitcher-tests)" swift test --package-path macos -j 4` (переменная действует только на дочерний процесс; HOME не менять). Перед первым применением проверить Foundation applicationSupportDirectory в новом профиле.
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
- По явному разрешению владельца PR #4 интегрирован в main merge-коммитом `528e272c4ab208b0b4fd1062e47282e62d8e4f45`; исходники приложения совпадают с выпущенным `58a529f`. Сайт опубликован Pages `41648752742`, публичные HTML/иконка совпали побайтно, RU/EN desktop/mobile сценарии PASS. История первого отказа branch-policy сохранена в docs/website.md; защиты не меняли.

## Настройки и диагностика · 04.11.2026

- Текущий Mac-выпуск alpha.27, источник `96fd8207499b111fd5f5b7d383575517ba237473`, CI41717875604 PASS512Swift/35Python/gold495. Подписан, notarized, штатно установлен; sidebar/topalignment/клик/стрелки проверены, prefs+словарь+обучение сохранены.
- Alpha.26 содержала визуальный отступ коротких форм, выявленный после установки; alpha.27 исправила его с RED/Green геометрией. Дополнительный CI связан с конкретным дефектом; исходный артефакт26 сохранён.
- Прерывистый отказ автокоррекции после ручного исправления остаётся открытым. Диагностика повторных отказов ограничена закрытыми enum и существующим opt-in; никаких набранных слов/клавиш/clipboard в OSLog. Не выдавать новые regression PASS за доказательство исправления исходной жалобы.

## Бренд-контекст и undo · alpha.28 / Windows alpha.3

- Исходник e57592474d19bf2e93b73740fc32683542acc879, PR7 merged. MacCI41768184482 PASS535/35/gold495; WindowsCI41768189082 PASS769/gold495/runtime44 + contract/installer. Mac28 signed/notarized/stapled и штатно установлен, prefs/словари/180мс сохранены; Windows3 опубликована, RSA-feed проверен, EXE без Authenticode.
- Категории названий сохраняются в памяти; частотные строчные омонимы не нейтрализуют английский контекст. Подтверждённый undo сохраняет слово до границы и позволяет следующее; поле/source/pending/readonly/secure guards сохранены. Контракт docs/plans/2026-11-04-brand-context-priority.md.
- CLI benchmarks и локальные tests запускать в новом CFFIXED_USER_HOME: PersonalWordStore.shared использует фиксированный applicationSupport путь. Содержимое личного профиля не выводить/не использовать как fixture; финальная изолированная перепроверка535PASS, actual personal dictionary hash не изменился. GitHub runner fresh profile не является пользовательским профилем.


## Recovery capacity · 10.11.2026

- Подтверждено: старый29 глобально отказывал после8 RAM-исходников. Count8 проверен локально при штатном экспорте; тексты не выводились/не попадали в fixtures/Git.
- Локально установлен alpha.30/f0717815adbf9a7c9b9cb22f06126734bf2224f4, CI42656185041 PASS557/35/gold495, Developer ID/notarization/staple/Gatekeeper. UIAbout30 и новый opt-in ON подтверждены, остальные настройки/словари/200мс сохранены; физическая приёмка ожидается. PR10 слит (`2b1f52936556c69d033d92189ed2947199c21aa8`); alpha.30 опубликована, подписанный RSS проверен, Pages42816504804 развёрнут из `cca642f88d00ab869a9dcf8400d48f82394534c2` и публично сверен.
- Владелец явно разрешил отдельные автоматические локальные recovery-копии неподтверждённых замен, включая полное поле. Обычные нажатия/успешный ввод/сеть не архивируются; defaultOFF для других профилей. Это узкое согласие не отменяет запрет текстовых логов или публикации личных файлов. Канон docs/plans/2026-11-09-recovery-capacity.md.
- Перед освобождением RAM копия проверяется фоновой очередью; key/lease-путь не читает диск. Защита точного неопределённого поля сохраняется. Квоты конечны, без автоматического удаления.

## Адаптеры специальных полей · кандидат alpha.31

- Канон: docs/plans/2026-11-10-input-adapters.md; текущая физическая приёмка — docs/compatibility.md. Поддержка определяется возможностями поля, не списком имён приложений.
- SearchOverlayTarget.swift разделяет host события и фактическую плавающую AX-цель; неопределённость не разрешает редактировать подложку. Native-проверки и защита secure/readonly сохраняются. CGWindow scan синхронный и непрерываемый; deadline мягкий.
- TerminalBridge/ и Resources/terminal-zle.zsh — отдельный default-OFF ручной zsh/ZLE backend, exact BUFFER/nonce CAS без Enter/исполнения/clipboard. Поле отображения Terminal не превращается в изменяемый AX-документ.
- Подключение профиля и Automation требуют отдельного явного setup; при разработке использовать только временные профили и изолированные PTY. При перезапуске/переподключении может понадобиться новое окно/приглашение zsh. Не подставлять fake AX boundary в production.
- Shell-команды не дают adaptive-learning голосов. Обычное обучение и данные сохраняются; расширение shell word-only provenance — отдельный долг.
- После новой ревизии физического ввода разрешение shell CAS отзывается. Исходник резервируется до send; Quit не завершает приложение в середине неопределённой доставки. Подтверждённый архив освобождает RAM-текст, точная неизвестная линия остаётся защищённой.
- Изолированный общий локальный прогон: Swift642/Python36/gold495, release build PASS. CI, подпись, установка, профиль/TCC и реальная клавиатура для alpha.31 пока не подтверждены; не приравнивать synthetic PASS к поддержке всех приложений.

## Самодиагностика · кандидат alpha.31

- Канон: docs/plans/2026-11-10-runtime-health.md. RuntimeHealth/ — чистые metadata policy и offline synthetic runner; production использует прежний 2-с опрос и один MonitoringTapRecovery.
- Startup/manual self-check не обращается к реальным полям, TIS selection, clipboard, профилю или сети. Ready означает подключение обработчика, не проверенную доставку во всех приложениях. Автоматические статусы тихие; ручная кнопка в настройках.
- Tap retry: максимум5 failed starts/episode,3с; обычный poll не обнуляет exhausted. Shell retry: только перечисленные typed transient errno, максимум3/30с; unsafe/active/unknown failure требует действия. Нет forcedquit, auto TCC/profile edits, скрытого ввода или повтора неизвестной замены.
- Lease/CAS откладывает restart, сохранённые исходники/line locks не чистятся. Обычный клавиатурный callback при healthy tap/fence подтверждает уже наблюдённое возобновление ДО новой буквы; поздний профилактический restart не стирает свежий контекст. Mouse/scroll не являются таким ACK. Пропущенный для буфера физический key всё равно отзывает input revision/shell permit.
- Полностью не наблюдавшийся интервал защиты/блокировки между опросами не выводится из отсутствия событий. Реальные OS sleep/wake/TCC/keyboard остаются отдельной приёмкой. Два раунда health-критики выполнены; R2 BLOCK исправлен и проверен targeted-regression главным агентом, третьего раунда не запускали.

## Packaged shell resource · приёмка 11.11.2026

- Live preview первого31/62dced1 обнаружил Bundle.module build fallback. Установка shell отменена до записи; новые права не запрашивались, shell OFF. Само приложение31 работает, UI selfcheck4/4, настройки/хеши данных/200мс сохранены.
- Исправление: ShellBridgeProfilePatch в `.app` возвращает только canonical читаемый regular resource внутри собственного nested bundle; build fallback допустим только вне `.app`. main --self-test-resources проверяет фактический shell URL.
- Канон: docs/plans/2026-11-11-packaged-shell-resource.md. R2 review PASS; full646 и реальные cold packaged CLI positive0/negative2 (dev fallback доступен) PASS. Это причина дополнительного финального CI/нового signed artifact; прежний62dced1 и его receipt не перезаписывать.


## Текущий выпуск · 13.11.2026

- Alpha.31: source `b47273570ab457d933141cfa19f5bc26b34245bd`, финальная CI `43276285226` (671 Swift/36 Python/gold495), notarization принята; установленный процесс работает, 29 настроек и локальные файлы сохранены. Физическая клавиатурная приёмка не подтверждена.
- Alpha.31 опубликована и проверена: source `b47273570ab457d933141cfa19f5bc26b34245bd`, PR #11 merge `6a7ef40044cdacedd67e03bb61e8a6671b19b0fe`; release assets совпали, подписанный feed SHA `f40c33ef107c19f2f4c4c238411e27d128b4acf25a28ba9788992e043c41f053` byte-equal и Sparkle PASS. Pages run `43356600525` развернул source `dfe2d6785d2c34646177716849635f0a0aa6a85f`; home/legal/SVG HTTP 200 и byte-equal. Windows остаётся alpha.3.
- Следующий продуктовый этап ACTIVE: owner briefing/interview — первый шаг. Физическая клавиатурная приёмка не подтверждена; не объявлять её PASS.

## Alpha.32 · установлена и опубликована · 13.11.2026

- PR #12 слит; source `176c3919b8b23db1f097cd4e234286f69db3c92c`, merge `ccfc4ac522170c9c45ccf78ad989095cacd81860`; tag `v0.1.0-alpha.32` создан. Финальная CI `43385000693` PASS: 695 Swift (1 intentional preview-export skip), 36 Python, gold495.
- Универсальный ZIP 43,415,986 bytes, SHA-256 `8b1e8818d5dc9ce32b3a248cf66fdd3dcc3ec9a506c3f731fa4a1fae20f5d3f1`; Developer ID, notarization ACCEPTED/stapled, strict codesign, Sparkle signatures, stapler and Gatekeeper checks passed. Это подтверждение пакета, не публичной GitHub Release/feed/Pages доставки.
- Штатная установка alpha.31 → alpha.32 запущена с резервной копией предыдущего `.app`; normal quit и работающий процесс alpha.32 read-back подтверждены. Все 34 прежних preference keys неизменны; новые данные миграции V2 проверены; backup 11 gesture keys приватен и совпадает по digest; personal data hashes unchanged, словарь пользователя до установки отсутствовал. Auto ON, double-Shift 200 ms.
- Реальное установленное окно AppKit осмотрено: Guide открывается первой; Words, Settings и Support доступны; internal checks 4/4, keyboard monitor connected. Физические нажатия и матрица приложений не проверены. Terminal live bridge сейчас не подключён — для него нужен новый настроенный zsh prompt; personal word editors не открывались.
- GitHub prerelease `v0.1.0-alpha.32` и три assets опубликованы и анонимно перечитаны; размер/SHA всех assets совпал с кандидатом. Публичный feed SHA `a1ca22de611c8733f5f0ce4c6e97f9736d0a708e81d390c979a6a9e2a2c30676` byte-equal и Sparkle PASS. Pages `43389847510` SUCCESS из `c76c2d4c146175bd271c253c35eeb7d87b0b9466`; home/legal/SVG HTTP 200 и byte-equal. Windows alpha.3 не менялась. Подробности: `.журналы/alpha32-owner-install.json`, `.журналы/alpha32-package-delivery.json`, `.журналы/alpha32-public-delivery.json`.


## Alpha.33 · current status · 2026-11-14

PR #13 merged; source `0cac296290cb32bedf05e924e8136b730af634b9`, final CI `43429048841` success. Universal signed ZIP accepted by Apple, stapled; SHA-256 `fb62e6796068cd31945a34a11ac65ff22e2af0a30ca9b764dcb1ac0f624efacd`. Installed and running read-back confirmed; 39 settings and local data preserved. Owner gave brief positive feedback and explicitly authorized GitHub publication. GitHub prerelease and all three assets are PUBLISHED_VERIFIED by anonymous size/hash read-back; alpha.33 is the current public Mac release. Signed feed and Pages read-back are still pending. Physical scope remains limited: repeated gestures, long sessions, all apps, Spotlight, and Terminal are unverified. Limit the Codex claim to brief positive owner feedback; do not claim universal reliability or App Store / Windows updates. Evidence: `.журналы/alpha33-*.json`.
