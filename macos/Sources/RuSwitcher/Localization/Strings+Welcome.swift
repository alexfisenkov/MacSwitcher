// Переводы на 16 языков (порядок: en, ru, de, fr, es, pt, zh, ja, ko, uk, pl, be, el, bg, hy, ka).
// Приветствие, разрешения, обучение, что нового.

extension L10n {
    static let welcomeStrings: [String: [String]] = [
        "whatsnew.body": [
            "MacSwitcher: one Shift changes layout, a double Shift fixes a word or selection. Early local RU/EN correction is available. This is an alpha; ambiguous cases still need testing.", // en
            "MacSwitcher: один Shift меняет раскладку, двойной исправляет слово или выделение. Добавлена ранняя локальная RU/EN-коррекция. Это альфа-версия; неоднозначные случаи требуют проверки.", // ru
            "MacSwitcher: Einmal Umschalt wechselt die Belegung, zweimal korrigiert ein Wort oder die Auswahl. Eine frühe lokale RU/EN-Korrektur ist enthalten. Dies ist eine Alpha-Version; mehrdeutige Fälle müssen noch getestet werden.", // de
            "MacSwitcher : un appui sur Maj change la disposition, deux appuis corrigent un mot ou la sélection. Une première correction locale RU/EN est disponible. Il s’agit d’une version alpha ; les cas ambigus doivent encore être testés.", // fr
            "MacSwitcher: una pulsación de Mayús cambia la distribución y una doble corrige una palabra o la selección. Hay una primera corrección local RU/EN. Es una versión alfa; los casos ambiguos aún necesitan pruebas.", // es
            "MacSwitcher: um toque em Shift muda o layout e um toque duplo corrige uma palavra ou a seleção. Há uma correção local RU/EN inicial. Esta é uma versão alfa; os casos ambíguos ainda precisam de testes.", // pt
            "MacSwitcher：按一次 Shift 切换布局，连按两次 Shift 修正单词或所选内容。已加入早期的本地 RU/EN 纠错功能。这是 Alpha 版本，含义不明确的情况仍需测试。", // zh
            "MacSwitcher：Shift を1回押すとレイアウトを切り替え、2回押すと単語または選択範囲を修正します。初期のローカル RU/EN 修正を追加しました。これはアルファ版で、判断が難しいケースはまだテストが必要です。", // ja
            "MacSwitcher: Shift를 한 번 누르면 레이아웃이 바뀌고, 두 번 누르면 단어나 선택 영역을 수정합니다. 초기 단계의 로컬 RU/EN 수정 기능이 추가되었습니다. 알파 버전이며, 모호한 경우는 아직 테스트가 필요합니다.", // ko
            "MacSwitcher: один Shift змінює розкладку, подвійний виправляє слово або виділення. Додано ранню локальну RU/EN-корекцію. Це альфа-версія; неоднозначні випадки ще потребують перевірки.", // uk
            "MacSwitcher: jeden Shift zmienia układ, podwójny poprawia słowo lub zaznaczenie. Dodano wczesną lokalną korektę RU/EN. To wersja alfa; niejednoznaczne przypadki wymagają jeszcze testów.", // pl
            "MacSwitcher: адзін Shift мяняе раскладку, двайны выпраўляе слова або вылучэнне. Дададзена ранняя лакальная RU/EN-карэкцыя. Гэта альфа-версія; неадназначныя выпадкі патрабуюць праверкі.", // be
            "MacSwitcher: ένα Shift αλλάζει τη διάταξη, διπλό Shift διορθώνει μια λέξη ή την επιλογή. Προστέθηκε μια πρώιμη τοπική διόρθωση RU/EN. Πρόκειται για έκδοση alpha· οι αμφίσημες περιπτώσεις χρειάζονται ακόμη δοκιμές.", // el
            "MacSwitcher: един Shift сменя подредбата, двоен Shift поправя дума или селекция. Добавена е ранна локална RU/EN корекция. Това е алфа версия; неясните случаи все още изискват тестване.", // bg
            "MacSwitcher. մեկ Shift-ը փոխում է դասավորությունը, կրկնակի Shift-ը ուղղում է բառը կամ ընտրվածը։ Ավելացվել է տեղային RU/EN ուղղման վաղ տարբերակ։ Սա ալֆա տարբերակ է. անորոշ դեպքերը դեռ փորձարկում են պահանջում։", // hy
            "MacSwitcher: ერთი Shift ცვლის განლაგებას, ორმაგი Shift ასწორებს სიტყვას ან მონიშნულს. დაემატა ადრეული ლოკალური RU/EN შესწორება. ეს ალფა ვერსიაა; ორაზროვანი შემთხვევები ჯერ კიდევ საჭიროებს ტესტირებას.", // ka
        ],
        "onboard.autoConvert.title": [
            "Automatic correction", // en
            "Автоисправление", // ru
            "Automatische Korrektur", // de
            "Correction automatique", // fr
            "Corrección automática", // es
            "Correção automática", // pt
            "自动纠错", // zh
            "自動修正", // ja
            "자동 수정", // ko
            "Автовиправлення", // uk
            "Autokorekta", // pl
            "Аўтавыпраўленне", // be
            "Αυτόματη διόρθωση", // el
            "Автокорекция", // bg
            "Ավտոմատ ուղղում", // hy
            "ავტომატური შესწორება", // ka
        ],
        "onboard.autoConvert.text": [
            "Enable local automatic RU/EN correction while typing? It is off by default. One Shift changes layout; a double Shift fixes a word or selection. Automatic correction can be turned off in Settings.", // en
            "Включить локальное автоисправление RU/EN при наборе? По умолчанию оно выключено. Один Shift меняет раскладку, двойной исправляет слово или выделение. Автоисправление можно отключить в настройках.", // ru
            "Lokale automatische RU/EN-Korrektur beim Tippen aktivieren? Standardmäßig ist sie aus. Einmal Umschalt wechselt die Belegung, zweimal korrigiert ein Wort oder die Auswahl. Die automatische Korrektur lässt sich in den Einstellungen ausschalten.", // de
            "Activer la correction automatique locale RU/EN pendant la saisie ? Elle est désactivée par défaut. Un appui sur Maj change la disposition, deux appuis corrigent un mot ou la sélection. Vous pouvez désactiver la correction automatique dans les réglages.", // fr
            "¿Activar la corrección automática local RU/EN al escribir? Está desactivada por defecto. Una pulsación de Mayús cambia la distribución y una doble corrige una palabra o la selección. Puedes desactivar la corrección automática en los ajustes.", // es
            "Ativar a correção automática local RU/EN durante a escrita? Está desativada por predefinição. Um toque em Shift muda o layout e um toque duplo corrige uma palavra ou a seleção. A correção automática pode ser desativada nas definições.", // pt
            "要在输入时启用本地 RU/EN 自动纠错吗？默认关闭。按一次 Shift 切换布局，连按两次 Shift 修正单词或所选内容。可随时在设置中关闭自动纠错。", // zh
            "入力中にローカルの RU/EN 自動修正を有効にしますか？初期設定ではオフです。Shift を1回押すとレイアウトを切り替え、2回押すと単語または選択範囲を修正します。自動修正は設定でオフにできます。", // ja
            "입력하는 동안 로컬 RU/EN 자동 수정을 켤까요? 기본값은 꺼짐입니다. Shift를 한 번 누르면 레이아웃이 바뀌고, 두 번 누르면 단어나 선택 영역을 수정합니다. 자동 수정은 설정에서 끌 수 있습니다.", // ko
            "Увімкнути локальне автовиправлення RU/EN під час набору? Типово воно вимкнене. Один Shift змінює розкладку, подвійний виправляє слово або виділення. Автовиправлення можна вимкнути в налаштуваннях.", // uk
            "Włączyć lokalną autokorektę RU/EN podczas pisania? Domyślnie jest wyłączona. Jeden Shift zmienia układ, podwójny poprawia słowo lub zaznaczenie. Autokorektę można wyłączyć w ustawieniach.", // pl
            "Уключыць лакальнае аўтавыпраўленне RU/EN падчас набору? Тыпова яно выключана. Адзін Shift мяняе раскладку, двайны выпраўляе слова або вылучэнне. Аўтавыпраўленне можна выключыць у наладах.", // be
            "Να ενεργοποιηθεί η τοπική αυτόματη διόρθωση RU/EN κατά την πληκτρολόγηση; Είναι απενεργοποιημένη από προεπιλογή. Ένα Shift αλλάζει τη διάταξη, διπλό Shift διορθώνει μια λέξη ή την επιλογή. Η αυτόματη διόρθωση μπορεί να απενεργοποιηθεί στις Ρυθμίσεις.", // el
            "Да се включи ли локалната автокорекция RU/EN при писане? По подразбиране е изключена. Един Shift сменя подредбата, двоен Shift поправя дума или селекция. Автокорекцията може да се изключи от настройките.", // bg
            "Միացնե՞լ տեղային RU/EN ավտոմատ ուղղումը մուտքագրելիս։ Լռելյայն անջատված է։ Մեկ Shift-ը փոխում է դասավորությունը, կրկնակի Shift-ը ուղղում է բառը կամ ընտրվածը։ Ավտոմատ ուղղումը կարելի է անջատել կարգավորումներում։", // hy
            "ჩავრთო ლოკალური RU/EN ავტომატური შესწორება აკრეფისას? ნაგულისხმევად გამორთულია. ერთი Shift ცვლის განლაგებას, ორმაგი Shift ასწორებს სიტყვას ან მონიშნულს. ავტომატური შესწორების გამორთვა პარამეტრებშია შესაძლებელი.", // ka
        ],
        "welcome.window.title": [
            "Welcome", // en
            "Добро пожаловать", // ru
            "Willkommen", // de
            "Bienvenue", // fr
            "Te damos la bienvenida", // es
            "Bem-vindo", // pt
            "欢迎", // zh
            "ようこそ", // ja
            "환영합니다", // ko
            "Ласкаво просимо", // uk
            "Witamy", // pl
            "Сардэчна запрашаем", // be
            "Καλώς ορίσατε", // el
            "Добре дошли", // bg
            "Բարի գալուստ", // hy
            "მოგესალმებით", // ka
        ],
        "welcome.title": [
            "Welcome to MacSwitcher", // en
            "Добро пожаловать в MacSwitcher", // ru
            "Willkommen bei MacSwitcher", // de
            "Bienvenue dans MacSwitcher", // fr
            "Te damos la bienvenida a MacSwitcher", // es
            "Bem-vindo ao MacSwitcher", // pt
            "欢迎使用 MacSwitcher", // zh
            "MacSwitcher へようこそ", // ja
            "MacSwitcher에 오신 것을 환영합니다", // ko
            "Ласкаво просимо до MacSwitcher", // uk
            "Witamy w MacSwitcher", // pl
            "Сардэчна запрашаем у MacSwitcher", // be
            "Καλώς ορίσατε στο MacSwitcher", // el
            "Добре дошли в MacSwitcher", // bg
            "Բարի գալուստ MacSwitcher", // hy
            "მოგესალმებით MacSwitcher-ში", // ka
        ],
        "welcome.lead": [
            "One Shift changes the layout, two quick Shifts fix a word. For this, macOS needs two permissions: press “Open Settings” and turn MacSwitcher on in the list. This screen notices by itself when they are granted.", // en
            "Один Shift меняет раскладку, два Shift подряд исправляют слово. Для этого macOS нужно два разрешения: нажмите «Открыть настройки» и включите MacSwitcher в списке. Этот экран сам заметит, когда разрешения выданы.", // ru
            "Einmal Umschalt wechselt die Belegung, zweimal schnell korrigiert ein Wort. Dafür braucht macOS zwei Berechtigungen: Klicken Sie auf „Einstellungen öffnen“ und aktivieren Sie MacSwitcher in der Liste. Dieses Fenster erkennt selbst, wenn sie erteilt sind.", // de
            "Un appui sur Maj change la disposition, deux appuis rapides corrigent un mot. Pour cela, macOS exige deux autorisations : cliquez sur « Ouvrir les réglages » et activez MacSwitcher dans la liste. Cet écran détecte seul quand elles sont accordées.", // fr
            "Una pulsación de Mayús cambia la distribución y dos rápidas corrigen una palabra. Para ello macOS necesita dos permisos: pulsa «Abrir ajustes» y activa MacSwitcher en la lista. Esta pantalla detecta sola cuándo se conceden.", // es
            "Um toque em Shift muda o layout e dois toques rápidos corrigem uma palavra. Para isso, o macOS precisa de duas permissões: prima «Abrir definições» e ative o MacSwitcher na lista. Este ecrã deteta sozinho quando forem concedidas.", // pt
            "按一次 Shift 切换布局，快速按两次 Shift 修正单词。为此 macOS 需要两项权限：点击“打开设置”，并在列表中打开 MacSwitcher。授权完成后，此界面会自动识别。", // zh
            "Shift を1回押すとレイアウトを切り替え、素早く2回押すと単語を修正します。そのため macOS で2つの許可が必要です。「設定を開く」を押して、リストで MacSwitcher をオンにしてください。許可されると、この画面が自動で検知します。", // ja
            "Shift를 한 번 누르면 레이아웃이 바뀌고, 빠르게 두 번 누르면 단어를 수정합니다. 이를 위해 macOS에서 두 가지 권한이 필요합니다. “설정 열기”를 누르고 목록에서 MacSwitcher를 켜세요. 권한이 허용되면 이 화면이 자동으로 알아차립니다.", // ko
            "Один Shift змінює розкладку, два Shift поспіль виправляють слово. Для цього macOS потрібні два дозволи: натисніть «Відкрити налаштування» і ввімкніть MacSwitcher у списку. Цей екран сам помітить, коли дозволи надано.", // uk
            "Jeden Shift zmienia układ, dwa szybkie Shifty poprawiają słowo. Do tego macOS wymaga dwóch uprawnień: kliknij „Otwórz ustawienia” i włącz MacSwitcher na liście. Ten ekran sam zauważy, gdy zostaną przyznane.", // pl
            "Адзін Shift мяняе раскладку, два Shift запар выпраўляюць слова. Для гэтага macOS патрэбны два дазволы: націсніце «Адкрыць налады» і ўключыце MacSwitcher у спісе. Гэты экран сам заўважыць, калі дазволы выдадзены.", // be
            "Ένα Shift αλλάζει τη διάταξη, δύο γρήγορα Shift διορθώνουν μια λέξη. Για αυτό το macOS χρειάζεται δύο δικαιώματα: πατήστε «Άνοιγμα ρυθμίσεων» και ενεργοποιήστε το MacSwitcher στη λίστα. Αυτή η οθόνη θα το αντιληφθεί μόνη της όταν δοθούν.", // el
            "Един Shift сменя подредбата, два бързи Shift поправят дума. За това macOS изисква две разрешения: натиснете „Отваряне на настройките“ и включете MacSwitcher в списъка. Този екран сам ще забележи, когато са дадени.", // bg
            "Մեկ Shift-ը փոխում է դասավորությունը, երկու արագ Shift-ը ուղղում է բառը։ Դրա համար macOS-ին պետք են երկու թույլտվություն. սեղմեք «Բացել կարգավորումները» և ցանկում միացրեք MacSwitcher-ը։ Այս էկրանը ինքնուրույն կնկատի, երբ թույլտվությունները տրվեն։", // hy
            "ერთი Shift ცვლის განლაგებას, ორი სწრაფი Shift ასწორებს სიტყვას. ამისთვის macOS-ს ორი ნებართვა სჭირდება: დააჭირეთ „პარამეტრების გახსნას“ და სიაში ჩართეთ MacSwitcher. ეს ეკრანი თავად შეამჩნევს, როცა ნებართვები მიიღება.", // ka
        ],
        "welcome.accessibility.title": [
            "Accessibility", // en
            "Универсальный доступ", // ru
            "Bedienungshilfen", // de
            "Accessibilité", // fr
            "Accesibilidad", // es
            "Acessibilidade", // pt
            "辅助功能", // zh
            "アクセシビリティ", // ja
            "손쉬운 사용", // ko
            "Універсальний доступ", // uk
            "Dostępność", // pl
            "Універсальны доступ", // be
            "Προσβασιμότητα", // el
            "Достъпност", // bg
            "Մատչելիություն", // hy
            "ხელმისაწვდომობა", // ka
        ],
        "welcome.accessibility.text": [
            "To fix a word right in the field where you type.", // en
            "Чтобы исправлять слово прямо в поле, где вы печатаете.", // ru
            "Um ein Wort direkt in dem Feld zu korrigieren, in dem Sie tippen.", // de
            "Pour corriger un mot directement dans le champ où vous tapez.", // fr
            "Para corregir una palabra directamente en el campo donde escribes.", // es
            "Para corrigir uma palavra diretamente no campo onde escreve.", // pt
            "用于直接在你输入的文本框中修正单词。", // zh
            "入力中のフィールドで直接単語を修正するために必要です。", // ja
            "입력 중인 필드에서 바로 단어를 수정하기 위해 필요합니다.", // ko
            "Щоб виправляти слово прямо в полі, де ви друкуєте.", // uk
            "Aby poprawiać słowo bezpośrednio w polu, w którym piszesz.", // pl
            "Каб выпраўляць слова прама ў полі, дзе вы друкуеце.", // be
            "Για να διορθώνει μια λέξη απευθείας στο πεδίο όπου πληκτρολογείτε.", // el
            "За да поправя дума направо в полето, в което пишете.", // bg
            "Որպեսզի բառն ուղղվի հենց այն դաշտում, որտեղ մուտքագրում եք։", // hy
            "რათა სიტყვა ზუსტად იმ ველში გასწორდეს, სადაც წერთ.", // ka
        ],
        "welcome.inputMonitoring.title": [
            "Input Monitoring", // en
            "Мониторинг ввода", // ru
            "Eingabeüberwachung", // de
            "Surveillance de l’entrée", // fr
            "Monitorización de entrada", // es
            "Monitorização de entrada", // pt
            "输入监控", // zh
            "入力監視", // ja
            "입력 모니터링", // ko
            "Моніторинг введення", // uk
            "Monitorowanie wprowadzania", // pl
            "Маніторынг уводу", // be
            "Παρακολούθηση εισόδου", // el
            "Наблюдение на въвеждането", // bg
            "Մուտքի մոնիթորինգ", // hy
            "შეყვანის მონიტორინგი", // ka
        ],
        "welcome.inputMonitoring.text": [
            "To notice Shift and the end of a word. What you type is not saved or sent anywhere. MacSwitcher restarts by itself once this is on.", // en
            "Чтобы замечать Shift и конец слова. Набранный текст не сохраняется и никуда не отправляется. После включения MacSwitcher перезапустится сам.", // ru
            "Um Umschalt und das Wortende zu erkennen. Getippter Text wird weder gespeichert noch irgendwohin gesendet. Nach dem Aktivieren startet MacSwitcher selbst neu.", // de
            "Pour détecter Maj et la fin d’un mot. Ce que vous tapez n’est ni enregistré ni envoyé. MacSwitcher redémarre seul une fois l’option activée.", // fr
            "Para detectar Mayús y el final de una palabra. Lo que escribes no se guarda ni se envía a ningún sitio. MacSwitcher se reinicia solo al activarlo.", // es
            "Para detetar o Shift e o fim de uma palavra. O que escreve não é guardado nem enviado para lado nenhum. O MacSwitcher reinicia-se sozinho depois de ativar.", // pt
            "用于检测 Shift 键和单词结束。你输入的内容不会被保存或发送到任何地方。开启后 MacSwitcher 会自动重新启动。", // zh
            "Shift キーと単語の終わりを検知するために必要です。入力した内容は保存も送信もされません。オンにすると MacSwitcher は自動的に再起動します。", // ja
            "Shift 키와 단어의 끝을 감지하기 위해 필요합니다. 입력한 내용은 저장되거나 어디로도 전송되지 않습니다. 켜면 MacSwitcher가 자동으로 다시 시작됩니다.", // ko
            "Щоб помічати Shift і кінець слова. Набраний текст не зберігається й нікуди не надсилається. Після ввімкнення MacSwitcher перезапуститься сам.", // uk
            "Aby wykrywać Shift i koniec słowa. Wpisywany tekst nie jest zapisywany ani nigdzie wysyłany. Po włączeniu MacSwitcher uruchomi się ponownie sam.", // pl
            "Каб заўважаць Shift і канец слова. Набраны тэкст не захоўваецца і нікуды не адпраўляецца. Пасля ўключэння MacSwitcher перазапусціцца сам.", // be
            "Για να εντοπίζει το Shift και το τέλος μιας λέξης. Το κείμενο που πληκτρολογείτε δεν αποθηκεύεται ούτε αποστέλλεται πουθενά. Το MacSwitcher θα επανεκκινηθεί μόνο του μόλις ενεργοποιηθεί.", // el
            "За да забелязва Shift и края на думата. Написаното не се запазва и не се изпраща никъде. След включване MacSwitcher ще се рестартира сам.", // bg
            "Որպեսզի նկատվեն Shift-ը և բառի ավարտը։ Մուտքագրածը չի պահվում և ոչ մի տեղ չի ուղարկվում։ Միացնելուց հետո MacSwitcher-ը ինքնուրույն կվերագործարկվի։", // hy
            "რათა Shift-ი და სიტყვის დასასრული შეიმჩნეს. აკრეფილი ტექსტი არ ინახება და არსად იგზავნება. ჩართვის შემდეგ MacSwitcher თავად გადაიტვირთება.", // ka
        ],
        "welcome.openSettings": [
            "Open Settings", // en
            "Открыть настройки", // ru
            "Einstellungen öffnen", // de
            "Ouvrir les réglages", // fr
            "Abrir ajustes", // es
            "Abrir definições", // pt
            "打开设置", // zh
            "設定を開く", // ja
            "설정 열기", // ko
            "Відкрити налаштування", // uk
            "Otwórz ustawienia", // pl
            "Адкрыць налады", // be
            "Άνοιγμα ρυθμίσεων", // el
            "Отваряне на настройките", // bg
            "Բացել կարգավորումները", // hy
            "პარამეტრების გახსნა", // ka
        ],
        "welcome.granted": [
            "Allowed", // en
            "Разрешено", // ru
            "Erlaubt", // de
            "Autorisé", // fr
            "Permitido", // es
            "Permitido", // pt
            "已允许", // zh
            "許可済み", // ja
            "허용됨", // ko
            "Дозволено", // uk
            "Dozwolone", // pl
            "Дазволена", // be
            "Επιτρέπεται", // el
            "Разрешено", // bg
            "Թույլատրված է", // hy
            "ნებადართულია", // ka
        ],
        "welcome.missing": [
            "Not allowed yet", // en
            "Ещё не разрешено", // ru
            "Noch nicht erlaubt", // de
            "Pas encore autorisé", // fr
            "Aún no permitido", // es
            "Ainda não permitido", // pt
            "尚未允许", // zh
            "まだ許可されていません", // ja
            "아직 허용되지 않음", // ko
            "Ще не дозволено", // uk
            "Jeszcze niedozwolone", // pl
            "Яшчэ не дазволена", // be
            "Δεν επιτρέπεται ακόμη", // el
            "Още не е разрешено", // bg
            "Դեռ թույլատրված չէ", // hy
            "ჯერ არ არის ნებადართული", // ka
        ],
        "welcome.autoCorrection.hint": [
            "Fixes words typed in the wrong layout. You can turn it off here, in the menu or in Settings.", // en
            "Исправляет слова, набранные не в той раскладке. Выключить можно здесь, в меню или в настройках.", // ru
            "Korrigiert Wörter, die in der falschen Belegung getippt wurden. Ausschalten können Sie es hier, im Menü oder in den Einstellungen.", // de
            "Corrige les mots saisis dans la mauvaise disposition. Vous pouvez la désactiver ici, dans le menu ou dans les réglages.", // fr
            "Corrige las palabras escritas en la distribución equivocada. Puedes desactivarla aquí, en el menú o en los ajustes.", // es
            "Corrige as palavras escritas no layout errado. Pode desativá-la aqui, no menu ou nas definições.", // pt
            "修正以错误布局输入的单词。你可以在此处、菜单或设置中将其关闭。", // zh
            "間違ったレイアウトで入力した単語を修正します。ここ、メニュー、または設定でオフにできます。", // ja
            "잘못된 레이아웃으로 입력한 단어를 수정합니다. 여기, 메뉴 또는 설정에서 끌 수 있습니다.", // ko
            "Виправляє слова, набрані не в тій розкладці. Вимкнути можна тут, у меню або в налаштуваннях.", // uk
            "Poprawia słowa wpisane w złym układzie. Można ją wyłączyć tutaj, w menu lub w ustawieniach.", // pl
            "Выпраўляе словы, набраныя не ў той раскладцы. Выключыць можна тут, у меню або ў наладах.", // be
            "Διορθώνει λέξεις που πληκτρολογήθηκαν σε λάθος διάταξη. Μπορείτε να την απενεργοποιήσετε εδώ, στο μενού ή στις Ρυθμίσεις.", // el
            "Поправя думи, написани в грешна подредба. Можете да я изключите тук, от менюто или от настройките.", // bg
            "Ուղղում է սխալ դասավորությամբ մուտքագրված բառերը։ Կարելի է անջատել այստեղ, ընտրացանկում կամ կարգավորումներում։", // hy
            "ასწორებს არასწორი განლაგებით აკრეფილ სიტყვებს. გამორთვა შეგიძლიათ აქ, მენიუში ან პარამეტრებში.", // ka
        ],
        "welcome.launchAtLogin": [
            "Open at login", // en
            "Запуск при входе", // ru
            "Beim Anmelden öffnen", // de
            "Ouvrir à la connexion", // fr
            "Abrir al iniciar sesión", // es
            "Abrir ao iniciar sessão", // pt
            "登录时打开", // zh
            "ログイン時に開く", // ja
            "로그인 시 열기", // ko
            "Запуск під час входу", // uk
            "Uruchamiaj przy logowaniu", // pl
            "Запуск пры ўваходзе", // be
            "Άνοιγμα κατά τη σύνδεση", // el
            "Стартиране при вход", // bg
            "Բացել մուտք գործելիս", // hy
            "გახსნა შესვლისას", // ka
        ],
        "welcome.launchAtLogin.hint": [
            "MacSwitcher starts by itself when you log in.", // en
            "MacSwitcher будет запускаться сам, когда вы входите в систему.", // ru
            "MacSwitcher startet von selbst, wenn Sie sich anmelden.", // de
            "MacSwitcher démarre tout seul à l’ouverture de session.", // fr
            "MacSwitcher se inicia solo al iniciar sesión.", // es
            "O MacSwitcher arranca sozinho quando inicia sessão.", // pt
            "登录时 MacSwitcher 会自动启动。", // zh
            "ログイン時に MacSwitcher が自動的に起動します。", // ja
            "로그인할 때 MacSwitcher가 자동으로 시작됩니다.", // ko
            "MacSwitcher запускатиметься сам, коли ви входите в систему.", // uk
            "MacSwitcher uruchomi się sam po zalogowaniu.", // pl
            "MacSwitcher будзе запускацца сам, калі вы ўваходзіце ў сістэму.", // be
            "Το MacSwitcher ξεκινά αυτόματα όταν συνδεθείτε.", // el
            "MacSwitcher се стартира сам, когато влезете в системата.", // bg
            "MacSwitcher-ը ինքնուրույն կգործարկվի, երբ մուտք գործեք համակարգ։", // hy
            "MacSwitcher თავად გაეშვება, როცა სისტემაში შეხვალთ.", // ka
        ],
        "welcome.done": [
            "Done", // en
            "Готово", // ru
            "Fertig", // de
            "Terminé", // fr
            "Listo", // es
            "Concluído", // pt
            "完成", // zh
            "完了", // ja
            "완료", // ko
            "Готово", // uk
            "Gotowe", // pl
            "Гатова", // be
            "Τέλος", // el
            "Готово", // bg
            "Պատրաստ է", // hy
            "მზადაა", // ka
        ],
        "permissions.reset.body": [
            "macOS revoked a MacSwitcher permission. Check Accessibility and Input Monitoring in System Settings. Existing permissions are preserved.", // en
            "macOS отозвала одно из разрешений MacSwitcher. Проверьте «Универсальный доступ» и «Мониторинг ввода» в Системных настройках. Действующие разрешения сохраняются.", // ru
            "macOS hat eine Berechtigung von MacSwitcher widerrufen. Prüfen Sie „Bedienungshilfen“ und „Eingabeüberwachung“ in den Systemeinstellungen. Bestehende Berechtigungen bleiben erhalten.", // de
            "macOS a révoqué une autorisation de MacSwitcher. Vérifiez « Accessibilité » et « Surveillance de l’entrée » dans Réglages Système. Les autorisations existantes sont conservées.", // fr
            "macOS ha revocado un permiso de MacSwitcher. Revisa «Accesibilidad» y «Monitorización de entrada» en Ajustes del Sistema. Los permisos existentes se conservan.", // es
            "O macOS revogou uma permissão do MacSwitcher. Verifique «Acessibilidade» e «Monitorização de entrada» em Definições do Sistema. As permissões existentes são mantidas.", // pt
            "macOS 撤销了 MacSwitcher 的一项权限。请在“系统设置”中检查“辅助功能”和“输入监控”。现有权限会保留。", // zh
            "macOS が MacSwitcher の許可の1つを取り消しました。「システム設定」で「アクセシビリティ」と「入力監視」を確認してください。現在の許可は保持されます。", // ja
            "macOS에서 MacSwitcher의 권한 하나를 취소했습니다. “시스템 설정”에서 “손쉬운 사용” 및 “입력 모니터링”을(를) 확인하세요. 기존 권한은 유지됩니다.", // ko
            "macOS відкликала один із дозволів MacSwitcher. Перевірте «Універсальний доступ» і «Моніторинг введення» у розділі «Системні налаштування». Чинні дозволи зберігаються.", // uk
            "macOS cofnął jedno z uprawnień MacSwitcher. Sprawdź „Dostępność” i „Monitorowanie wprowadzania” w ustawieniach: Ustawienia systemowe. Obecne uprawnienia zostają zachowane.", // pl
            "macOS адклікала адзін з дазволаў MacSwitcher. Праверце «Універсальны доступ» і «Маніторынг уводу» у раздзеле «Сістэмныя налады». Бягучыя дазволы захоўваюцца.", // be
            "Το macOS ανακάλεσε ένα δικαίωμα του MacSwitcher. Ελέγξτε τα «Προσβασιμότητα» και «Παρακολούθηση εισόδου» στις Ρυθμίσεις συστήματος. Τα υπάρχοντα δικαιώματα διατηρούνται.", // el
            "macOS отмени едно от разрешенията на MacSwitcher. Проверете «Достъпност» и «Наблюдение на въвеждането» в Системни настройки. Съществуващите разрешения се запазват.", // bg
            "macOS-ը չեղարկեց MacSwitcher-ի թույլտվություններից մեկը։ Ստուգեք «Մատչելիություն» և «Մուտքի մոնիթորինգ» կետերը «Համակարգի կարգավորումներ»-ում։ Գործող թույլտվությունները պահպանվում են։", // hy
            "macOS-მა გააუქმა MacSwitcher-ის ერთ-ერთი ნებართვა. შეამოწმეთ „ხელმისაწვდომობა“ და „შეყვანის მონიტორინგი“ განყოფილებაში „სისტემის პარამეტრები“. არსებული ნებართვები შენარჩუნებულია.", // ka
        ],
        "adaptive.intro.title": [
            "MacSwitcher learns locally", // en
            "Локальное обучение MacSwitcher", // ru
            "MacSwitcher lernt lokal", // de
            "MacSwitcher apprend en local", // fr
            "MacSwitcher aprende en local", // es
            "O MacSwitcher aprende localmente", // pt
            "MacSwitcher 在本地学习", // zh
            "MacSwitcher はローカルで学習します", // ja
            "MacSwitcher가 로컬에서 학습합니다", // ko
            "Локальне навчання MacSwitcher", // uk
            "MacSwitcher uczy się lokalnie", // pl
            "Лакальнае навучанне MacSwitcher", // be
            "Το MacSwitcher μαθαίνει τοπικά", // el
            "MacSwitcher се обучава локално", // bg
            "MacSwitcher-ը սովորում է տեղում", // hy
            "MacSwitcher ლოკალურად სწავლობს", // ka
        ],
        "adaptive.intro.body": [
            "After two separate corrections of a word, the choice is remembered only on this Mac. To turn learning off or delete rules, open “%1$@ → %2$@”. Typing history is not saved.", // en
            "После двух независимых исправлений одного слова выбор запоминается только на этом Mac. Отключить обучение и удалить правила можно в «%1$@ → %2$@». История набора не сохраняется.", // ru
            "Nach zwei unabhängigen Korrekturen eines Wortes wird die Wahl nur auf diesem Mac gemerkt. Das Lernen ausschalten und Regeln löschen können Sie unter „%1$@ → %2$@“. Der Tippverlauf wird nicht gespeichert.", // de
            "Après deux corrections indépendantes d’un mot, le choix est mémorisé uniquement sur ce Mac. Pour désactiver l’apprentissage ou supprimer des règles, ouvrez « %1$@ → %2$@ ». L’historique de saisie n’est pas enregistré.", // fr
            "Tras dos correcciones independientes de una palabra, la elección se recuerda solo en este Mac. Para desactivar el aprendizaje o borrar reglas, abre «%1$@ → %2$@». El historial de escritura no se guarda.", // es
            "Após duas correções independentes de uma palavra, a escolha é memorizada apenas neste Mac. Para desativar a aprendizagem ou apagar regras, abra «%1$@ → %2$@». O histórico de escrita não é guardado.", // pt
            "对同一单词进行两次独立修正后，所做的选择只会记在这台 Mac 上。要关闭学习或删除规则，请打开“%1$@ → %2$@”。输入历史不会被保存。", // zh
            "同じ単語を2回別々に修正すると、その選択はこの Mac にのみ記憶されます。学習をオフにしたりルールを削除したりするには、「%1$@ → %2$@」を開いてください。入力履歴は保存されません。", // ja
            "같은 단어를 두 번 따로 수정하면 그 선택은 이 Mac에만 기억됩니다. 학습을 끄거나 규칙을 삭제하려면 “%1$@ → %2$@”을 여세요. 입력 기록은 저장되지 않습니다.", // ko
            "Після двох незалежних виправлень одного слова вибір запам’ятовується лише на цьому Mac. Вимкнути навчання й видалити правила можна в «%1$@ → %2$@». Історія набору не зберігається.", // uk
            "Po dwóch niezależnych poprawkach słowa wybór jest zapamiętywany tylko na tym Macu. Aby wyłączyć uczenie się lub usunąć reguły, otwórz „%1$@ → %2$@”. Historia pisania nie jest zapisywana.", // pl
            "Пасля двух незалежных выпраўленняў аднаго слова выбар запамінаецца толькі на гэтым Mac. Адключыць навучанне і выдаліць правілы можна ў «%1$@ → %2$@». Гісторыя набору не захоўваецца.", // be
            "Μετά από δύο ανεξάρτητες διορθώσεις μιας λέξης, η επιλογή απομνημονεύεται μόνο σε αυτό το Mac. Για να απενεργοποιήσετε τη μάθηση ή να διαγράψετε κανόνες, ανοίξτε «%1$@ → %2$@». Το ιστορικό πληκτρολόγησης δεν αποθηκεύεται.", // el
            "След две независими поправки на една дума изборът се запомня само на този Mac. За да изключите обучението или да изтриете правила, отворете «%1$@ → %2$@». Историята на писане не се запазва.", // bg
            "Մեկ բառի երկու անկախ ուղղումից հետո ընտրությունը հիշվում է միայն այս Mac-ում։ Սովորելն անջատելու կամ կանոնները ջնջելու համար բացեք «%1$@ → %2$@»։ Մուտքագրման պատմությունը չի պահվում։", // hy
            "სიტყვის ორი დამოუკიდებელი შესწორების შემდეგ არჩევანი მხოლოდ ამ Mac-ზე ახსოვს. სწავლის გამორთვა და წესების წაშლა შეგიძლიათ განყოფილებაში «%1$@ → %2$@». აკრეფის ისტორია არ ინახება.", // ka
        ],
        "adaptive.intro.action": [
            "Open", // en
            "Открыть", // ru
            "Öffnen", // de
            "Ouvrir", // fr
            "Abrir", // es
            "Abrir", // pt
            "打开", // zh
            "開く", // ja
            "열기", // ko
            "Відкрити", // uk
            "Otwórz", // pl
            "Адкрыць", // be
            "Άνοιγμα", // el
            "Отваряне", // bg
            "Բացել", // hy
            "გახსნა", // ka
        ],
    ]
}
