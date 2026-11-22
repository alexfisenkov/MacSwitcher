// Переводы на 16 языков (порядок: en, ru, de, fr, es, pt, zh, ja, ko, uk, pl, be, el, bg, hy, ka).
// Настройки, меню, подпись подсказки.

extension L10n {
    static let settingsStrings: [String: [String]] = [
        "settings.tab.general": [
            "General", // en
            "Общие", // ru
            "Allgemein", // de
            "Général", // fr
            "General", // es
            "Geral", // pt
            "通用", // zh
            "一般", // ja
            "일반", // ko
            "Загальні", // uk
            "Ogólne", // pl
            "Агульныя", // be
            "Γενικά", // el
            "Общи", // bg
            "Ընդհանուր", // hy
            "ზოგადი", // ka
        ],
        "settings.tab.exceptions": [
            "Correction", // en
            "Автозамена", // ru
            "Korrektur", // de
            "Correction", // fr
            "Corrección", // es
            "Correção", // pt
            "纠错", // zh
            "修正", // ja
            "수정", // ko
            "Автозаміна", // uk
            "Korekta", // pl
            "Аўтазамена", // be
            "Διόρθωση", // el
            "Корекция", // bg
            "Ուղղում", // hy
            "შესწორება", // ka
        ],
        "settings.checkUpdates.hint": [
            "New versions are installed from the app after your confirmation.", // en
            "Новая версия устанавливается из приложения после вашего подтверждения.", // ru
            "Neue Versionen werden nach Ihrer Bestätigung aus der App installiert.", // de
            "Les nouvelles versions s’installent depuis l’app après votre confirmation.", // fr
            "Las versiones nuevas se instalan desde la app tras tu confirmación.", // es
            "As novas versões são instaladas a partir da app após a sua confirmação.", // pt
            "新版本会在你确认后从应用内安装。", // zh
            "新しいバージョンは、確認後にアプリ内からインストールされます。", // ja
            "새 버전은 확인 후 앱에서 설치됩니다.", // ko
            "Нова версія встановлюється із застосунку після вашого підтвердження.", // uk
            "Nowe wersje są instalowane z aplikacji po Twoim potwierdzeniu.", // pl
            "Новая версія ўсталёўваецца з праграмы пасля вашага пацвярджэння.", // be
            "Οι νέες εκδόσεις εγκαθίστανται από την εφαρμογή μετά την επιβεβαίωσή σας.", // el
            "Новата версия се инсталира от приложението след вашето потвърждение.", // bg
            "Նոր տարբերակը տեղադրվում է հավելվածից՝ ձեր հաստատումից հետո։", // hy
            "ახალი ვერსია ინსტალირდება აპლიკაციიდან თქვენი დადასტურების შემდეგ.", // ka
        ],
        "settings.betaChannel": [
            "Include alpha and beta releases", // en
            "Включать альфа- и бета-выпуски", // ru
            "Alpha- und Beta-Versionen einbeziehen", // de
            "Inclure les versions alpha et bêta", // fr
            "Incluir versiones alfa y beta", // es
            "Incluir versões alfa e beta", // pt
            "包含 Alpha 和 Beta 版本", // zh
            "アルファ版とベータ版を含める", // ja
            "알파 및 베타 버전 포함", // ko
            "Включати альфа- і бета-випуски", // uk
            "Uwzględniaj wersje alfa i beta", // pl
            "Уключаць альфа- і бета-выпускі", // be
            "Συμπερίληψη εκδόσεων alpha και beta", // el
            "Включване на алфа и бета версии", // bg
            "Ներառել ալֆա և բետա տարբերակները", // hy
            "ალფა და ბეტა ვერსიების ჩართვა", // ka
        ],
        "settings.betaChannel.hint": [
            "Include MacSwitcher prereleases. Installation requires confirmation.", // en
            "Предлагать предварительные выпуски MacSwitcher. Установка — после подтверждения.", // ru
            "Vorabversionen von MacSwitcher anbieten. Die Installation erfordert eine Bestätigung.", // de
            "Proposer les préversions de MacSwitcher. L’installation nécessite une confirmation.", // fr
            "Ofrecer versiones preliminares de MacSwitcher. La instalación requiere confirmación.", // es
            "Oferecer pré-lançamentos do MacSwitcher. A instalação requer confirmação.", // pt
            "提供 MacSwitcher 预发布版本。安装前需要确认。", // zh
            "MacSwitcher のプレリリース版を提案します。インストールには確認が必要です。", // ja
            "MacSwitcher 사전 출시 버전을 제안합니다. 설치하려면 확인이 필요합니다.", // ko
            "Пропонувати попередні випуски MacSwitcher. Встановлення — після підтвердження.", // uk
            "Proponuj wersje wstępne MacSwitcher. Instalacja wymaga potwierdzenia.", // pl
            "Прапаноўваць папярэднія выпускі MacSwitcher. Усталёўка — пасля пацвярджэння.", // be
            "Προσφορά προκαταρκτικών εκδόσεων του MacSwitcher. Η εγκατάσταση απαιτεί επιβεβαίωση.", // el
            "Предлагане на предварителни версии на MacSwitcher. Инсталирането изисква потвърждение.", // bg
            "Առաջարկել MacSwitcher-ի նախնական տարբերակները։ Տեղադրումը պահանջում է հաստատում։", // hy
            "MacSwitcher-ის წინასწარი ვერსიების შეთავაზება. ინსტალაციას დადასტურება სჭირდება.", // ka
        ],
        "settings.autoConvert": [
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
        "settings.autoConvert.hint": [
            "Local RU/EN correction during typing and at word boundaries. Ambiguous text may be left unchanged.", // en
            "Локальная RU/EN-коррекция при наборе и на границе слова. Неоднозначный текст может остаться без изменений.", // ru
            "Lokale RU/EN-Korrektur beim Tippen und an Wortgrenzen. Mehrdeutiger Text bleibt eventuell unverändert.", // de
            "Correction locale RU/EN pendant la saisie et en fin de mot. Un texte ambigu peut rester inchangé.", // fr
            "Corrección local RU/EN al escribir y al final de cada palabra. El texto ambiguo puede quedar sin cambios.", // es
            "Correção local RU/EN durante a escrita e no fim de cada palavra. O texto ambíguo pode ficar inalterado.", // pt
            "输入时及单词结束处进行本地 RU/EN 纠错。含义不明确的文本可能保持不变。", // zh
            "入力中と単語の区切りでローカルの RU/EN 修正を行います。判断が難しいテキストは変更されないことがあります。", // ja
            "입력 중과 단어 경계에서 로컬 RU/EN 수정을 합니다. 모호한 텍스트는 그대로 남을 수 있습니다.", // ko
            "Локальна RU/EN-корекція під час набору та на межі слова. Неоднозначний текст може залишитися без змін.", // uk
            "Lokalna korekta RU/EN podczas pisania i na granicy słowa. Niejednoznaczny tekst może pozostać bez zmian.", // pl
            "Лакальная RU/EN-карэкцыя падчас набору і на мяжы слова. Неадназначны тэкст можа застацца без змен.", // be
            "Τοπική διόρθωση RU/EN κατά την πληκτρολόγηση και στο όριο της λέξης. Το αμφίσημο κείμενο μπορεί να μείνει αμετάβλητο.", // el
            "Локална RU/EN корекция при писане и в края на думата. Неясен текст може да остане непроменен.", // bg
            "Տեղային RU/EN ուղղում մուտքագրելիս և բառի սահմանին։ Անորոշ տեքստը կարող է մնալ անփոփոխ։", // hy
            "ლოკალური RU/EN შესწორება აკრეფისას და სიტყვის საზღვარზე. ორაზროვანი ტექსტი შეიძლება უცვლელი დარჩეს.", // ka
        ],
        "settings.version": [
            "Keyboard layout switching and RU/EN correction", // en
            "Переключение раскладки и коррекция RU/EN", // ru
            "Umschalten der Tastaturbelegung und RU/EN-Korrektur", // de
            "Changement de disposition du clavier et correction RU/EN", // fr
            "Cambio de distribución del teclado y corrección RU/EN", // es
            "Mudança de layout do teclado e correção RU/EN", // pt
            "键盘布局切换与 RU/EN 纠错", // zh
            "キーボードレイアウトの切り替えと RU/EN 修正", // ja
            "키보드 레이아웃 전환 및 RU/EN 수정", // ko
            "Перемикання розкладки та корекція RU/EN", // uk
            "Przełączanie układu klawiatury i korekta RU/EN", // pl
            "Пераключэнне раскладкі і карэкцыя RU/EN", // be
            "Εναλλαγή διάταξης πληκτρολογίου και διόρθωση RU/EN", // el
            "Превключване на подредбата и RU/EN корекция", // bg
            "Ստեղնաշարի դասավորության փոխարկում և RU/EN ուղղում", // hy
            "კლავიატურის განლაგების გადართვა და RU/EN შესწორება", // ka
        ],
        "menu.autoConvert": [
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
        "menu.inputSource": [
            "Input Source", // en
            "Раскладка", // ru
            "Eingabequelle", // de
            "Source de saisie", // fr
            "Fuente de entrada", // es
            "Fonte de entrada", // pt
            "输入法", // zh
            "入力ソース", // ja
            "입력 소스", // ko
            "Розкладка", // uk
            "Źródło wprowadzania", // pl
            "Раскладка", // be
            "Πηγή εισαγωγής", // el
            "Подредба", // bg
            "Դասավորություն", // hy
            "განლაგება", // ka
        ],
        "menu.more": [
            "More", // en
            "Дополнительно", // ru
            "Mehr", // de
            "Plus", // fr
            "Más", // es
            "Mais", // pt
            "更多", // zh
            "その他", // ja
            "더 보기", // ko
            "Додатково", // uk
            "Więcej", // pl
            "Дадаткова", // be
            "Περισσότερα", // el
            "Още", // bg
            "Ավելին", // hy
            "მეტი", // ka
        ],
        "correction.hint": [
            "%@  ·  Shift ×2 to fix", // en
            "%@  ·  Shift ×2 — исправить", // ru
            "%@  ·  Shift ×2 zum Korrigieren", // de
            "%@  ·  Maj ×2 pour corriger", // fr
            "%@  ·  Mayús ×2 para corregir", // es
            "%@  ·  Shift ×2 para corrigir", // pt
            "%@  ·  按两次 Shift 修正", // zh
            "%@  ·  Shift ×2 で修正", // ja
            "%@  ·  Shift ×2로 수정", // ko
            "%@  ·  Shift ×2 — виправити", // uk
            "%@  ·  Shift ×2, aby poprawić", // pl
            "%@  ·  Shift ×2 — выправіць", // be
            "%@  ·  Shift ×2 για διόρθωση", // el
            "%@  ·  Shift ×2 за поправка", // bg
            "%@  ·  Shift ×2՝ ուղղելու համար", // hy
            "%@  ·  Shift ×2 — შესასწორებლად", // ka
        ],
        "settings.gestures.group": [
            "Shift and automatic correction", // en
            "Shift и автоисправление", // ru
            "Umschalt und automatische Korrektur", // de
            "Maj et correction automatique", // fr
            "Mayús y corrección automática", // es
            "Shift e correção automática", // pt
            "Shift 与自动纠错", // zh
            "Shift と自動修正", // ja
            "Shift 및 자동 수정", // ko
            "Shift і автовиправлення", // uk
            "Shift i autokorekta", // pl
            "Shift і аўтавыпраўленне", // be
            "Shift και αυτόματη διόρθωση", // el
            "Shift и автокорекция", // bg
            "Shift և ավտոմատ ուղղում", // hy
            "Shift და ავტომატური შესწორება", // ka
        ],
        "settings.startupIcon.group": [
            "Startup, updates and icon", // en
            "Запуск, обновления и значок", // ru
            "Start, Updates und Symbol", // de
            "Démarrage, mises à jour et icône", // fr
            "Inicio, actualizaciones e icono", // es
            "Arranque, atualizações e ícone", // pt
            "启动、更新和图标", // zh
            "起動、アップデート、アイコン", // ja
            "시작, 업데이트 및 아이콘", // ko
            "Запуск, оновлення та значок", // uk
            "Uruchamianie, aktualizacje i ikona", // pl
            "Запуск, абнаўленні і значок", // be
            "Εκκίνηση, ενημερώσεις και εικονίδιο", // el
            "Стартиране, актуализации и икона", // bg
            "Մեկնարկ, թարմացումներ և պատկերակ", // hy
            "გაშვება, განახლებები და ხატულა", // ka
        ],
        "settings.icon": [
            "Menu bar icon:", // en
            "Значок в строке меню:", // ru
            "Symbol in der Menüleiste:", // de
            "Icône dans la barre des menus :", // fr
            "Icono en la barra de menús:", // es
            "Ícone na barra de menus:", // pt
            "菜单栏图标：", // zh
            "メニューバーのアイコン：", // ja
            "메뉴 막대 아이콘:", // ko
            "Значок у рядку меню:", // uk
            "Ikona na pasku menu:", // pl
            "Значок у радку меню:", // be
            "Εικονίδιο στη γραμμή μενού:", // el
            "Икона в менюто:", // bg
            "Պատկերակը ընտրացանկի տողում.", // hy
            "ხატულა მენიუს ზოლში:", // ka
        ],
        "settings.icon.badge": [
            "RU/EN", // en
            "РУ/EN", // ru
            "RU/EN", // de
            "RU/EN", // fr
            "RU/EN", // es
            "RU/EN", // pt
            "RU/EN", // zh
            "RU/EN", // ja
            "RU/EN", // ko
            "РУ/EN", // uk
            "RU/EN", // pl
            "РУ/EN", // be
            "RU/EN", // el
            "РУ/EN", // bg
            "RU/EN", // hy
            "RU/EN", // ka
        ],
        "settings.icon.flag": [
            "Flag", // en
            "Флаг", // ru
            "Flagge", // de
            "Drapeau", // fr
            "Bandera", // es
            "Bandeira", // pt
            "旗帜", // zh
            "旗", // ja
            "깃발", // ko
            "Прапор", // uk
            "Flaga", // pl
            "Сцяг", // be
            "Σημαία", // el
            "Флаг", // bg
            "Դրոշ", // hy
            "დროშა", // ka
        ],
        "settings.section.check": [
            "Check", // en
            "Проверка", // ru
            "Prüfen", // de
            "Vérification", // fr
            "Comprobación", // es
            "Verificação", // pt
            "检查", // zh
            "確認", // ja
            "점검", // ko
            "Перевірка", // uk
            "Sprawdzanie", // pl
            "Праверка", // be
            "Έλεγχος", // el
            "Проверка", // bg
            "Ստուգում", // hy
            "შემოწმება", // ka
        ],
        "settings.section.expert": [
            "For advanced users", // en
            "Для опытных", // ru
            "Für Fortgeschrittene", // de
            "Pour utilisateurs avancés", // fr
            "Para usuarios avanzados", // es
            "Para utilizadores avançados", // pt
            "高级用户", // zh
            "上級者向け", // ja
            "고급 사용자용", // ko
            "Для досвідчених", // uk
            "Dla zaawansowanych", // pl
            "Для дасведчаных", // be
            "Για προχωρημένους", // el
            "За опитни потребители", // bg
            "Փորձառու օգտատերերի համար", // hy
            "მოწინავე მომხმარებლებისთვის", // ka
        ],
        "settings.compactMenu": [
            "Short menu", // en
            "Короткое меню", // ru
            "Kurzes Menü", // de
            "Menu court", // fr
            "Menú corto", // es
            "Menu curto", // pt
            "精简菜单", // zh
            "短縮メニュー", // ja
            "간단한 메뉴", // ko
            "Коротке меню", // uk
            "Krótkie menu", // pl
            "Кароткае меню", // be
            "Σύντομο μενού", // el
            "Кратко меню", // bg
            "Կարճ ընտրացանկ", // hy
            "მოკლე მენიუ", // ka
        ],
        "settings.compactMenu.hint": [
            "The menu keeps “Automatic correction”, “Settings…” and “Quit”. “How to use” and “Words & exceptions” stay inside Settings.", // en
            "В меню остаются «Автоисправление», «Настройки…» и «Выход». «Как пользоваться» и «Слова и исключения» — внутри настроек.", // ru
            "Das Menü enthält nur „Automatische Korrektur“, „Einstellungen…“ und „Beenden“. „Verwendung“ und „Wörter & Ausnahmen“ befinden sich in den Einstellungen.", // de
            "Le menu ne garde que « Correction automatique », « Préférences… » et « Quitter ». « Mode d’emploi » et « Mots et exceptions » restent dans les réglages.", // fr
            "El menú conserva «Corrección automática», «Ajustes…» y «Salir». «Cómo usar» y «Palabras y excepciones» quedan dentro de los ajustes.", // es
            "O menu mantém «Correção automática», «Configurações…» e «Sair». «Como usar» e «Palavras e exceções» ficam dentro das definições.", // pt
            "菜单中仅保留“自动纠错”、“设置…”和“退出”。“使用方法”和“词语与例外”位于设置内。", // zh
            "メニューには「自動修正」、「設定…」、「終了」だけが残ります。「使い方」と「単語と例外」は設定内にあります。", // ja
            "메뉴에는 “자동 수정”, “설정…”, “종료”만 남습니다. “사용 방법”과 “단어 및 예외”는 설정 안에 있습니다.", // ko
            "У меню залишаються «Автовиправлення», «Налаштування…» і «Вихід». «Як користуватися» та «Слова й винятки» — усередині налаштувань.", // uk
            "W menu zostają „Autokorekta”, „Ustawienia…” i „Zakończ”. „Jak używać” oraz „Słowa i wyjątki” są w ustawieniach.", // pl
            "У меню застаюцца «Аўтавыпраўленне», «Налады…» і «Выхад». «Як карыстацца» і «Словы і выключэнні» — унутры налад.", // be
            "Το μενού διατηρεί «Αυτόματη διόρθωση», «Ρυθμίσεις…» και «Έξοδος». Τα «Οδηγίες χρήσης» και «Λέξεις και εξαιρέσεις» βρίσκονται μέσα στις Ρυθμίσεις.", // el
            "Менюто съдържа само «Автокорекция», «Настройки…» и «Изход». «Как се използва» и «Думи и изключения» са в настройките.", // bg
            "Ընտրացանկում մնում են «Ավտոմատ ուղղում», «Կարգավորումներ…» և «Ելք»։ «Ինչպես օգտվել» և «Բառեր և բացառություններ» կետերը գտնվում են կարգավորումներում։", // hy
            "მენიუში რჩება «ავტომატური შესწორება», «პარამეტრები…» და «გასვლა». «გამოყენება» და «სიტყვები და გამონაკლისები» პარამეტრების შიგნითაა.", // ka
        ],
        "words.dictionary.detail": [
            "Names and brands to keep as typed, and exact phrase exceptions.", // en
            "Имена и бренды, которые нужно оставлять как есть, и точные фразы-исключения.", // ru
            "Namen und Marken, die unverändert bleiben sollen, sowie genaue Ausnahmen für Wendungen.", // de
            "Noms et marques à garder tels quels, et exceptions de phrases exactes.", // fr
            "Nombres y marcas que se mantienen tal cual y excepciones de frases exactas.", // es
            "Nomes e marcas a manter como escritos e exceções de frases exatas.", // pt
            "需要保持原样的名称和品牌，以及精确的短语例外。", // zh
            "入力したまま残す名前やブランド、および完全一致のフレーズの例外。", // ja
            "입력한 그대로 둘 이름과 브랜드, 그리고 정확한 구문 예외입니다.", // ko
            "Імена та бренди, які слід залишати як є, і точні фрази-винятки.", // uk
            "Imiona i marki, które mają zostać bez zmian, oraz dokładne wyjątki dla fraz.", // pl
            "Імёны і брэнды, якія трэба пакідаць як ёсць, і дакладныя фразы-выключэнні.", // be
            "Ονόματα και επωνυμίες που μένουν όπως πληκτρολογήθηκαν, και ακριβείς εξαιρέσεις φράσεων.", // el
            "Имена и марки, които да останат както са, и точни изключения за фрази.", // bg
            "Անուններ և բրենդներ, որոնք պետք է մնան ինչպես կան, և ճշգրիտ արտահայտությունների բացառություններ։", // hy
            "სახელები და ბრენდები, რომლებიც უცვლელი უნდა დარჩეს, და ზუსტი ფრაზების გამონაკლისები.", // ka
        ],
        "words.never.detail": [
            "Automatic correction always leaves these words as typed.", // en
            "Эти слова автоисправление всегда оставляет как есть.", // ru
            "Diese Wörter lässt die automatische Korrektur immer unverändert.", // de
            "La correction automatique laisse toujours ces mots tels quels.", // fr
            "La corrección automática deja siempre estas palabras tal cual.", // es
            "A correção automática deixa sempre estas palavras como escritas.", // pt
            "自动纠错始终保持这些词不变。", // zh
            "自動修正はこれらの単語を常にそのまま残します。", // ja
            "자동 수정은 이 단어들을 항상 그대로 둡니다.", // ko
            "Ці слова автовиправлення завжди залишає як є.", // uk
            "Autokorekta zawsze pozostawia te słowa bez zmian.", // pl
            "Гэтыя словы аўтавыпраўленне заўсёды пакідае як ёсць.", // be
            "Αυτές τις λέξεις η αυτόματη διόρθωση τις αφήνει πάντα όπως είναι.", // el
            "Тези думи автокорекцията винаги оставя както са.", // bg
            "Այս բառերը ավտոմատ ուղղումը միշտ թողնում է ինչպես կան։", // hy
            "ამ სიტყვებს ავტომატური შესწორება ყოველთვის უცვლელს ტოვებს.", // ka
        ],
        "words.always.detail": [
            "These words are corrected even when they are not in the dictionary.", // en
            "Эти слова исправляются, даже если их нет в словаре.", // ru
            "Diese Wörter werden auch korrigiert, wenn sie nicht im Wörterbuch stehen.", // de
            "Ces mots sont corrigés même s’ils ne figurent pas dans le dictionnaire.", // fr
            "Estas palabras se corrigen aunque no estén en el diccionario.", // es
            "Estas palavras são corrigidas mesmo que não estejam no dicionário.", // pt
            "即使这些词不在词典中，也会被修正。", // zh
            "これらの単語は、辞書にない場合でも修正されます。", // ja
            "이 단어들은 사전에 없어도 수정됩니다.", // ko
            "Ці слова виправляються, навіть якщо їх немає у словнику.", // uk
            "Te słowa są poprawiane, nawet jeśli nie ma ich w słowniku.", // pl
            "Гэтыя словы выпраўляюцца, нават калі іх няма ў слоўніку.", // be
            "Αυτές οι λέξεις διορθώνονται ακόμη και αν δεν υπάρχουν στο λεξικό.", // el
            "Тези думи се поправят, дори когато ги няма в речника.", // bg
            "Այս բառերն ուղղվում են, նույնիսկ եթե բառարանում չկան։", // hy
            "ეს სიტყვები სწორდება, თუნდაც ლექსიკონში არ იყოს.", // ka
        ],
        "words.apps.detail": [
            "Automatic correction is off in these apps; Shift works as usual.", // en
            "В этих приложениях автоисправление не работает; Shift работает как обычно.", // ru
            "In diesen Apps ist die automatische Korrektur aus; Umschalt funktioniert wie gewohnt.", // de
            "Dans ces apps, la correction automatique est désactivée ; Maj fonctionne comme d’habitude.", // fr
            "En estas apps, la corrección automática está desactivada; Mayús funciona como siempre.", // es
            "Nestas apps, a correção automática está desativada; o Shift funciona como habitual.", // pt
            "在这些应用中自动纠错已关闭；Shift 照常工作。", // zh
            "これらのアプリでは自動修正はオフです。Shift は通常どおり動作します。", // ja
            "이 앱에서는 자동 수정이 꺼집니다. Shift는 평소처럼 작동합니다.", // ko
            "У цих застосунках автовиправлення не працює; Shift працює як зазвичай.", // uk
            "W tych aplikacjach autokorekta jest wyłączona; Shift działa jak zwykle.", // pl
            "У гэтых праграмах аўтавыпраўленне не працуе; Shift працуе як звычайна.", // be
            "Σε αυτές τις εφαρμογές η αυτόματη διόρθωση είναι απενεργοποιημένη· το Shift λειτουργεί κανονικά.", // el
            "В тези приложения автокорекцията е изключена; Shift работи както обикновено.", // bg
            "Այս հավելվածներում ավտոմատ ուղղումը անջատված է. Shift-ը աշխատում է ինչպես միշտ։", // hy
            "ამ აპებში ავტომატური შესწორება გამორთულია; Shift ჩვეულებრივ მუშაობს.", // ka
        ],
        "words.learning.detail": [
            "What was remembered from your corrections; learning is turned off here.", // en
            "Что запомнено по вашим исправлениям; здесь же обучение выключается.", // ru
            "Was aus Ihren Korrekturen gemerkt wurde; hier lässt sich das Lernen ausschalten.", // de
            "Ce qui a été mémorisé à partir de vos corrections ; l’apprentissage se désactive ici.", // fr
            "Lo que se ha recordado de tus correcciones; aquí también se desactiva el aprendizaje.", // es
            "O que foi memorizado a partir das suas correções; é aqui que se desativa a aprendizagem.", // pt
            "根据你的修正记住的内容；也可在此关闭学习。", // zh
            "修正から記憶された内容です。ここで学習をオフにできます。", // ja
            "사용자의 수정에서 기억한 내용입니다. 여기서 학습을 끌 수 있습니다.", // ko
            "Що запам’ятовано за вашими виправленнями; тут же навчання вимикається.", // uk
            "To, co zapamiętano na podstawie Twoich poprawek; tutaj wyłączysz też uczenie się.", // pl
            "Што запомнена па вашых выпраўленнях; тут жа навучанне выключаецца.", // be
            "Ό,τι απομνημονεύτηκε από τις διορθώσεις σας· εδώ απενεργοποιείται και η μάθηση.", // el
            "Какво е запомнено от вашите поправки; тук се изключва и обучението.", // bg
            "Ինչ է հիշվել ձեր ուղղումներից. այստեղ է անջատվում նաև սովորելը։", // hy
            "რა დაიმახსოვრა თქვენი შესწორებებიდან; აქვე გამოირთვება სწავლა.", // ka
        ],
        "settings.interval.value": [
            "%d ms", // en
            "%d мс", // ru
            "%d ms", // de
            "%d ms", // fr
            "%d ms", // es
            "%d ms", // pt
            "%d 毫秒", // zh
            "%d ミリ秒", // ja
            "%d ms", // ko
            "%d мс", // uk
            "%d ms", // pl
            "%d мс", // be
            "%d ms", // el
            "%d ms", // bg
            "%d մվ", // hy
            "%d მწმ", // ka
        ],
        "menu.recovery": [
            "Original texts after unconfirmed edits", // en
            "Исходные тексты после сбоя", // ru
            "Originaltexte nach unbestätigten Änderungen", // de
            "Textes originaux après modifications non confirmées", // fr
            "Textos originales tras cambios sin confirmar", // es
            "Textos originais após alterações por confirmar", // pt
            "未确认修改后的原文", // zh
            "未確認の変更後の元のテキスト", // ja
            "확인되지 않은 수정 후의 원본 텍스트", // ko
            "Початкові тексти після збою", // uk
            "Teksty oryginalne po niepotwierdzonych zmianach", // pl
            "Зыходныя тэксты пасля збою", // be
            "Αρχικά κείμενα μετά από μη επιβεβαιωμένες αλλαγές", // el
            "Оригинални текстове след непотвърдени промени", // bg
            "Սկզբնական տեքստերը չհաստատված փոփոխություններից հետո", // hy
            "საწყისი ტექსტები დაუდასტურებელი ცვლილებების შემდეგ", // ka
        ],
        "menu.archiveFolder": [
            "Original-text archive folder", // en
            "Папка архивов исходников", // ru
            "Ordner mit Originaltext-Archiven", // de
            "Dossier des archives de textes originaux", // fr
            "Carpeta del archivo de textos originales", // es
            "Pasta do arquivo de textos originais", // pt
            "原文存档文件夹", // zh
            "元のテキストのアーカイブフォルダ", // ja
            "원본 텍스트 보관 폴더", // ko
            "Папка архівів першоджерел", // uk
            "Folder archiwum tekstów oryginalnych", // pl
            "Папка архіваў зыходнікаў", // be
            "Φάκελος αρχείου αρχικών κειμένων", // el
            "Папка с архиви на оригиналните текстове", // bg
            "Սկզբնական տեքստերի արխիվի պանակ", // hy
            "საწყისი ტექსტების არქივის საქაღალდე", // ka
        ],
        "menu.sourceConfirm": [
            "Text changed · confirm the %@ input source", // en
            "Текст исправлен · подтвердите раскладку %@", // ru
            "Text geändert · Eingabequelle %@ bestätigen", // de
            "Texte modifié · confirmez la source de saisie %@", // fr
            "Texto cambiado · confirma la fuente de entrada %@", // es
            "Texto alterado · confirme a fonte de entrada %@", // pt
            "文本已更改 · 请确认输入法 %@", // zh
            "テキストを変更しました · 入力ソース %@ を確認してください", // ja
            "텍스트가 변경됨 · 입력 소스 %@ 확인", // ko
            "Текст виправлено · підтвердьте розкладку %@", // uk
            "Tekst zmieniony · potwierdź źródło wprowadzania %@", // pl
            "Тэкст выпраўлены · пацвердзіце раскладку %@", // be
            "Το κείμενο άλλαξε · επιβεβαιώστε την πηγή εισαγωγής %@", // el
            "Текстът е променен · потвърдете подредбата %@", // bg
            "Տեքստը փոխվեց · հաստատեք %@ դասավորությունը", // hy
            "ტექსტი შეიცვალა · დაადასტურეთ განლაგება %@", // ka
        ],
        "menu.copyOriginal": [
            "Copy original text %d", // en
            "Скопировать исходный текст %d", // ru
            "Originaltext %d kopieren", // de
            "Copier le texte original %d", // fr
            "Copiar el texto original %d", // es
            "Copiar o texto original %d", // pt
            "拷贝原文 %d", // zh
            "元のテキスト %d をコピー", // ja
            "원본 텍스트 %d 복사", // ko
            "Скопіювати початковий текст %d", // uk
            "Kopiuj tekst oryginalny %d", // pl
            "Скапіяваць зыходны тэкст %d", // be
            "Αντιγραφή αρχικού κειμένου %d", // el
            "Копиране на оригиналния текст %d", // bg
            "Պատճենել սկզբնական տեքստը %d", // hy
            "საწყისი ტექსტის %d კოპირება", // ka
        ],
        "menu.copyArchive": [
            "Copy from archive %d", // en
            "Скопировать из архива %d", // ru
            "Aus Archiv %d kopieren", // de
            "Copier depuis l’archive %d", // fr
            "Copiar del archivo %d", // es
            "Copiar do arquivo %d", // pt
            "从存档拷贝 %d", // zh
            "アーカイブ %d からコピー", // ja
            "보관 파일 %d에서 복사", // ko
            "Скопіювати з архіву %d", // uk
            "Kopiuj z archiwum %d", // pl
            "Скапіяваць з архіва %d", // be
            "Αντιγραφή από το αρχείο %d", // el
            "Копиране от архив %d", // bg
            "Պատճենել արխիվից %d", // hy
            "არქივიდან %d კოპირება", // ka
        ],
        "menu.copyTerminalLine": [
            "Copy original terminal line %d", // en
            "Скопировать исходную строку терминала %d", // ru
            "Ursprüngliche Terminalzeile %d kopieren", // de
            "Copier la ligne d’origine du terminal %d", // fr
            "Copiar la línea original del terminal %d", // es
            "Copiar a linha original do terminal %d", // pt
            "拷贝终端原始行 %d", // zh
            "ターミナルの元の行 %d をコピー", // ja
            "터미널 원래 줄 %d 복사", // ko
            "Скопіювати початковий рядок термінала %d", // uk
            "Kopiuj oryginalną linię terminala %d", // pl
            "Скапіяваць зыходны радок тэрмінала %d", // be
            "Αντιγραφή αρχικής γραμμής τερματικού %d", // el
            "Копиране на първоначалния ред на терминала %d", // bg
            "Պատճենել տերմինալի սկզբնական տողը %d", // hy
            "ტერმინალის საწყისი ხაზის %d კოპირება", // ka
        ],
        "menu.saveOriginals": [
            "Save originals locally and continue", // en
            "Сохранить исходники локально и продолжить", // ru
            "Originale lokal sichern und fortfahren", // de
            "Enregistrer les originaux localement et continuer", // fr
            "Guardar originales localmente y continuar", // es
            "Guardar os originais localmente e continuar", // pt
            "将原文保存到本地并继续", // zh
            "元のテキストをローカルに保存して続行", // ja
            "원본을 로컬에 저장하고 계속", // ko
            "Зберегти першоджерела локально й продовжити", // uk
            "Zapisz oryginały lokalnie i kontynuuj", // pl
            "Захаваць зыходнікі лакальна і працягнуць", // be
            "Τοπική αποθήκευση πρωτοτύπων και συνέχεια", // el
            "Запазване на оригиналите локално и продължаване", // bg
            "Պահպանել սկզբնականները տեղում և շարունակել", // hy
            "საწყისების ლოკალურად შენახვა და გაგრძელება", // ka
        ],
        "settings.combinedShift": [
            "One Shift changes layout; two fix the text", // en
            "Один Shift — раскладка, два — исправить текст", // ru
            "Einmal Umschalt wechselt die Belegung, zweimal korrigiert den Text", // de
            "Un Maj change la disposition, deux corrigent le texte", // fr
            "Una pulsación de Mayús cambia la distribución; dos corrigen el texto", // es
            "Um Shift muda o layout; dois corrigem o texto", // pt
            "按一次 Shift 切换布局，按两次修正文本", // zh
            "Shift 1回でレイアウト切替、2回でテキスト修正", // ja
            "Shift 한 번은 레이아웃 전환, 두 번은 텍스트 수정", // ko
            "Один Shift — розкладка, два — виправити текст", // uk
            "Jeden Shift zmienia układ; dwa poprawiają tekst", // pl
            "Адзін Shift — раскладка, два — выправіць тэкст", // be
            "Ένα Shift αλλάζει διάταξη· δύο διορθώνουν το κείμενο", // el
            "Един Shift сменя подредбата; два поправят текста", // bg
            "Մեկ Shift՝ դասավորություն, երկու՝ տեքստի ուղղում", // hy
            "ერთი Shift — განლაგება, ორი — ტექსტის შესწორება", // ka
        ],
        "settings.combinedShift.tip": [
            "Press either Shift briefly to change layout; double-press to fix the last word or selection. Other shortcuts and holding Shift work as usual.", // en
            "Оба Shift: короткое нажатие меняет раскладку, двойное исправляет последнее слово или выделение. Обычные сочетания и удержание работают как раньше.", // ru
            "Beide Umschalttasten: kurzes Drücken wechselt die Belegung, doppeltes Drücken korrigiert das letzte Wort oder die Auswahl. Andere Kürzel und langes Halten funktionieren wie gewohnt.", // de
            "Les deux touches Maj : un appui bref change la disposition, un double appui corrige le dernier mot ou la sélection. Les autres raccourcis et le maintien de Maj fonctionnent comme avant.", // fr
            "Ambas teclas Mayús: una pulsación breve cambia la distribución y una doble corrige la última palabra o la selección. Los demás atajos y mantener Mayús funcionan como siempre.", // es
            "Ambas as teclas Shift: um toque breve muda o layout e um toque duplo corrige a última palavra ou a seleção. Os outros atalhos e manter o Shift premido funcionam como habitual.", // pt
            "任一 Shift 键：短按切换布局，连按两次修正最后一个单词或所选内容。其他快捷键和按住 Shift 的用法保持不变。", // zh
            "どちらの Shift でも、短く押すとレイアウトを切り替え、2回押すと直前の単語または選択範囲を修正します。ほかのショートカットや Shift の長押しは従来どおり動作します。", // ja
            "양쪽 Shift 모두: 짧게 누르면 레이아웃이 바뀌고, 두 번 누르면 마지막 단어나 선택 영역을 수정합니다. 다른 단축키와 Shift 길게 누르기는 평소처럼 작동합니다.", // ko
            "Обидва Shift: короткий натиск змінює розкладку, подвійний виправляє останнє слово або виділення. Звичайні скорочення та утримання працюють як раніше.", // uk
            "Oba Shifty: krótkie naciśnięcie zmienia układ, podwójne poprawia ostatnie słowo lub zaznaczenie. Inne skróty i przytrzymanie Shift działają jak dotąd.", // pl
            "Абодва Shift: кароткае націсканне мяняе раскладку, двайное выпраўляе апошняе слова або вылучэнне. Звычайныя спалучэнні і ўтрымліванне працуюць як раней.", // be
            "Και τα δύο Shift: το σύντομο πάτημα αλλάζει τη διάταξη, το διπλό διορθώνει την τελευταία λέξη ή την επιλογή. Οι άλλες συντομεύσεις και το παρατεταμένο πάτημα λειτουργούν όπως πριν.", // el
            "И двата Shift: кратко натискане сменя подредбата, двойно поправя последната дума или селекцията. Другите комбинации и задържането работят както преди.", // bg
            "Երկու Shift-երից ցանկացածը. կարճ սեղմումը փոխում է դասավորությունը, կրկնակին ուղղում է վերջին բառը կամ ընտրվածը։ Մյուս դյուրանցումներն ու պահելը աշխատում են ինչպես առաջ։", // hy
            "ორივე Shift: მოკლე დაჭერა ცვლის განლაგებას, ორმაგი ასწორებს ბოლო სიტყვას ან მონიშნულს. სხვა მალსახმობები და Shift-ის დაჭერა ძველებურად მუშაობს.", // ka
        ],
        "settings.shellBridge.tip": [
            "Requires zsh setup and tab access. Open a new terminal window after restarting MacSwitcher. Commands are never run.", // en
            "Требуется настройка zsh и доступ к вкладке. После перезапуска MacSwitcher откройте новое окно терминала. Команды не запускаются.", // ru
            "Erfordert die zsh-Einrichtung und Tab-Zugriff. Öffnen Sie nach dem Neustart von MacSwitcher ein neues Terminalfenster. Es werden nie Befehle ausgeführt.", // de
            "Nécessite la configuration de zsh et l’accès à l’onglet. Ouvrez une nouvelle fenêtre de terminal après le redémarrage de MacSwitcher. Aucune commande n’est jamais exécutée.", // fr
            "Requiere configurar zsh y acceso a la pestaña. Abre una ventana nueva del terminal tras reiniciar MacSwitcher. Nunca se ejecutan comandos.", // es
            "Requer a configuração do zsh e o acesso ao separador. Abra uma nova janela do terminal depois de reiniciar o MacSwitcher. Nunca são executados comandos.", // pt
            "需要设置 zsh 并获得标签页访问权限。重新启动 MacSwitcher 后请打开新的终端窗口。不会运行任何命令。", // zh
            "zsh の設定とタブへのアクセスが必要です。MacSwitcher を再起動したら、新しいターミナルウインドウを開いてください。コマンドは実行されません。", // ja
            "zsh 설정과 탭 접근 권한이 필요합니다. MacSwitcher를 다시 시작한 후 새 터미널 창을 여세요. 명령은 실행되지 않습니다.", // ko
            "Потрібне налаштування zsh і доступ до вкладки. Після перезапуску MacSwitcher відкрийте нове вікно термінала. Команди не виконуються.", // uk
            "Wymaga konfiguracji zsh i dostępu do karty. Po ponownym uruchomieniu MacSwitcher otwórz nowe okno terminala. Polecenia nigdy nie są uruchamiane.", // pl
            "Патрэбная налада zsh і доступ да ўкладкі. Пасля перазапуску MacSwitcher адкрыйце новае акно тэрмінала. Каманды не выконваюцца.", // be
            "Απαιτεί ρύθμιση του zsh και πρόσβαση στην καρτέλα. Μετά την επανεκκίνηση του MacSwitcher ανοίξτε νέο παράθυρο τερματικού. Δεν εκτελούνται ποτέ εντολές.", // el
            "Изисква настройка на zsh и достъп до раздела. След рестартиране на MacSwitcher отворете нов прозорец на терминала. Команди никога не се изпълняват.", // bg
            "Պահանջում է zsh-ի կարգավորում և ներդիրին հասանելիություն։ MacSwitcher-ը վերագործարկելուց հետո բացեք տերմինալի նոր պատուհան։ Հրամաններ երբեք չեն կատարվում։", // hy
            "საჭიროა zsh-ის დაყენება და ჩანართზე წვდომა. MacSwitcher-ის გადატვირთვის შემდეგ გახსენით ტერმინალის ახალი ფანჯარა. ბრძანებები არასოდეს სრულდება.", // ka
        ],
        "settings.russianPriority": [
            "Prefer Russian in ambiguous phrases", // en
            "Приоритет русского в неоднозначных фразах", // ru
            "Russisch bei mehrdeutigen Phrasen bevorzugen", // de
            "Privilégier le russe dans les phrases ambiguës", // fr
            "Priorizar el ruso en frases ambiguas", // es
            "Dar prioridade ao russo em frases ambíguas", // pt
            "在含义不明确的短语中优先使用俄语", // zh
            "判断が難しいフレーズではロシア語を優先", // ja
            "모호한 구문에서는 러시아어 우선", // ko
            "Пріоритет російської в неоднозначних фразах", // uk
            "Preferuj rosyjski w niejednoznacznych frazach", // pl
            "Прыярытэт рускай у неадназначных фразах", // be
            "Προτεραιότητα στα ρωσικά σε αμφίσημες φράσεις", // el
            "Приоритет на руския в неясни фрази", // bg
            "Ռուսերենի առաջնահերթություն անորոշ արտահայտություններում", // hy
            "რუსულის პრიორიტეტი ორაზროვან ფრაზებში", // ka
        ],
        "settings.russianPriority.tip": [
            "Takes effect only when automatic correction is enabled separately.", // en
            "Действует только при отдельно включённом автоисправлении.", // ru
            "Wirkt nur, wenn die automatische Korrektur separat aktiviert ist.", // de
            "N’a d’effet que si la correction automatique est activée séparément.", // fr
            "Solo tiene efecto si la corrección automática está activada por separado.", // es
            "Só tem efeito se a correção automática estiver ativada em separado.", // pt
            "仅在单独开启自动纠错时生效。", // zh
            "自動修正を別途オンにしている場合にのみ有効です。", // ja
            "자동 수정을 별도로 켠 경우에만 적용됩니다.", // ko
            "Діє лише за окремо ввімкненого автовиправлення.", // uk
            "Działa tylko wtedy, gdy autokorekta jest osobno włączona.", // pl
            "Дзейнічае толькі пры асобна ўключаным аўтавыпраўленні.", // be
            "Ισχύει μόνο όταν η αυτόματη διόρθωση είναι ενεργοποιημένη ξεχωριστά.", // el
            "Действа само когато автокорекцията е включена отделно.", // bg
            "Գործում է միայն այն դեպքում, երբ ավտոմատ ուղղումը առանձին միացված է։", // hy
            "მოქმედებს მხოლოდ მაშინ, როცა ავტომატური შესწორება ცალკეა ჩართული.", // ka
        ],
        "settings.report": [
            "Report a problem", // en
            "Сообщить о проблеме", // ru
            "Problem melden", // de
            "Signaler un problème", // fr
            "Informar de un problema", // es
            "Comunicar um problema", // pt
            "报告问题", // zh
            "問題を報告", // ja
            "문제 신고", // ko
            "Повідомити про проблему", // uk
            "Zgłoś problem", // pl
            "Паведаміць пра праблему", // be
            "Αναφορά προβλήματος", // el
            "Съобщаване за проблем", // bg
            "Հաղորդել խնդրի մասին", // hy
            "პრობლემის შეტყობინება", // ka
        ],
        "settings.recoveryAuto": [
            "Automatically save originals after an uncertain edit", // en
            "Автоматически сохранять исходники после сбоя", // ru
            "Originale nach einer unsicheren Änderung automatisch sichern", // de
            "Enregistrer automatiquement les originaux après une modification incertaine", // fr
            "Guardar automáticamente los originales tras un cambio incierto", // es
            "Guardar automaticamente os originais após uma alteração incerta", // pt
            "在修改结果不确定后自动保存原文", // zh
            "不確実な編集の後、元のテキストを自動的に保存", // ja
            "불확실한 수정 후 원본 자동 저장", // ko
            "Автоматично зберігати першоджерела після збою", // uk
            "Automatycznie zapisuj oryginały po niepewnej zmianie", // pl
            "Аўтаматычна захоўваць зыходнікі пасля збою", // be
            "Αυτόματη αποθήκευση πρωτοτύπων μετά από αβέβαιη αλλαγή", // el
            "Автоматично запазване на оригиналите след несигурна промяна", // bg
            "Ավտոմատ պահպանել սկզբնականները անորոշ փոփոխությունից հետո", // hy
            "საწყისების ავტომატური შენახვა ეჭვმიტანილი ცვლილების შემდეგ", // ka
        ],
        "settings.recoveryAuto.hint": [
            "Only after an uncertain edit: the full field text is saved locally in Library/Application Support/MacSwitcher/Recovery. Ordinary typing is not saved; nothing is sent over the network. Off by default.", // en
            "Только при неподтверждённой правке: полный текст поля локально в Library/Application Support/MacSwitcher/Recovery. Обычный ввод не сохраняется; передачи в сеть нет. По умолчанию выключено.", // ru
            "Nur nach einer unsicheren Änderung: Der vollständige Feldtext wird lokal in Library/Application Support/MacSwitcher/Recovery gesichert. Normales Tippen wird nicht gespeichert; es wird nichts über das Netzwerk gesendet. Standardmäßig aus.", // de
            "Uniquement après une modification incertaine : le texte complet du champ est enregistré localement dans Library/Application Support/MacSwitcher/Recovery. La saisie ordinaire n’est pas enregistrée ; rien n’est envoyé sur le réseau. Désactivé par défaut.", // fr
            "Solo tras un cambio incierto: el texto completo del campo se guarda localmente en Library/Application Support/MacSwitcher/Recovery. La escritura normal no se guarda; no se envía nada por la red. Desactivado por defecto.", // es
            "Apenas após uma alteração incerta: o texto completo do campo é guardado localmente em Library/Application Support/MacSwitcher/Recovery. A escrita normal não é guardada; nada é enviado pela rede. Desativado por predefinição.", // pt
            "仅在修改结果不确定时：文本框的完整内容会保存在本地 Library/Application Support/MacSwitcher/Recovery 中。普通输入不会被保存，也不会通过网络发送。默认关闭。", // zh
            "不確実な編集の後のみ：フィールドのテキスト全体が Library/Application Support/MacSwitcher/Recovery にローカル保存されます。通常の入力は保存されず、ネットワークにも送信されません。初期設定ではオフです。", // ja
            "불확실한 수정 후에만: 필드의 전체 텍스트가 Library/Application Support/MacSwitcher/Recovery에 로컬로 저장됩니다. 일반 입력은 저장되지 않으며 네트워크로 전송되지 않습니다. 기본값은 꺼짐입니다.", // ko
            "Лише після непідтвердженої правки: повний текст поля локально в Library/Application Support/MacSwitcher/Recovery. Звичайне введення не зберігається; нічого не передається в мережу. Типово вимкнено.", // uk
            "Tylko po niepewnej zmianie: pełny tekst pola jest zapisywany lokalnie w Library/Application Support/MacSwitcher/Recovery. Zwykłe pisanie nie jest zapisywane; nic nie jest wysyłane przez sieć. Domyślnie wyłączone.", // pl
            "Толькі пры непацверджанай праўцы: поўны тэкст поля лакальна ў Library/Application Support/MacSwitcher/Recovery. Звычайны ўвод не захоўваецца; у сетку нічога не перадаецца. Тыпова выключана.", // be
            "Μόνο μετά από αβέβαιη αλλαγή: το πλήρες κείμενο του πεδίου αποθηκεύεται τοπικά στο Library/Application Support/MacSwitcher/Recovery. Η συνηθισμένη πληκτρολόγηση δεν αποθηκεύεται· δεν στέλνεται τίποτα στο δίκτυο. Απενεργοποιημένο από προεπιλογή.", // el
            "Само след несигурна промяна: пълният текст на полето се запазва локално в Library/Application Support/MacSwitcher/Recovery. Обикновеното писане не се запазва; нищо не се изпраща по мрежата. Изключено по подразбиране.", // bg
            "Միայն անորոշ փոփոխությունից հետո. դաշտի ամբողջ տեքստը պահվում է տեղում՝ Library/Application Support/MacSwitcher/Recovery-ում։ Սովորական մուտքագրումը չի պահվում. ցանցով ոչինչ չի ուղարկվում։ Լռելյայն անջատված է։", // hy
            "მხოლოდ ეჭვმიტანილი ცვლილების შემდეგ: ველის სრული ტექსტი ლოკალურად ინახება Library/Application Support/MacSwitcher/Recovery-ში. ჩვეულებრივი აკრეფა არ ინახება; ქსელში არაფერი იგზავნება. ნაგულისხმევად გამორთულია.", // ka
        ],
        "settings.recoveryAuto.alert.title": [
            "Save full originals locally?", // en
            "Сохранять полные исходники локально?", // ru
            "Vollständige Originale lokal sichern?", // de
            "Enregistrer localement les originaux complets ?", // fr
            "¿Guardar los originales completos localmente?", // es
            "Guardar os originais completos localmente?", // pt
            "要在本地保存完整原文吗？", // zh
            "完全な元のテキストをローカルに保存しますか？", // ja
            "전체 원본을 로컬에 저장할까요?", // ko
            "Зберігати повні першоджерела локально?", // uk
            "Zapisywać pełne oryginały lokalnie?", // pl
            "Захоўваць поўныя зыходнікі лакальна?", // be
            "Τοπική αποθήκευση πλήρων πρωτοτύπων;", // el
            "Да се запазват ли пълните оригинали локално?", // bg
            "Պահպանե՞լ ամբողջական սկզբնականները տեղում։", // hy
            "შევინახო სრული საწყისები ლოკალურად?", // ka
        ],
        "settings.recoveryAuto.alert.body": [
            "After an uncertain edit, MacSwitcher will save the full original field text in your private Recovery folder. Ordinary typing is not recorded and nothing is sent over the network. Archives remain until you delete them.", // en
            "При неподтверждённой правке MacSwitcher автоматически сохранит полный исходный текст поля в личной папке Recovery. Обычный ввод не записывается и ничего не отправляется в сеть. Архивы остаются до вашего удаления.", // ru
            "Nach einer unsicheren Änderung sichert MacSwitcher den vollständigen Originaltext des Feldes in Ihrem privaten Ordner „Recovery“. Normales Tippen wird nicht aufgezeichnet, und es wird nichts über das Netzwerk gesendet. Archive bleiben bestehen, bis Sie sie löschen.", // de
            "Après une modification incertaine, MacSwitcher enregistrera le texte original complet du champ dans votre dossier privé Recovery. La saisie ordinaire n’est pas enregistrée et rien n’est envoyé sur le réseau. Les archives restent jusqu’à ce que vous les supprimiez.", // fr
            "Tras un cambio incierto, MacSwitcher guardará el texto original completo del campo en tu carpeta privada Recovery. La escritura normal no se registra y no se envía nada por la red. Los archivos permanecen hasta que los borres.", // es
            "Após uma alteração incerta, o MacSwitcher guardará o texto original completo do campo na sua pasta privada Recovery. A escrita normal não é registada e nada é enviado pela rede. Os arquivos permanecem até os apagar.", // pt
            "出现不确定的修改后，MacSwitcher 会将文本框的完整原文保存到你的私有 Recovery 文件夹。普通输入不会被记录，也不会通过网络发送。存档会一直保留，直到你删除它们。", // zh
            "不確実な編集の後、MacSwitcher はフィールドの元のテキスト全体を非公開の Recovery フォルダに保存します。通常の入力は記録されず、ネットワークにも送信されません。アーカイブは削除するまで残ります。", // ja
            "불확실한 수정이 있으면 MacSwitcher가 필드의 전체 원본 텍스트를 비공개 Recovery 폴더에 저장합니다. 일반 입력은 기록되지 않으며 네트워크로 전송되지 않습니다. 보관 파일은 삭제하기 전까지 남아 있습니다.", // ko
            "Після непідтвердженої правки MacSwitcher автоматично збереже повний початковий текст поля в особистій папці Recovery. Звичайне введення не записується, і нічого не надсилається в мережу. Архіви залишаються, доки ви їх не видалите.", // uk
            "Po niepewnej zmianie MacSwitcher zapisze pełny tekst oryginalny pola w Twoim prywatnym folderze Recovery. Zwykłe pisanie nie jest rejestrowane i nic nie jest wysyłane przez sieć. Archiwa pozostają, dopóki ich nie usuniesz.", // pl
            "Пры непацверджанай праўцы MacSwitcher аўтаматычна захавае поўны зыходны тэкст поля ў асабістай папцы Recovery. Звычайны ўвод не запісваецца, і нічога не адпраўляецца ў сетку. Архівы застаюцца, пакуль вы іх не выдаліце.", // be
            "Μετά από αβέβαιη αλλαγή, το MacSwitcher θα αποθηκεύσει το πλήρες αρχικό κείμενο του πεδίου στον ιδιωτικό σας φάκελο Recovery. Η συνηθισμένη πληκτρολόγηση δεν καταγράφεται και δεν στέλνεται τίποτα στο δίκτυο. Τα αρχεία παραμένουν μέχρι να τα διαγράψετε.", // el
            "След несигурна промяна MacSwitcher ще запази пълния оригинален текст на полето във вашата лична папка Recovery. Обикновеното писане не се записва и нищо не се изпраща по мрежата. Архивите остават, докато не ги изтриете.", // bg
            "Անորոշ փոփոխությունից հետո MacSwitcher-ը դաշտի ամբողջ սկզբնական տեքստը կպահի ձեր անձնական Recovery պանակում։ Սովորական մուտքագրումը չի գրանցվում, ցանցով ոչինչ չի ուղարկվում։ Արխիվները մնում են, մինչև ջնջեք դրանք։", // hy
            "ეჭვმიტანილი ცვლილების შემდეგ MacSwitcher ველის სრულ საწყის ტექსტს თქვენს პირად Recovery საქაღალდეში შეინახავს. ჩვეულებრივი აკრეფა არ ჩაიწერება და ქსელში არაფერი გაიგზავნება. არქივები რჩება, სანამ არ წაშლით.", // ka
        ],
        "settings.recoveryAuto.alert.enable": [
            "Enable", // en
            "Включить", // ru
            "Aktivieren", // de
            "Activer", // fr
            "Activar", // es
            "Ativar", // pt
            "开启", // zh
            "オンにする", // ja
            "켜기", // ko
            "Увімкнути", // uk
            "Włącz", // pl
            "Уключыць", // be
            "Ενεργοποίηση", // el
            "Включване", // bg
            "Միացնել", // hy
            "ჩართვა", // ka
        ],
    ]
}
