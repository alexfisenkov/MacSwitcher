// Переводы на 16 языков (порядок: en, ru, de, fr, es, pt, zh, ja, ko, uk, pl, be, el, bg, hy, ka).
// Проверка работы и подсказка в строке меню.

extension L10n {
    static let healthStrings: [String: [String]] = [
        "health.sleeping": [
            "MacSwitcher: waking up", // en
            "MacSwitcher: выход из сна", // ru
            "MacSwitcher: wird aus dem Ruhezustand geholt", // de
            "MacSwitcher: reprise après la mise en veille", // fr
            "MacSwitcher: saliendo de la suspensión", // es
            "MacSwitcher: a sair da suspensão", // pt
            "MacSwitcher: 正在唤醒", // zh
            "MacSwitcher: スリープから復帰中", // ja
            "MacSwitcher: 잠자기에서 깨어나는 중", // ko
            "MacSwitcher: вихід зі сну", // uk
            "MacSwitcher: wybudzanie", // pl
            "MacSwitcher: выхад са сну", // be
            "MacSwitcher: αφύπνιση", // el
            "MacSwitcher: излизане от режим на заспиване", // bg
            "MacSwitcher: արթնանում է", // hy
            "MacSwitcher: იღვიძებს", // ka
        ],
        "health.permissionsRequired": [
            "MacSwitcher: check permissions", // en
            "MacSwitcher: проверьте разрешения", // ru
            "MacSwitcher: Berechtigungen prüfen", // de
            "MacSwitcher: vérifiez les autorisations", // fr
            "MacSwitcher: revisa los permisos", // es
            "MacSwitcher: verifique as permissões", // pt
            "MacSwitcher: 请检查权限", // zh
            "MacSwitcher: 権限を確認してください", // ja
            "MacSwitcher: 권한을 확인하세요", // ko
            "MacSwitcher: перевірте дозволи", // uk
            "MacSwitcher: sprawdź uprawnienia", // pl
            "MacSwitcher: праверце дазволы", // be
            "MacSwitcher: ελέγξτε τα δικαιώματα", // el
            "MacSwitcher: проверете разрешенията", // bg
            "MacSwitcher: ստուգեք թույլտվությունները", // hy
            "MacSwitcher: შეამოწმეთ ნებართვები", // ka
        ],
        "health.secureInput": [
            "MacSwitcher: Secure Input", // en
            "MacSwitcher: защищённый ввод", // ru
            "MacSwitcher: Sichere Eingabe", // de
            "MacSwitcher: saisie sécurisée", // fr
            "MacSwitcher: entrada segura", // es
            "MacSwitcher: entrada segura", // pt
            "MacSwitcher: 安全输入", // zh
            "MacSwitcher: セキュア入力", // ja
            "MacSwitcher: 보안 입력", // ko
            "MacSwitcher: захищене введення", // uk
            "MacSwitcher: bezpieczne wprowadzanie", // pl
            "MacSwitcher: абаронены ўвод", // be
            "MacSwitcher: ασφαλής εισαγωγή", // el
            "MacSwitcher: защитено въвеждане", // bg
            "MacSwitcher: պաշտպանված մուտքագրում", // hy
            "MacSwitcher: დაცული შეყვანა", // ka
        ],
        "health.editDeferred": [
            "MacSwitcher: recovery deferred", // en
            "MacSwitcher: восстановление отложено", // ru
            "MacSwitcher: Wiederherstellung aufgeschoben", // de
            "MacSwitcher: récupération différée", // fr
            "MacSwitcher: recuperación aplazada", // es
            "MacSwitcher: recuperação adiada", // pt
            "MacSwitcher: 恢复已推迟", // zh
            "MacSwitcher: 復元を保留中", // ja
            "MacSwitcher: 복구가 보류됨", // ko
            "MacSwitcher: відновлення відкладено", // uk
            "MacSwitcher: odzyskiwanie odroczone", // pl
            "MacSwitcher: аднаўленне адкладзена", // be
            "MacSwitcher: η ανάκτηση αναβλήθηκε", // el
            "MacSwitcher: възстановяването е отложено", // bg
            "MacSwitcher: վերականգնումը հետաձգված է", // hy
            "MacSwitcher: აღდგენა გადადებულია", // ka
        ],
        "health.tapUnavailable": [
            "MacSwitcher: keyboard connection unavailable", // en
            "MacSwitcher: нет подключения к клавиатуре", // ru
            "MacSwitcher: keine Verbindung zur Tastatur", // de
            "MacSwitcher: connexion au clavier indisponible", // fr
            "MacSwitcher: conexión con el teclado no disponible", // es
            "MacSwitcher: ligação ao teclado indisponível", // pt
            "MacSwitcher: 无法连接键盘", // zh
            "MacSwitcher: キーボードに接続できません", // ja
            "MacSwitcher: 키보드에 연결할 수 없음", // ko
            "MacSwitcher: немає підключення до клавіатури", // uk
            "MacSwitcher: brak połączenia z klawiaturą", // pl
            "MacSwitcher: няма падключэння да клавіятуры", // be
            "MacSwitcher: μη διαθέσιμη σύνδεση πληκτρολογίου", // el
            "MacSwitcher: няма връзка с клавиатурата", // bg
            "MacSwitcher: ստեղնաշարին միացում չկա", // hy
            "MacSwitcher: კლავიატურასთან კავშირი არ არის", // ka
        ],
        "health.shellRecovering": [
            "MacSwitcher: terminal connection recovering", // en
            "MacSwitcher: подключение терминала восстанавливается", // ru
            "MacSwitcher: Terminalverbindung wird wiederhergestellt", // de
            "MacSwitcher: reconnexion au terminal en cours", // fr
            "MacSwitcher: recuperando la conexión del terminal", // es
            "MacSwitcher: a recuperar a ligação ao terminal", // pt
            "MacSwitcher: 正在恢复终端连接", // zh
            "MacSwitcher: ターミナルとの接続を回復中", // ja
            "MacSwitcher: 터미널 연결 복구 중", // ko
            "MacSwitcher: підключення термінала відновлюється", // uk
            "MacSwitcher: przywracanie połączenia z terminalem", // pl
            "MacSwitcher: падключэнне тэрмінала аднаўляецца", // be
            "MacSwitcher: επαναφορά σύνδεσης τερματικού", // el
            "MacSwitcher: връзката с терминала се възстановява", // bg
            "MacSwitcher: տերմինալի կապը վերականգնվում է", // hy
            "MacSwitcher: ტერმინალის კავშირი აღდგება", // ka
        ],
        "health.shellNeedsUserAction": [
            "MacSwitcher: check terminal connection", // en
            "MacSwitcher: проверьте подключение терминала", // ru
            "MacSwitcher: Terminalverbindung prüfen", // de
            "MacSwitcher: vérifiez la connexion au terminal", // fr
            "MacSwitcher: revisa la conexión del terminal", // es
            "MacSwitcher: verifique a ligação ao terminal", // pt
            "MacSwitcher: 请检查终端连接", // zh
            "MacSwitcher: ターミナルの接続を確認してください", // ja
            "MacSwitcher: 터미널 연결을 확인하세요", // ko
            "MacSwitcher: перевірте підключення термінала", // uk
            "MacSwitcher: sprawdź połączenie z terminalem", // pl
            "MacSwitcher: праверце падключэнне тэрмінала", // be
            "MacSwitcher: ελέγξτε τη σύνδεση τερματικού", // el
            "MacSwitcher: проверете връзката с терминала", // bg
            "MacSwitcher: ստուգեք տերմինալի կապը", // hy
            "MacSwitcher: შეამოწმეთ ტერმინალის კავშირი", // ka
        ],
        "health.unconfirmedEdit": [
            "MacSwitcher: an edit is unconfirmed", // en
            "MacSwitcher: есть неподтверждённая правка", // ru
            "MacSwitcher: eine Änderung ist unbestätigt", // de
            "MacSwitcher: une modification n’est pas confirmée", // fr
            "MacSwitcher: hay un cambio sin confirmar", // es
            "MacSwitcher: há uma alteração por confirmar", // pt
            "MacSwitcher: 有未确认的修改", // zh
            "MacSwitcher: 未確認の変更があります", // ja
            "MacSwitcher: 확인되지 않은 수정이 있음", // ko
            "MacSwitcher: є непідтверджена правка", // uk
            "MacSwitcher: jest niepotwierdzona zmiana", // pl
            "MacSwitcher: ёсць непацверджаная праўка", // be
            "MacSwitcher: υπάρχει μη επιβεβαιωμένη αλλαγή", // el
            "MacSwitcher: има непотвърдена промяна", // bg
            "MacSwitcher: կա չհաստատված փոփոխություն", // hy
            "MacSwitcher: არის დაუდასტურებელი ცვლილება", // ka
        ],
        "health.selfCheckFailed": [
            "MacSwitcher: internal check failed", // en
            "MacSwitcher: внутренняя проверка не прошла", // ru
            "MacSwitcher: interne Prüfung fehlgeschlagen", // de
            "MacSwitcher: échec de la vérification interne", // fr
            "MacSwitcher: falló la comprobación interna", // es
            "MacSwitcher: a verificação interna falhou", // pt
            "MacSwitcher: 内部检查未通过", // zh
            "MacSwitcher: 内部チェックに失敗しました", // ja
            "MacSwitcher: 내부 점검에 실패함", // ko
            "MacSwitcher: внутрішня перевірка не пройшла", // uk
            "MacSwitcher: wewnętrzna kontrola nie powiodła się", // pl
            "MacSwitcher: унутраная праверка не прайшла", // be
            "MacSwitcher: ο εσωτερικός έλεγχος απέτυχε", // el
            "MacSwitcher: вътрешната проверка не премина", // bg
            "MacSwitcher: ներքին ստուգումը չանցավ", // hy
            "MacSwitcher: შიდა შემოწმება ვერ გაიარა", // ka
        ],
        "check.title": [
            "MacSwitcher check", // en
            "Проверка MacSwitcher", // ru
            "MacSwitcher-Prüfung", // de
            "Vérification de MacSwitcher", // fr
            "Comprobación de MacSwitcher", // es
            "Verificação do MacSwitcher", // pt
            "MacSwitcher 检查", // zh
            "MacSwitcher のチェック", // ja
            "MacSwitcher 점검", // ko
            "Перевірка MacSwitcher", // uk
            "Kontrola MacSwitcher", // pl
            "Праверка MacSwitcher", // be
            "Έλεγχος MacSwitcher", // el
            "Проверка на MacSwitcher", // bg
            "MacSwitcher-ի ստուգում", // hy
            "MacSwitcher-ის შემოწმება", // ka
        ],
        "check.off": [
            "Processing is off in settings.", // en
            "Обработка выключена в настройках.", // ru
            "Die Verarbeitung ist in den Einstellungen ausgeschaltet.", // de
            "Le traitement est désactivé dans les réglages.", // fr
            "El procesamiento está desactivado en los ajustes.", // es
            "O processamento está desativado nas definições.", // pt
            "处理功能已在设置中关闭。", // zh
            "設定で処理がオフになっています。", // ja
            "설정에서 처리가 꺼져 있습니다.", // ko
            "Обробку вимкнено в налаштуваннях.", // uk
            "Przetwarzanie jest wyłączone w ustawieniach.", // pl
            "Апрацоўка выключана ў наладах.", // be
            "Η επεξεργασία είναι απενεργοποιημένη στις ρυθμίσεις.", // el
            "Обработката е изключена в настройките.", // bg
            "Մշակումն անջատված է կարգավորումներում։", // hy
            "დამუშავება პარამეტრებში გამორთულია.", // ka
        ],
        "check.sleeping": [
            "The Mac is waking up.", // en
            "Компьютер выходит из сна.", // ru
            "Der Mac wird aus dem Ruhezustand geholt.", // de
            "Le Mac sort de veille.", // fr
            "El Mac está saliendo de la suspensión.", // es
            "O Mac está a sair da suspensão.", // pt
            "Mac 正在唤醒。", // zh
            "Mac がスリープから復帰しています。", // ja
            "Mac이 잠자기에서 깨어나는 중입니다.", // ko
            "Комп’ютер виходить зі сну.", // uk
            "Mac się wybudza.", // pl
            "Камп’ютар выходзіць са сну.", // be
            "Το Mac ξυπνά.", // el
            "Mac излиза от режим на заспиване.", // bg
            "Mac-ը արթնանում է։", // hy
            "Mac იღვიძებს.", // ka
        ],
        "check.permissionsRequired": [
            "Check Accessibility and Input Monitoring permissions.", // en
            "Проверьте разрешения «Универсальный доступ» и «Мониторинг ввода».", // ru
            "Prüfen Sie die Berechtigungen „Bedienungshilfen“ und „Eingabeüberwachung“.", // de
            "Vérifiez les autorisations « Accessibilité » et « Surveillance de l’entrée ».", // fr
            "Revisa los permisos «Accesibilidad» y «Monitorización de entrada».", // es
            "Verifique as permissões «Acessibilidade» e «Monitorização de entrada».", // pt
            "请检查“辅助功能”和“输入监控”权限。", // zh
            "「アクセシビリティ」と「入力監視」の許可を確認してください。", // ja
            "“손쉬운 사용” 및 “입력 모니터링” 권한을 확인하세요.", // ko
            "Перевірте дозволи «Універсальний доступ» і «Моніторинг введення».", // uk
            "Sprawdź uprawnienia „Dostępność” i „Monitorowanie wprowadzania”.", // pl
            "Праверце дазволы «Універсальны доступ» і «Маніторынг уводу».", // be
            "Ελέγξτε τα δικαιώματα «Προσβασιμότητα» και «Παρακολούθηση εισόδου».", // el
            "Проверете разрешенията «Достъпност» и «Наблюдение на въвеждането».", // bg
            "Ստուգեք «Մատչելիություն» և «Մուտքի մոնիթորինգ» թույլտվությունները։", // hy
            "შეამოწმეთ ნებართვები: «ხელმისაწვდომობა» და «შეყვანის მონიტორინგი».", // ka
        ],
        "check.secureInput": [
            "Secure Input has paused processing.", // en
            "Защищённый ввод временно приостановил обработку.", // ru
            "Die sichere Eingabe hat die Verarbeitung angehalten.", // de
            "La saisie sécurisée a suspendu le traitement.", // fr
            "La entrada segura ha pausado el procesamiento.", // es
            "A entrada segura pausou o processamento.", // pt
            "安全输入已暂停处理。", // zh
            "セキュア入力により処理が一時停止されました。", // ja
            "보안 입력으로 인해 처리가 일시 중지되었습니다.", // ko
            "Захищене введення тимчасово призупинило обробку.", // uk
            "Bezpieczne wprowadzanie wstrzymało przetwarzanie.", // pl
            "Абаронены ўвод часова прыпыніў апрацоўку.", // be
            "Η ασφαλής εισαγωγή διέκοψε την επεξεργασία.", // el
            "Защитеното въвеждане временно спря обработката.", // bg
            "Պաշտպանված մուտքագրումը ժամանակավորապես կասեցրել է մշակումը։", // hy
            "დაცულმა შეყვანამ დამუშავება დროებით შეაჩერა.", // ka
        ],
        "check.editDeferred": [
            "An edit is in progress; recovery is deferred.", // en
            "Идёт редактирование; восстановление отложено.", // ru
            "Eine Änderung läuft; die Wiederherstellung ist aufgeschoben.", // de
            "Une modification est en cours ; la récupération est différée.", // fr
            "Hay una edición en curso; la recuperación se aplaza.", // es
            "Está em curso uma edição; a recuperação foi adiada.", // pt
            "正在进行编辑；恢复已推迟。", // zh
            "編集中のため、復元は保留されています。", // ja
            "수정이 진행 중이며 복구가 보류되었습니다.", // ko
            "Триває редагування; відновлення відкладено.", // uk
            "Trwa edycja; odzyskiwanie jest odroczone.", // pl
            "Ідзе рэдагаванне; аднаўленне адкладзена.", // be
            "Μια επεξεργασία βρίσκεται σε εξέλιξη· η ανάκτηση αναβλήθηκε.", // el
            "Извършва се редакция; възстановяването е отложено.", // bg
            "Խմբագրումը ընթացքի մեջ է. վերականգնումը հետաձգված է։", // hy
            "მიმდინარეობს რედაქტირება; აღდგენა გადადებულია.", // ka
        ],
        "check.tapExhausted": [
            "MacSwitcher cannot receive keys. Check permissions and run the check again.", // en
            "MacSwitcher не получает нажатия. Проверьте разрешения и попробуйте проверку ещё раз.", // ru
            "MacSwitcher empfängt keine Tastenanschläge. Prüfen Sie die Berechtigungen und wiederholen Sie die Prüfung.", // de
            "MacSwitcher ne reçoit pas les frappes. Vérifiez les autorisations et relancez la vérification.", // fr
            "MacSwitcher no recibe las pulsaciones. Revisa los permisos y vuelve a ejecutar la comprobación.", // es
            "O MacSwitcher não recebe as teclas. Verifique as permissões e execute a verificação novamente.", // pt
            "MacSwitcher 无法接收按键。请检查权限并重新运行检查。", // zh
            "MacSwitcher がキー入力を受け取れません。権限を確認して、もう一度チェックしてください。", // ja
            "MacSwitcher가 키 입력을 받지 못합니다. 권한을 확인하고 점검을 다시 실행하세요.", // ko
            "MacSwitcher не отримує натискань. Перевірте дозволи й повторіть перевірку.", // uk
            "MacSwitcher nie odbiera naciśnięć klawiszy. Sprawdź uprawnienia i uruchom kontrolę ponownie.", // pl
            "MacSwitcher не атрымлівае націскі. Праверце дазволы і паўтарыце праверку.", // be
            "Το MacSwitcher δεν λαμβάνει πατήματα πλήκτρων. Ελέγξτε τα δικαιώματα και εκτελέστε ξανά τον έλεγχο.", // el
            "MacSwitcher не получава натисканията. Проверете разрешенията и стартирайте проверката отново.", // bg
            "MacSwitcher-ը ստեղների սեղմումներ չի ստանում։ Ստուգեք թույլտվությունները և նորից կատարեք ստուգումը։", // hy
            "MacSwitcher კლავიშების დაჭერებს ვერ იღებს. შეამოწმეთ ნებართვები და შემოწმება გაიმეორეთ.", // ka
        ],
        "check.tapConnecting": [
            "MacSwitcher is not connected to the keyboard yet; checking again.", // en
            "MacSwitcher пока не подключён к клавиатуре; повторяем проверку.", // ru
            "MacSwitcher ist noch nicht mit der Tastatur verbunden; die Prüfung wird wiederholt.", // de
            "MacSwitcher n’est pas encore connecté au clavier ; nouvelle vérification en cours.", // fr
            "MacSwitcher aún no está conectado al teclado; se vuelve a comprobar.", // es
            "O MacSwitcher ainda não está ligado ao teclado; a verificar novamente.", // pt
            "MacSwitcher 尚未连接键盘；正在重新检查。", // zh
            "MacSwitcher はまだキーボードに接続されていません。再確認しています。", // ja
            "MacSwitcher가 아직 키보드에 연결되지 않았습니다. 다시 확인하는 중입니다.", // ko
            "MacSwitcher ще не підключений до клавіатури; повторюємо перевірку.", // uk
            "MacSwitcher nie jest jeszcze połączony z klawiaturą; sprawdzam ponownie.", // pl
            "MacSwitcher пакуль не падключаны да клавіятуры; паўтараем праверку.", // be
            "Το MacSwitcher δεν έχει συνδεθεί ακόμη με το πληκτρολόγιο· γίνεται νέος έλεγχος.", // el
            "MacSwitcher още не е свързан с клавиатурата; проверката се повтаря.", // bg
            "MacSwitcher-ը դեռ միացված չէ ստեղնաշարին. կրկին ստուգվում է։", // hy
            "MacSwitcher ჯერ არ არის დაკავშირებული კლავიატურასთან; ვამოწმებთ ხელახლა.", // ka
        ],
        "check.shellRecovering": [
            "The terminal connection is temporarily unavailable; retries are limited.", // en
            "Подключение терминала временно недоступно; число повторов ограничено.", // ru
            "Die Terminalverbindung ist vorübergehend nicht verfügbar; die Anzahl der Versuche ist begrenzt.", // de
            "La connexion au terminal est temporairement indisponible ; le nombre de tentatives est limité.", // fr
            "La conexión del terminal no está disponible temporalmente; los reintentos son limitados.", // es
            "A ligação ao terminal está temporariamente indisponível; as tentativas são limitadas.", // pt
            "终端连接暂时不可用；重试次数有限。", // zh
            "ターミナルとの接続が一時的に利用できません。再試行の回数には上限があります。", // ja
            "터미널 연결을 일시적으로 사용할 수 없습니다. 재시도 횟수는 제한됩니다.", // ko
            "Підключення термінала тимчасово недоступне; кількість повторів обмежена.", // uk
            "Połączenie z terminalem jest tymczasowo niedostępne; liczba prób jest ograniczona.", // pl
            "Падключэнне тэрмінала часова недаступнае; колькасць паўтораў абмежавана.", // be
            "Η σύνδεση τερματικού δεν είναι προσωρινά διαθέσιμη· οι επαναλήψεις είναι περιορισμένες.", // el
            "Връзката с терминала временно не е налична; опитите са ограничени.", // bg
            "Տերմինալի կապը ժամանակավորապես անհասանելի է. կրկնությունների թիվը սահմանափակ է։", // hy
            "ტერმინალის კავშირი დროებით მიუწვდომელია; განმეორებათა რაოდენობა შეზღუდულია.", // ka
        ],
        "check.shellNeedsUserAction": [
            "Check the terminal connection and tab access.", // en
            "Проверьте подключение терминала и доступ к вкладке.", // ru
            "Prüfen Sie die Terminalverbindung und den Zugriff auf den Tab.", // de
            "Vérifiez la connexion au terminal et l’accès à l’onglet.", // fr
            "Revisa la conexión del terminal y el acceso a la pestaña.", // es
            "Verifique a ligação ao terminal e o acesso ao separador.", // pt
            "请检查终端连接和标签页访问权限。", // zh
            "ターミナルの接続とタブへのアクセスを確認してください。", // ja
            "터미널 연결과 탭 접근 권한을 확인하세요.", // ko
            "Перевірте підключення термінала й доступ до вкладки.", // uk
            "Sprawdź połączenie z terminalem i dostęp do karty.", // pl
            "Праверце падключэнне тэрмінала і доступ да ўкладкі.", // be
            "Ελέγξτε τη σύνδεση τερματικού και την πρόσβαση στην καρτέλα.", // el
            "Проверете връзката с терминала и достъпа до раздела.", // bg
            "Ստուգեք տերմինալի կապը և ներդիրին հասանելիությունը։", // hy
            "შეამოწმეთ ტერმინალის კავშირი და ჩანართზე წვდომა.", // ka
        ],
        "check.unconfirmedEdit": [
            "An edit is unconfirmed. Check the original text in the recovery menu.", // en
            "Есть неподтверждённая замена. Проверьте исходный текст в меню восстановления.", // ru
            "Eine Änderung ist unbestätigt. Prüfen Sie den Originaltext im Wiederherstellungsmenü.", // de
            "Une modification n’est pas confirmée. Vérifiez le texte original dans le menu de récupération.", // fr
            "Hay un cambio sin confirmar. Revisa el texto original en el menú de recuperación.", // es
            "Há uma alteração por confirmar. Verifique o texto original no menu de recuperação.", // pt
            "有未确认的修改。请在恢复菜单中检查原文。", // zh
            "未確認の変更があります。復元メニューで元のテキストを確認してください。", // ja
            "확인되지 않은 수정이 있습니다. 복구 메뉴에서 원본 텍스트를 확인하세요.", // ko
            "Є непідтверджена заміна. Перевірте початковий текст у меню відновлення.", // uk
            "Jest niepotwierdzona zmiana. Sprawdź tekst oryginalny w menu odzyskiwania.", // pl
            "Ёсць непацверджаная замена. Праверце зыходны тэкст у меню аднаўлення.", // be
            "Υπάρχει μη επιβεβαιωμένη αλλαγή. Ελέγξτε το αρχικό κείμενο στο μενού ανάκτησης.", // el
            "Има непотвърдена промяна. Проверете оригиналния текст в менюто за възстановяване.", // bg
            "Կա չհաստատված փոփոխություն։ Ստուգեք սկզբնական տեքստը վերականգնման ընտրացանկում։", // hy
            "არის დაუდასტურებელი ცვლილება. შეამოწმეთ საწყისი ტექსტი აღდგენის მენიუში.", // ka
        ],
        "check.connected": [
            "MacSwitcher is connected to the keyboard.", // en
            "MacSwitcher подключён к клавиатуре.", // ru
            "MacSwitcher ist mit der Tastatur verbunden.", // de
            "MacSwitcher est connecté au clavier.", // fr
            "MacSwitcher está conectado al teclado.", // es
            "O MacSwitcher está ligado ao teclado.", // pt
            "MacSwitcher 已连接键盘。", // zh
            "MacSwitcher はキーボードに接続されています。", // ja
            "MacSwitcher가 키보드에 연결되어 있습니다.", // ko
            "MacSwitcher підключений до клавіатури.", // uk
            "MacSwitcher jest połączony z klawiaturą.", // pl
            "MacSwitcher падключаны да клавіятуры.", // be
            "Το MacSwitcher είναι συνδεδεμένο με το πληκτρολόγιο.", // el
            "MacSwitcher е свързан с клавиатурата.", // bg
            "MacSwitcher-ը միացված է ստեղնաշարին։", // hy
            "MacSwitcher დაკავშირებულია კლავიატურასთან.", // ka
        ],
        "check.selfCheckFailed": [
            "An internal check failed.", // en
            "Внутренняя проверка не прошла.", // ru
            "Eine interne Prüfung ist fehlgeschlagen.", // de
            "Une vérification interne a échoué.", // fr
            "Falló una comprobación interna.", // es
            "Uma verificação interna falhou.", // pt
            "内部检查未通过。", // zh
            "内部チェックに失敗しました。", // ja
            "내부 점검에 실패했습니다.", // ko
            "Внутрішня перевірка не пройшла.", // uk
            "Wewnętrzna kontrola nie powiodła się.", // pl
            "Унутраная праверка не прайшла.", // be
            "Ένας εσωτερικός έλεγχος απέτυχε.", // el
            "Вътрешна проверка не премина.", // bg
            "Ներքին ստուգումը չանցավ։", // hy
            "შიდა შემოწმება ვერ გაიარა.", // ka
        ],
        "check.detail": [
            "%1$@\n\nInternal checks: %2$d/%3$d. They do not test typing in other apps.", // en
            "%1$@\n\nВнутренние проверки: %2$d/%3$d. Они не проверяют ввод в других приложениях.", // ru
            "%1$@\n\nInterne Prüfungen: %2$d/%3$d. Sie testen nicht die Eingabe in anderen Apps.", // de
            "%1$@\n\nVérifications internes : %2$d/%3$d. Elles ne testent pas la saisie dans d’autres apps.", // fr
            "%1$@\n\nComprobaciones internas: %2$d/%3$d. No prueban la escritura en otras apps.", // es
            "%1$@\n\nVerificações internas: %2$d/%3$d. Não testam a escrita noutras apps.", // pt
            "%1$@\n\n内部检查：%2$d/%3$d。这些检查不会测试其他应用中的输入。", // zh
            "%1$@\n\n内部チェック：%2$d/%3$d。他のアプリでの入力はテストしません。", // ja
            "%1$@\n\n내부 점검: %2$d/%3$d. 다른 앱에서의 입력은 점검하지 않습니다.", // ko
            "%1$@\n\nВнутрішні перевірки: %2$d/%3$d. Вони не перевіряють введення в інших застосунках.", // uk
            "%1$@\n\nKontrole wewnętrzne: %2$d/%3$d. Nie sprawdzają pisania w innych aplikacjach.", // pl
            "%1$@\n\nУнутраныя праверкі: %2$d/%3$d. Яны не правяраюць увод у іншых праграмах.", // be
            "%1$@\n\nΕσωτερικοί έλεγχοι: %2$d/%3$d. Δεν δοκιμάζουν την πληκτρολόγηση σε άλλες εφαρμογές.", // el
            "%1$@\n\nВътрешни проверки: %2$d/%3$d. Те не тестват въвеждането в други приложения.", // bg
            "%1$@\n\nՆերքին ստուգումներ՝ %2$d/%3$d։ Դրանք չեն ստուգում այլ հավելվածներում մուտքագրումը։", // hy
            "%1$@\n\nშიდა შემოწმებები: %2$d/%3$d. ისინი სხვა აპებში აკრეფას არ ამოწმებს.", // ka
        ],
        "check.shellNone": [
            "\n\nTerminal: no prompt is connected now. Check setup and open a new window if needed.", // en
            "\n\nТерминал: сейчас нет подключения. При необходимости проверьте настройку и откройте новое окно.", // ru
            "\n\nTerminal: derzeit ist keine Eingabeaufforderung verbunden. Prüfen Sie die Einrichtung und öffnen Sie bei Bedarf ein neues Fenster.", // de
            "\n\nTerminal : aucune invite n’est connectée pour le moment. Vérifiez la configuration et ouvrez une nouvelle fenêtre si besoin.", // fr
            "\n\nTerminal: ahora mismo no hay ningún prompt conectado. Revisa la configuración y abre una ventana nueva si hace falta.", // es
            "\n\nTerminal: neste momento não há nenhum prompt ligado. Verifique a configuração e abra uma nova janela, se necessário.", // pt
            "\n\n终端：当前没有已连接的提示符。请检查设置，必要时打开新窗口。", // zh
            "\n\nターミナル：現在接続されているプロンプトはありません。設定を確認し、必要に応じて新しいウインドウを開いてください。", // ja
            "\n\n터미널: 현재 연결된 프롬프트가 없습니다. 설정을 확인하고 필요하면 새 창을 여세요.", // ko
            "\n\nТермінал: зараз немає підключення. За потреби перевірте налаштування й відкрийте нове вікно.", // uk
            "\n\nTerminal: obecnie nie ma połączonego wiersza poleceń. Sprawdź konfigurację i w razie potrzeby otwórz nowe okno.", // pl
            "\n\nТэрмінал: зараз няма падключэння. Пры неабходнасці праверце налады і адкрыйце новае акно.", // be
            "\n\nΤερματικό: δεν υπάρχει συνδεδεμένη γραμμή εντολών αυτή τη στιγμή. Ελέγξτε τη ρύθμιση και ανοίξτε νέο παράθυρο αν χρειάζεται.", // el
            "\n\nТерминал: в момента няма свързан команден ред. При нужда проверете настройката и отворете нов прозорец.", // bg
            "\n\nՏերմինալ. այս պահին միացված հրամանի տող չկա։ Անհրաժեշտության դեպքում ստուգեք կարգավորումը և բացեք նոր պատուհան։", // hy
            "\n\nტერმინალი: ახლა დაკავშირებული პრომპტი არ არის. საჭიროების შემთხვევაში შეამოწმეთ დაყენება და გახსენით ახალი ფანჯარა.", // ka
        ],
    ]
}
