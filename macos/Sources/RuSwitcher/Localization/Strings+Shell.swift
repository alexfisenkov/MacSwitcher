// Переводы на 16 языков (порядок: en, ru, de, fr, es, pt, zh, ja, ko, uk, pl, be, el, bg, hy, ka).
// Терминал и соседний переключатель.

extension L10n {
    static let shellStrings: [String: [String]] = [
        "rival.hint.title": [
            "Another layout switcher is running", // en
            "Рядом работает другой переключатель", // ru
            "Ein anderer Layout-Umschalter läuft", // de
            "Un autre sélecteur de disposition est actif", // fr
            "Hay otro cambiador de distribución activo", // es
            "Outro alternador de layout está ativo", // pt
            "另一个布局切换工具正在运行", // zh
            "別のレイアウト切り替えアプリが動作中です", // ja
            "다른 레이아웃 전환 앱이 실행 중입니다", // ko
            "Поруч працює інший перемикач", // uk
            "Działa inny przełącznik układu", // pl
            "Побач працуе іншы пераключальнік", // be
            "Εκτελείται άλλος εναλλάκτης διάταξης", // el
            "Работи друг превключвател на подредба", // bg
            "Աշխատում է դասավորության մեկ այլ փոխարկիչ", // hy
            "მუშაობს განლაგების სხვა გადამრთველი", // ka
        ],
        "rival.hint.body.named": [
            "Another layout switcher is running nearby (%@). It may interfere with MacSwitcher.", // en
            "Рядом работает другой переключатель раскладки (%@). Он может мешать MacSwitcher.", // ru
            "Ein anderer Layout-Umschalter läuft (%@). Er kann MacSwitcher stören.", // de
            "Un autre sélecteur de disposition est actif (%@). Il peut gêner MacSwitcher.", // fr
            "Hay otro cambiador de distribución activo (%@). Puede interferir con MacSwitcher.", // es
            "Outro alternador de layout está ativo (%@). Pode interferir com o MacSwitcher.", // pt
            "另一个布局切换工具正在运行（%@），可能会干扰 MacSwitcher。", // zh
            "別のレイアウト切り替えアプリ（%@）が動作中です。MacSwitcher の動作を妨げる可能性があります。", // ja
            "다른 레이아웃 전환 앱(%@)이 실행 중입니다. MacSwitcher에 방해가 될 수 있습니다.", // ko
            "Поруч працює інший перемикач розкладки (%@). Він може заважати MacSwitcher.", // uk
            "Działa inny przełącznik układu (%@). Może zakłócać pracę MacSwitcher.", // pl
            "Побач працуе іншы пераключальнік раскладкі (%@). Ён можа замінаць MacSwitcher.", // be
            "Εκτελείται άλλος εναλλάκτης διάταξης (%@). Μπορεί να παρεμβαίνει στο MacSwitcher.", // el
            "Работи друг превключвател на подредба (%@). Той може да пречи на MacSwitcher.", // bg
            "Աշխատում է դասավորության մեկ այլ փոխարկիչ (%@)։ Այն կարող է խանգարել MacSwitcher-ին։", // hy
            "მუშაობს განლაგების სხვა გადამრთველი (%@). მას შეუძლია MacSwitcher-ს ხელი შეუშალოს.", // ka
        ],
        "rival.hint.body.unnamed": [
            "Another layout switcher is running nearby. It may interfere with MacSwitcher.", // en
            "Рядом работает другой переключатель раскладки. Он может мешать MacSwitcher.", // ru
            "Ein anderer Layout-Umschalter läuft. Er kann MacSwitcher stören.", // de
            "Un autre sélecteur de disposition est actif. Il peut gêner MacSwitcher.", // fr
            "Hay otro cambiador de distribución activo. Puede interferir con MacSwitcher.", // es
            "Outro alternador de layout está ativo. Pode interferir com o MacSwitcher.", // pt
            "另一个布局切换工具正在运行，可能会干扰 MacSwitcher。", // zh
            "別のレイアウト切り替えアプリが動作中です。MacSwitcher の動作を妨げる可能性があります。", // ja
            "다른 레이아웃 전환 앱이 실행 중입니다. MacSwitcher에 방해가 될 수 있습니다.", // ko
            "Поруч працює інший перемикач розкладки. Він може заважати MacSwitcher.", // uk
            "Działa inny przełącznik układu. Może zakłócać pracę MacSwitcher.", // pl
            "Побач працуе іншы пераключальнік раскладкі. Ён можа замінаць MacSwitcher.", // be
            "Εκτελείται άλλος εναλλάκτης διάταξης. Μπορεί να παρεμβαίνει στο MacSwitcher.", // el
            "Работи друг превключвател на подредба. Той може да пречи на MacSwitcher.", // bg
            "Աշխատում է դասավորության մեկ այլ փոխարկիչ։ Այն կարող է խանգարել MacSwitcher-ին։", // hy
            "მუშაობს განლაგების სხვა გადამრთველი. მას შეუძლია MacSwitcher-ს ხელი შეუშალოს.", // ka
        ],
        "shell.setup.title": [
            "Connect the command line?", // en
            "Подключить командную строку?", // ru
            "Befehlszeile verbinden?", // de
            "Connecter la ligne de commande ?", // fr
            "¿Conectar la línea de comandos?", // es
            "Ligar a linha de comandos?", // pt
            "要连接命令行吗？", // zh
            "コマンドラインに接続しますか？", // ja
            "명령줄을 연결할까요?", // ko
            "Підключити командний рядок?", // uk
            "Połączyć wiersz poleceń?", // pl
            "Падключыць камандны радок?", // be
            "Σύνδεση της γραμμής εντολών;", // el
            "Да се свърже ли командният ред?", // bg
            "Միացնե՞լ հրամանի տողը։", // hy
            "დავაკავშირო ბრძანების ხაზი?", // ka
        ],
        "shell.setup.explain": [
            "MacSwitcher will add one line to ~/.zshrc so it can fix typing in zsh. A byte-exact private backup is saved first. Then macOS asks once for permission to reach the active terminal tab: it is used only to find the tab, and no commands are run.", // en
            "MacSwitcher добавит в ~/.zshrc одну строку, чтобы исправлять ввод в zsh. Перед записью сохранится точная приватная копия файла. Затем macOS один раз спросит разрешение на доступ к активной вкладке терминала: оно нужно только чтобы найти вкладку, команды не запускаются.", // ru
            "MacSwitcher fügt ~/.zshrc eine Zeile hinzu, um die Eingabe in zsh zu korrigieren. Zuvor wird eine exakte private Sicherung der Datei angelegt. Danach fragt macOS einmal nach der Erlaubnis, auf den aktiven Terminal-Tab zuzugreifen: Sie dient nur dazu, den Tab zu finden, es werden keine Befehle ausgeführt.", // de
            "MacSwitcher ajoutera une ligne à ~/.zshrc pour corriger la saisie dans zsh. Une copie privée exacte du fichier est d’abord enregistrée. Ensuite, macOS demande une fois l’autorisation d’accéder à l’onglet actif du terminal : elle sert uniquement à trouver l’onglet, aucune commande n’est exécutée.", // fr
            "MacSwitcher añadirá una línea a ~/.zshrc para corregir lo que escribas en zsh. Antes se guarda una copia privada exacta del archivo. Después macOS pedirá una vez permiso para acceder a la pestaña activa del terminal: solo sirve para encontrar la pestaña y no se ejecuta ningún comando.", // es
            "O MacSwitcher vai adicionar uma linha a ~/.zshrc para corrigir a escrita no zsh. Antes é guardada uma cópia privada exata do ficheiro. Depois, o macOS pede uma vez permissão para aceder ao separador ativo do terminal: serve apenas para o encontrar e nenhum comando é executado.", // pt
            "MacSwitcher 会向 ~/.zshrc 添加一行，以便修正 zsh 中的输入。写入前会先保存该文件的精确私有备份。随后 macOS 会询问一次是否允许访问当前终端标签页：仅用于找到该标签页，不会运行任何命令。", // zh
            "MacSwitcher は zsh での入力を修正できるよう、~/.zshrc に1行を追加します。書き込む前に、ファイルの完全な非公開バックアップを保存します。その後、macOS がアクティブなターミナルのタブへのアクセス許可を1回尋ねます。タブを見つけるためだけに使い、コマンドは実行しません。", // ja
            "MacSwitcher가 zsh 입력을 수정할 수 있도록 ~/.zshrc에 한 줄을 추가합니다. 쓰기 전에 파일의 정확한 비공개 백업을 저장합니다. 그다음 macOS가 활성 터미널 탭에 접근할 권한을 한 번 묻습니다. 탭을 찾는 데만 사용하며 명령은 실행하지 않습니다.", // ko
            "MacSwitcher додасть до ~/.zshrc один рядок, щоб виправляти введення в zsh. Перед записом буде збережено точну приватну копію файлу. Потім macOS один раз запитає дозвіл на доступ до активної вкладки термінала: він потрібен лише щоб знайти вкладку, команди не виконуються.", // uk
            "MacSwitcher doda do ~/.zshrc jedną linię, aby poprawiać pisanie w zsh. Najpierw zostanie zapisana dokładna prywatna kopia pliku. Potem macOS raz zapyta o zgodę na dostęp do aktywnej karty terminala: służy ona tylko do znalezienia karty, żadne polecenia nie są uruchamiane.", // pl
            "MacSwitcher дадасць у ~/.zshrc адзін радок, каб выпраўляць увод у zsh. Перад запісам будзе захавана дакладная прыватная копія файла. Потым macOS адзін раз запытае дазвол на доступ да актыўнай укладкі тэрмінала: ён патрэбны толькі каб знайсці ўкладку, каманды не выконваюцца.", // be
            "Το MacSwitcher θα προσθέσει μία γραμμή στο ~/.zshrc για να διορθώνει την πληκτρολόγηση στο zsh. Πρώτα αποθηκεύεται ένα ακριβές ιδιωτικό αντίγραφο του αρχείου. Έπειτα το macOS ζητά μία φορά άδεια πρόσβασης στην ενεργή καρτέλα του τερματικού: χρησιμοποιείται μόνο για να βρεθεί η καρτέλα και δεν εκτελούνται εντολές.", // el
            "MacSwitcher ще добави един ред в ~/.zshrc, за да поправя въвеждането в zsh. Първо се запазва точно частно копие на файла. След това macOS веднъж ще поиска разрешение за достъп до активния раздел на терминала: то е нужно само за намиране на раздела, команди не се изпълняват.", // bg
            "MacSwitcher-ը ~/.zshrc-ում մեկ տող կավելացնի՝ zsh-ում մուտքագրումն ուղղելու համար։ Նախ կպահվի ֆայլի ճշգրիտ մասնավոր պատճենը։ Հետո macOS-ը մեկ անգամ կհարցնի տերմինալի ակտիվ ներդիրին հասանելիության թույլտվություն. այն անհրաժեշտ է միայն ներդիրը գտնելու համար, հրամաններ չեն կատարվում։", // hy
            "MacSwitcher დაამატებს ~/.zshrc-ში ერთ ხაზს, რათა zsh-ში აკრეფა გასწორდეს. ჩაწერამდე შეინახება ფაილის ზუსტი პირადი ასლი. შემდეგ macOS ერთხელ მოგთხოვთ ტერმინალის აქტიურ ჩანართზე წვდომის ნებართვას: იგი მხოლოდ ჩანართის საპოვნელად გამოიყენება, ბრძანებები არ სრულდება.", // ka
        ],
        "shell.setup.connect": [
            "Connect", // en
            "Подключить", // ru
            "Verbinden", // de
            "Connecter", // fr
            "Conectar", // es
            "Ligar", // pt
            "连接", // zh
            "接続", // ja
            "연결", // ko
            "Підключити", // uk
            "Połącz", // pl
            "Падключыць", // be
            "Σύνδεση", // el
            "Свързване", // bg
            "Միացնել", // hy
            "დაკავშირება", // ka
        ],
        "shell.setup.cancel": [
            "Cancel", // en
            "Отмена", // ru
            "Abbrechen", // de
            "Annuler", // fr
            "Cancelar", // es
            "Cancelar", // pt
            "取消", // zh
            "キャンセル", // ja
            "취소", // ko
            "Скасувати", // uk
            "Anuluj", // pl
            "Скасаваць", // be
            "Άκυρο", // el
            "Отказ", // bg
            "Չեղարկել", // hy
            "გაუქმება", // ka
        ],
        "shell.setup.failed": [
            "Setup did not finish. Review ~/.zshrc and the private copies in ~/.macswitcher-profile-recovery, then try again.", // en
            "Подключение не завершено. Проверьте ~/.zshrc и приватные копии в ~/.macswitcher-profile-recovery и повторите.", // ru
            "Die Einrichtung wurde nicht abgeschlossen. Prüfen Sie ~/.zshrc und die privaten Kopien in ~/.macswitcher-profile-recovery und versuchen Sie es erneut.", // de
            "La configuration n’a pas abouti. Vérifiez ~/.zshrc et les copies privées dans ~/.macswitcher-profile-recovery, puis réessayez.", // fr
            "La configuración no se completó. Revisa ~/.zshrc y las copias privadas en ~/.macswitcher-profile-recovery y vuelve a intentarlo.", // es
            "A configuração não foi concluída. Verifique o ~/.zshrc e as cópias privadas em ~/.macswitcher-profile-recovery e tente novamente.", // pt
            "设置未完成。请检查 ~/.zshrc 和 ~/.macswitcher-profile-recovery 中的私有副本，然后重试。", // zh
            "設定が完了しませんでした。~/.zshrc と ~/.macswitcher-profile-recovery 内の非公開コピーを確認して、もう一度お試しください。", // ja
            "설정이 완료되지 않았습니다. ~/.zshrc와 ~/.macswitcher-profile-recovery의 비공개 사본을 확인한 후 다시 시도하세요.", // ko
            "Підключення не завершено. Перевірте ~/.zshrc і приватні копії в ~/.macswitcher-profile-recovery та повторіть.", // uk
            "Konfiguracja nie została zakończona. Sprawdź ~/.zshrc i prywatne kopie w ~/.macswitcher-profile-recovery, a potem spróbuj ponownie.", // pl
            "Падключэнне не завершана. Праверце ~/.zshrc і прыватныя копіі ў ~/.macswitcher-profile-recovery і паўтарыце.", // be
            "Η ρύθμιση δεν ολοκληρώθηκε. Ελέγξτε το ~/.zshrc και τα ιδιωτικά αντίγραφα στο ~/.macswitcher-profile-recovery και δοκιμάστε ξανά.", // el
            "Настройката не завърши. Проверете ~/.zshrc и частните копия в ~/.macswitcher-profile-recovery и опитайте отново.", // bg
            "Կարգավորումը չավարտվեց։ Ստուգեք ~/.zshrc-ը և ~/.macswitcher-profile-recovery-ի մասնավոր պատճենները, ապա կրկնեք։", // hy
            "დაყენება არ დასრულდა. შეამოწმეთ ~/.zshrc და ~/.macswitcher-profile-recovery-ში არსებული პირადი ასლები, შემდეგ სცადეთ ხელახლა.", // ka
        ],
        "shell.setup.done.installed": [
            "The line was added.", // en
            "Строка добавлена.", // ru
            "Die Zeile wurde hinzugefügt.", // de
            "La ligne a été ajoutée.", // fr
            "Se ha añadido la línea.", // es
            "A linha foi adicionada.", // pt
            "已添加该行。", // zh
            "行を追加しました。", // ja
            "줄을 추가했습니다.", // ko
            "Рядок додано.", // uk
            "Linia została dodana.", // pl
            "Радок дададзены.", // be
            "Η γραμμή προστέθηκε.", // el
            "Редът е добавен.", // bg
            "Տողը ավելացվեց։", // hy
            "ხაზი დაემატა.", // ka
        ],
        "shell.setup.done.granted": [
            "Terminal tab access is allowed.", // en
            "Доступ к вкладке терминала разрешён.", // ru
            "Der Zugriff auf den Terminal-Tab ist erlaubt.", // de
            "L’accès à l’onglet du terminal est autorisé.", // fr
            "El acceso a la pestaña del terminal está permitido.", // es
            "O acesso ao separador do terminal está permitido.", // pt
            "已允许访问终端标签页。", // zh
            "ターミナルのタブへのアクセスが許可されました。", // ja
            "터미널 탭 접근이 허용되었습니다.", // ko
            "Доступ до вкладки термінала дозволено.", // uk
            "Dostęp do karty terminala jest dozwolony.", // pl
            "Доступ да ўкладкі тэрмінала дазволены.", // be
            "Η πρόσβαση στην καρτέλα του τερματικού επιτρέπεται.", // el
            "Достъпът до раздела на терминала е разрешен.", // bg
            "Տերմինալի ներդիրին հասանելիությունը թույլատրված է։", // hy
            "ტერმინალის ჩანართზე წვდომა ნებადართულია.", // ka
        ],
        "shell.setup.done.denied": [
            "Tab access was not granted yet: press the button again when you are ready.", // en
            "Доступ к вкладке пока не получен: нажмите кнопку ещё раз, когда будете готовы.", // ru
            "Der Zugriff auf den Tab wurde noch nicht erteilt: Drücken Sie die Taste erneut, wenn Sie bereit sind.", // de
            "L’accès à l’onglet n’a pas encore été accordé : appuyez de nouveau sur le bouton quand vous serez prêt.", // fr
            "Aún no se ha concedido el acceso a la pestaña: vuelve a pulsar el botón cuando estés listo.", // es
            "O acesso ao separador ainda não foi concedido: prima novamente o botão quando estiver pronto.", // pt
            "尚未获得标签页访问权限：准备好后请再次点击该按钮。", // zh
            "タブへのアクセスはまだ許可されていません。準備ができたら、もう一度ボタンを押してください。", // ja
            "탭 접근이 아직 허용되지 않았습니다. 준비되면 버튼을 다시 누르세요.", // ko
            "Доступ до вкладки ще не отримано: натисніть кнопку ще раз, коли будете готові.", // uk
            "Dostęp do karty nie został jeszcze przyznany: naciśnij przycisk ponownie, gdy będziesz gotowy.", // pl
            "Доступ да ўкладкі пакуль не атрыманы: націсніце кнопку яшчэ раз, калі будзеце гатовыя.", // be
            "Η πρόσβαση στην καρτέλα δεν έχει δοθεί ακόμη: πατήστε ξανά το κουμπί όταν είστε έτοιμοι.", // el
            "Достъпът до раздела още не е получен: натиснете бутона отново, когато сте готови.", // bg
            "Ներդիրին հասանելիությունը դեռ չի տրվել. պատրաստ լինելիս նորից սեղմեք կոճակը։", // hy
            "ჩანართზე წვდომა ჯერ არ არის მიღებული: მზად რომ იქნებით, ღილაკს ხელახლა დააჭირეთ.", // ka
        ],
        "shell.setup.done.noTerminal": [
            "Open one terminal (for example Ghostty) and press the button again to grant access.", // en
            "Откройте один терминал (например, Ghostty) и нажмите кнопку ещё раз, чтобы выдать доступ.", // ru
            "Öffnen Sie ein Terminal (zum Beispiel Ghostty) und drücken Sie die Taste erneut, um den Zugriff zu erteilen.", // de
            "Ouvrez un terminal (par exemple Ghostty) et appuyez de nouveau sur le bouton pour accorder l’accès.", // fr
            "Abre un terminal (por ejemplo, Ghostty) y vuelve a pulsar el botón para conceder el acceso.", // es
            "Abra um terminal (por exemplo, o Ghostty) e prima novamente o botão para conceder o acesso.", // pt
            "请打开一个终端（例如 Ghostty），然后再次点击该按钮以授予访问权限。", // zh
            "ターミナル（例：Ghostty）を1つ開き、もう一度ボタンを押してアクセスを許可してください。", // ja
            "터미널(예: Ghostty)을 하나 열고 버튼을 다시 눌러 접근을 허용하세요.", // ko
            "Відкрийте один термінал (наприклад, Ghostty) і натисніть кнопку ще раз, щоб надати доступ.", // uk
            "Otwórz jeden terminal (na przykład Ghostty) i naciśnij przycisk ponownie, aby przyznać dostęp.", // pl
            "Адкрыйце адзін тэрмінал (напрыклад, Ghostty) і націсніце кнопку яшчэ раз, каб выдаць доступ.", // be
            "Ανοίξτε ένα τερματικό (για παράδειγμα Ghostty) και πατήστε ξανά το κουμπί για να δώσετε πρόσβαση.", // el
            "Отворете един терминал (например Ghostty) и натиснете бутона отново, за да дадете достъп.", // bg
            "Բացեք մեկ տերմինալ (օրինակ՝ Ghostty) և նորից սեղմեք կոճակը՝ հասանելիություն տալու համար։", // hy
            "გახსენით ერთი ტერმინალი (მაგალითად, Ghostty) და ღილაკს ხელახლა დააჭირეთ წვდომის მისაცემად.", // ka
        ],
        "shell.setup.done.newWindow": [
            "Open a new terminal window for the setup to take effect.", // en
            "Откройте новое окно терминала, чтобы подключение заработало.", // ru
            "Öffnen Sie ein neues Terminalfenster, damit die Einrichtung wirksam wird.", // de
            "Ouvrez une nouvelle fenêtre de terminal pour que la configuration prenne effet.", // fr
            "Abre una ventana nueva del terminal para que la configuración surta efecto.", // es
            "Abra uma nova janela do terminal para a configuração ter efeito.", // pt
            "请打开新的终端窗口，使设置生效。", // zh
            "設定を反映するには、新しいターミナルウインドウを開いてください。", // ja
            "설정을 적용하려면 새 터미널 창을 여세요.", // ko
            "Відкрийте нове вікно термінала, щоб підключення запрацювало.", // uk
            "Otwórz nowe okno terminala, aby konfiguracja zaczęła działać.", // pl
            "Адкрыйце новае акно тэрмінала, каб падключэнне запрацавала.", // be
            "Ανοίξτε ένα νέο παράθυρο τερματικού για να τεθεί σε ισχύ η ρύθμιση.", // el
            "Отворете нов прозорец на терминала, за да влезе в сила настройката.", // bg
            "Բացեք տերմինալի նոր պատուհան, որպեսզի կարգավորումն ուժի մեջ մտնի։", // hy
            "გახსენით ტერმინალის ახალი ფანჯარა, რომ დაყენება ამოქმედდეს.", // ka
        ],
        "shell.terminalLine.memoryLocalFailed": [
            "The original terminal line remains in memory; local saving failed.", // en
            "Исходная строка терминала осталась в памяти; локальное сохранение не удалось.", // ru
            "Die ursprüngliche Terminalzeile bleibt im Speicher; das lokale Sichern ist fehlgeschlagen.", // de
            "La ligne d’origine du terminal reste en mémoire ; l’enregistrement local a échoué.", // fr
            "La línea original del terminal sigue en memoria; no se pudo guardar localmente.", // es
            "A linha original do terminal permanece na memória; a gravação local falhou.", // pt
            "终端的原始行仍保留在内存中；本地保存失败。", // zh
            "ターミナルの元の行はメモリに残っています。ローカルへの保存に失敗しました。", // ja
            "터미널의 원래 줄은 메모리에 남아 있습니다. 로컬 저장에 실패했습니다.", // ko
            "Початковий рядок термінала залишився в пам’яті; локальне збереження не вдалося.", // uk
            "Oryginalna linia terminala pozostała w pamięci; zapis lokalny nie powiódł się.", // pl
            "Зыходны радок тэрмінала застаўся ў памяці; лакальнае захаванне не атрымалася.", // be
            "Η αρχική γραμμή του τερματικού παραμένει στη μνήμη· η τοπική αποθήκευση απέτυχε.", // el
            "Първоначалният ред на терминала остава в паметта; локалното запазване не успя.", // bg
            "Տերմինալի սկզբնական տողը մնացել է հիշողության մեջ. տեղային պահպանումը չհաջողվեց։", // hy
            "ტერმინალის საწყისი ხაზი მეხსიერებაში დარჩა; ლოკალური შენახვა ვერ მოხერხდა.", // ka
        ],
        "shell.terminalLine.memoryFailed": [
            "The original terminal line remains in memory; saving failed.", // en
            "Исходная строка терминала осталась в памяти; сохранение не удалось.", // ru
            "Die ursprüngliche Terminalzeile bleibt im Speicher; das Sichern ist fehlgeschlagen.", // de
            "La ligne d’origine du terminal reste en mémoire ; l’enregistrement a échoué.", // fr
            "La línea original del terminal sigue en memoria; no se pudo guardar.", // es
            "A linha original do terminal permanece na memória; a gravação falhou.", // pt
            "终端的原始行仍保留在内存中；保存失败。", // zh
            "ターミナルの元の行はメモリに残っています。保存に失敗しました。", // ja
            "터미널의 원래 줄은 메모리에 남아 있습니다. 저장에 실패했습니다.", // ko
            "Початковий рядок термінала залишився в пам’яті; збереження не вдалося.", // uk
            "Oryginalna linia terminala pozostała w pamięci; zapis nie powiódł się.", // pl
            "Зыходны радок тэрмінала застаўся ў памяці; захаванне не атрымалася.", // be
            "Η αρχική γραμμή του τερματικού παραμένει στη μνήμη· η αποθήκευση απέτυχε.", // el
            "Първоначалният ред на терминала остава в паметта; запазването не успя.", // bg
            "Տերմինալի սկզբնական տողը մնացել է հիշողության մեջ. պահպանումը չհաջողվեց։", // hy
            "ტერმინალის საწყისი ხაზი მეხსიერებაში დარჩა; შენახვა ვერ მოხერხდა.", // ka
        ],
        "shell.bridge.resourceMissing": [
            "The packaged shell resource is missing.", // en
            "Ресурс подключения отсутствует в приложении.", // ru
            "Die mitgelieferte Shell-Ressource fehlt.", // de
            "La ressource shell intégrée est introuvable.", // fr
            "Falta el recurso de shell incluido en la app.", // es
            "O recurso de shell incluído na app está em falta.", // pt
            "应用中缺少内置的 shell 资源。", // zh
            "アプリ内の shell リソースが見つかりません。", // ja
            "앱에 포함된 셸 리소스가 없습니다.", // ko
            "Ресурс підключення відсутній у застосунку.", // uk
            "W aplikacji brakuje zasobu powłoki.", // pl
            "Рэсурс падключэння адсутнічае ў праграме.", // be
            "Λείπει ο ενσωματωμένος πόρος του shell.", // el
            "Липсва вграденият ресурс на shell.", // bg
            "Հավելվածում բացակայում է shell-ի ներկառուցված ռեսուրսը։", // hy
            "აპლიკაციაში shell-ის ჩაშენებული რესურსი არ არის.", // ka
        ],
        "shell.bridge.title.installed": [
            "zsh integration is installed", // en
            "Подключение zsh установлено", // ru
            "Die zsh-Anbindung ist installiert", // de
            "L’intégration zsh est installée", // fr
            "La integración con zsh está instalada", // es
            "A integração com o zsh está instalada", // pt
            "zsh 集成已安装", // zh
            "zsh 連携はインストール済みです", // ja
            "zsh 연동이 설치되어 있습니다", // ko
            "Підключення zsh встановлено", // uk
            "Integracja z zsh jest zainstalowana", // pl
            "Падключэнне zsh усталявана", // be
            "Η ενσωμάτωση zsh είναι εγκατεστημένη", // el
            "Интеграцията с zsh е инсталирана", // bg
            "zsh-ի ինտեգրումը տեղադրված է", // hy
            "zsh-ის ინტეგრაცია დაყენებულია", // ka
        ],
        "shell.bridge.title.connect": [
            "Connect zsh to MacSwitcher?", // en
            "Подключить zsh к MacSwitcher?", // ru
            "zsh mit MacSwitcher verbinden?", // de
            "Connecter zsh à MacSwitcher ?", // fr
            "¿Conectar zsh con MacSwitcher?", // es
            "Ligar o zsh ao MacSwitcher?", // pt
            "要将 zsh 连接到 MacSwitcher 吗？", // zh
            "zsh を MacSwitcher に接続しますか？", // ja
            "zsh를 MacSwitcher에 연결할까요?", // ko
            "Підключити zsh до MacSwitcher?", // uk
            "Połączyć zsh z MacSwitcher?", // pl
            "Падключыць zsh да MacSwitcher?", // be
            "Σύνδεση του zsh με το MacSwitcher;", // el
            "Да се свърже ли zsh с MacSwitcher?", // bg
            "Միացնե՞լ zsh-ը MacSwitcher-ին։", // hy
            "დავაკავშირო zsh MacSwitcher-თან?", // ka
        ],
        "shell.bridge.body": [
            "Installing or removing changes exactly one line in ~/.zshrc. A byte-exact private backup (0600) is saved first. Open a new terminal window afterward. Tab access is requested separately.", // en
            "При установке или удалении меняется только одна строка ~/.zshrc. Перед записью сохранится точная приватная копия (0600). После изменения откройте новое окно терминала. Доступ к вкладке запрашивается отдельно.", // ru
            "Beim Installieren oder Entfernen wird genau eine Zeile in ~/.zshrc geändert. Zuvor wird eine exakte private Sicherung (0600) angelegt. Öffnen Sie danach ein neues Terminalfenster. Der Zugriff auf den Tab wird separat angefragt.", // de
            "L’installation ou la suppression ne modifie qu’une seule ligne de ~/.zshrc. Une copie privée exacte (0600) est d’abord enregistrée. Ouvrez ensuite une nouvelle fenêtre de terminal. L’accès à l’onglet est demandé séparément.", // fr
            "Al instalar o quitar solo se cambia una línea de ~/.zshrc. Antes se guarda una copia privada exacta (0600). Después abre una ventana nueva del terminal. El acceso a la pestaña se solicita por separado.", // es
            "Ao instalar ou remover, apenas uma linha de ~/.zshrc é alterada. Antes é guardada uma cópia privada exata (0600). Depois abra uma nova janela do terminal. O acesso ao separador é pedido em separado.", // pt
            "安装或移除只会更改 ~/.zshrc 中的一行。写入前会先保存精确的私有备份（0600）。之后请打开新的终端窗口。标签页访问权限需另行请求。", // zh
            "インストールまたは削除で変更されるのは ~/.zshrc の1行だけです。変更前に完全な非公開バックアップ（0600）を保存します。その後、新しいターミナルウインドウを開いてください。タブへのアクセスは別途リクエストします。", // ja
            "설치하거나 제거할 때 ~/.zshrc의 한 줄만 바뀝니다. 먼저 정확한 비공개 백업(0600)을 저장합니다. 이후 새 터미널 창을 여세요. 탭 접근은 별도로 요청합니다.", // ko
            "Під час встановлення або видалення змінюється лише один рядок ~/.zshrc. Перед записом буде збережено точну приватну копію (0600). Після змін відкрийте нове вікно термінала. Доступ до вкладки запитується окремо.", // uk
            "Instalacja lub usunięcie zmienia dokładnie jedną linię w ~/.zshrc. Najpierw zostanie zapisana dokładna prywatna kopia (0600). Potem otwórz nowe okno terminala. Dostęp do karty jest wymagany osobno.", // pl
            "Пры ўсталёўцы або выдаленні мяняецца толькі адзін радок ~/.zshrc. Перад запісам будзе захавана дакладная прыватная копія (0600). Пасля змены адкрыйце новае акно тэрмінала. Доступ да ўкладкі запытваецца асобна.", // be
            "Η εγκατάσταση ή η αφαίρεση αλλάζει ακριβώς μία γραμμή στο ~/.zshrc. Πρώτα αποθηκεύεται ένα ακριβές ιδιωτικό αντίγραφο (0600). Έπειτα ανοίξτε νέο παράθυρο τερματικού. Η πρόσβαση στην καρτέλα ζητείται ξεχωριστά.", // el
            "При инсталиране или премахване се променя точно един ред в ~/.zshrc. Първо се запазва точно частно копие (0600). После отворете нов прозорец на терминала. Достъпът до раздела се иска отделно.", // bg
            "Տեղադրելիս կամ հեռացնելիս փոխվում է ~/.zshrc-ի միայն մեկ տողը։ Նախ կպահվի ճշգրիտ մասնավոր պատճեն (0600)։ Դրանից հետո բացեք տերմինալի նոր պատուհան։ Ներդիրին հասանելիությունը հարցվում է առանձին։", // hy
            "ინსტალაციისას ან წაშლისას ~/.zshrc-ში იცვლება მხოლოდ ერთი ხაზი. ჯერ შეინახება ზუსტი პირადი ასლი (0600). შემდეგ გახსენით ტერმინალის ახალი ფანჯარა. ჩანართზე წვდომა ცალკე მოითხოვება.", // ka
        ],
        "shell.bridge.requestTabAccess": [
            "Request tab access", // en
            "Запросить доступ к вкладке", // ru
            "Tab-Zugriff anfragen", // de
            "Demander l’accès à l’onglet", // fr
            "Solicitar acceso a la pestaña", // es
            "Pedir acesso ao separador", // pt
            "请求标签页访问权限", // zh
            "タブへのアクセスをリクエスト", // ja
            "탭 접근 요청", // ko
            "Запросити доступ до вкладки", // uk
            "Poproś o dostęp do karty", // pl
            "Запытаць доступ да ўкладкі", // be
            "Αίτημα πρόσβασης στην καρτέλα", // el
            "Заявяване на достъп до раздела", // bg
            "Խնդրել հասանելիություն ներդիրին", // hy
            "ჩანართზე წვდომის მოთხოვნა", // ka
        ],
        "shell.bridge.removeLine": [
            "Remove line", // en
            "Удалить строку", // ru
            "Zeile entfernen", // de
            "Supprimer la ligne", // fr
            "Quitar línea", // es
            "Remover linha", // pt
            "移除该行", // zh
            "行を削除", // ja
            "줄 제거", // ko
            "Видалити рядок", // uk
            "Usuń linię", // pl
            "Выдаліць радок", // be
            "Αφαίρεση γραμμής", // el
            "Премахване на реда", // bg
            "Հեռացնել տողը", // hy
            "ხაზის წაშლა", // ka
        ],
        "shell.bridge.installLine": [
            "Install line", // en
            "Установить строку", // ru
            "Zeile installieren", // de
            "Installer la ligne", // fr
            "Instalar línea", // es
            "Instalar linha", // pt
            "安装该行", // zh
            "行をインストール", // ja
            "줄 설치", // ko
            "Встановити рядок", // uk
            "Zainstaluj linię", // pl
            "Усталяваць радок", // be
            "Εγκατάσταση γραμμής", // el
            "Инсталиране на реда", // bg
            "Տեղադրել տողը", // hy
            "ხაზის დაყენება", // ka
        ],
        "shell.bridge.removed": [
            "Integration removed", // en
            "Подключение удалено", // ru
            "Anbindung entfernt", // de
            "Intégration supprimée", // fr
            "Integración eliminada", // es
            "Integração removida", // pt
            "集成已移除", // zh
            "連携を削除しました", // ja
            "연동을 제거했습니다", // ko
            "Підключення видалено", // uk
            "Integracja usunięta", // pl
            "Падключэнне выдалена", // be
            "Η ενσωμάτωση αφαιρέθηκε", // el
            "Интеграцията е премахната", // bg
            "Ինտեգրումը հեռացվեց", // hy
            "ინტეგრაცია წაიშალა", // ka
        ],
        "shell.bridge.installed": [
            "Integration installed", // en
            "Подключение установлено", // ru
            "Anbindung installiert", // de
            "Intégration installée", // fr
            "Integración instalada", // es
            "Integração instalada", // pt
            "集成已安装", // zh
            "連携をインストールしました", // ja
            "연동을 설치했습니다", // ko
            "Підключення встановлено", // uk
            "Integracja zainstalowana", // pl
            "Падключэнне ўсталявана", // be
            "Η ενσωμάτωση εγκαταστάθηκε", // el
            "Интеграцията е инсталирана", // bg
            "Ինտեգրումը տեղադրվեց", // hy
            "ინტეგრაცია დაყენდა", // ka
        ],
        "shell.bridge.done": [
            "%1$@. Open a new terminal window. Backup: %2$@.", // en
            "%1$@. Откройте новое окно терминала. Резервная копия: %2$@.", // ru
            "%1$@. Öffnen Sie ein neues Terminalfenster. Sicherung: %2$@.", // de
            "%1$@. Ouvrez une nouvelle fenêtre de terminal. Copie de sauvegarde : %2$@.", // fr
            "%1$@. Abre una ventana nueva del terminal. Copia de seguridad: %2$@.", // es
            "%1$@. Abra uma nova janela do terminal. Cópia de segurança: %2$@.", // pt
            "%1$@。请打开新的终端窗口。备份：%2$@。", // zh
            "%1$@。新しいターミナルウインドウを開いてください。バックアップ：%2$@。", // ja
            "%1$@. 새 터미널 창을 여세요. 백업: %2$@.", // ko
            "%1$@. Відкрийте нове вікно термінала. Резервна копія: %2$@.", // uk
            "%1$@. Otwórz nowe okno terminala. Kopia zapasowa: %2$@.", // pl
            "%1$@. Адкрыйце новае акно тэрмінала. Рэзервовая копія: %2$@.", // be
            "%1$@. Ανοίξτε νέο παράθυρο τερματικού. Αντίγραφο ασφαλείας: %2$@.", // el
            "%1$@. Отворете нов прозорец на терминала. Резервно копие: %2$@.", // bg
            "%1$@։ Բացեք տերմինալի նոր պատուհան։ Պահուստային պատճեն՝ %2$@։", // hy
            "%1$@. გახსენით ტერმინალის ახალი ფანჯარა. სარეზერვო ასლი: %2$@.", // ka
        ],
        "shell.bridge.conflict": [
            "Another editor changed ~/.zshrc during setup. The current file and private copies are preserved in ~/.macswitcher-profile-recovery. Review them before retrying.", // en
            "Другой редактор изменил ~/.zshrc во время настройки. Текущий файл и приватные копии сохранены в ~/.macswitcher-profile-recovery. Проверьте их перед повтором.", // ru
            "Ein anderer Editor hat ~/.zshrc während der Einrichtung geändert. Die aktuelle Datei und private Kopien liegen in ~/.macswitcher-profile-recovery. Prüfen Sie sie vor einem neuen Versuch.", // de
            "Un autre éditeur a modifié ~/.zshrc pendant la configuration. Le fichier actuel et les copies privées sont conservés dans ~/.macswitcher-profile-recovery. Vérifiez-les avant de réessayer.", // fr
            "Otro editor modificó ~/.zshrc durante la configuración. El archivo actual y las copias privadas se conservan en ~/.macswitcher-profile-recovery. Revísalos antes de reintentar.", // es
            "Outro editor alterou o ~/.zshrc durante a configuração. O ficheiro atual e as cópias privadas ficaram em ~/.macswitcher-profile-recovery. Verifique-os antes de tentar novamente.", // pt
            "设置期间另一个编辑器修改了 ~/.zshrc。当前文件和私有副本已保存在 ~/.macswitcher-profile-recovery 中。重试前请先检查。", // zh
            "設定中に別のエディタが ~/.zshrc を変更しました。現在のファイルと非公開コピーは ~/.macswitcher-profile-recovery に保存されています。やり直す前に確認してください。", // ja
            "설정하는 동안 다른 편집기가 ~/.zshrc를 변경했습니다. 현재 파일과 비공개 사본은 ~/.macswitcher-profile-recovery에 보관되어 있습니다. 다시 시도하기 전에 확인하세요.", // ko
            "Інший редактор змінив ~/.zshrc під час налаштування. Поточний файл і приватні копії збережено в ~/.macswitcher-profile-recovery. Перевірте їх перед повтором.", // uk
            "Inny edytor zmienił ~/.zshrc podczas konfiguracji. Bieżący plik i prywatne kopie zachowano w ~/.macswitcher-profile-recovery. Sprawdź je przed ponowną próbą.", // pl
            "Іншы рэдактар змяніў ~/.zshrc падчас налады. Бягучы файл і прыватныя копіі захаваны ў ~/.macswitcher-profile-recovery. Праверце іх перад паўторам.", // be
            "Άλλος επεξεργαστής άλλαξε το ~/.zshrc κατά τη ρύθμιση. Το τρέχον αρχείο και τα ιδιωτικά αντίγραφα διατηρούνται στο ~/.macswitcher-profile-recovery. Ελέγξτε τα πριν δοκιμάσετε ξανά.", // el
            "Друг редактор промени ~/.zshrc по време на настройката. Текущият файл и частните копия са запазени в ~/.macswitcher-profile-recovery. Проверете ги, преди да опитате отново.", // bg
            "Մեկ այլ խմբագրիչ փոխել է ~/.zshrc-ը կարգավորման ժամանակ։ Ընթացիկ ֆայլը և մասնավոր պատճենները պահպանված են ~/.macswitcher-profile-recovery-ում։ Կրկնելուց առաջ ստուգեք դրանք։", // hy
            "სხვა რედაქტორმა შეცვალა ~/.zshrc დაყენებისას. მიმდინარე ფაილი და პირადი ასლები შენახულია ~/.macswitcher-profile-recovery-ში. გადახედეთ მათ ხელახლა ცდამდე.", // ka
        ],
        "shell.bridge.failed": [
            "Setup did not finish. Review ~/.zshrc and private copies in ~/.macswitcher-profile-recovery before retrying.", // en
            "Настройка не завершена. Проверьте ~/.zshrc и приватные копии в ~/.macswitcher-profile-recovery перед повтором.", // ru
            "Die Einrichtung wurde nicht abgeschlossen. Prüfen Sie ~/.zshrc und die privaten Kopien in ~/.macswitcher-profile-recovery vor einem neuen Versuch.", // de
            "La configuration n’a pas abouti. Vérifiez ~/.zshrc et les copies privées dans ~/.macswitcher-profile-recovery avant de réessayer.", // fr
            "La configuración no se completó. Revisa ~/.zshrc y las copias privadas en ~/.macswitcher-profile-recovery antes de reintentar.", // es
            "A configuração não foi concluída. Verifique o ~/.zshrc e as cópias privadas em ~/.macswitcher-profile-recovery antes de tentar novamente.", // pt
            "设置未完成。重试前请检查 ~/.zshrc 和 ~/.macswitcher-profile-recovery 中的私有副本。", // zh
            "設定が完了しませんでした。やり直す前に ~/.zshrc と ~/.macswitcher-profile-recovery 内の非公開コピーを確認してください。", // ja
            "설정이 완료되지 않았습니다. 다시 시도하기 전에 ~/.zshrc와 ~/.macswitcher-profile-recovery의 비공개 사본을 확인하세요.", // ko
            "Налаштування не завершено. Перевірте ~/.zshrc і приватні копії в ~/.macswitcher-profile-recovery перед повтором.", // uk
            "Konfiguracja nie została zakończona. Przed ponowną próbą sprawdź ~/.zshrc i prywatne kopie w ~/.macswitcher-profile-recovery.", // pl
            "Налада не завершана. Праверце ~/.zshrc і прыватныя копіі ў ~/.macswitcher-profile-recovery перад паўторам.", // be
            "Η ρύθμιση δεν ολοκληρώθηκε. Ελέγξτε το ~/.zshrc και τα ιδιωτικά αντίγραφα στο ~/.macswitcher-profile-recovery πριν δοκιμάσετε ξανά.", // el
            "Настройката не завърши. Проверете ~/.zshrc и частните копия в ~/.macswitcher-profile-recovery, преди да опитате отново.", // bg
            "Կարգավորումը չավարտվեց։ Կրկնելուց առաջ ստուգեք ~/.zshrc-ը և ~/.macswitcher-profile-recovery-ի մասնավոր պատճենները։", // hy
            "დაყენება არ დასრულდა. ხელახლა ცდამდე შეამოწმეთ ~/.zshrc და ~/.macswitcher-profile-recovery-ში არსებული პირადი ასლები.", // ka
        ],
        "shell.consent.noHost": [
            "Open one compatible terminal and request access again.", // en
            "Откройте один совместимый терминал и повторите запрос доступа.", // ru
            "Öffnen Sie ein kompatibles Terminal und fragen Sie den Zugriff erneut an.", // de
            "Ouvrez un terminal compatible et redemandez l’accès.", // fr
            "Abre un terminal compatible y vuelve a solicitar el acceso.", // es
            "Abra um terminal compatível e peça novamente o acesso.", // pt
            "请打开一个兼容的终端，然后再次请求访问权限。", // zh
            "対応するターミナルを1つ開いて、もう一度アクセスをリクエストしてください。", // ja
            "호환되는 터미널을 하나 열고 접근을 다시 요청하세요.", // ko
            "Відкрийте один сумісний термінал і повторіть запит доступу.", // uk
            "Otwórz jeden zgodny terminal i ponów prośbę o dostęp.", // pl
            "Адкрыйце адзін сумяшчальны тэрмінал і паўтарыце запыт доступу.", // be
            "Ανοίξτε ένα συμβατό τερματικό και ζητήστε ξανά πρόσβαση.", // el
            "Отворете един съвместим терминал и заявете достъп отново.", // bg
            "Բացեք մեկ համատեղելի տերմինալ և նորից խնդրեք հասանելիություն։", // hy
            "გახსენით ერთი თავსებადი ტერმინალი და წვდომა ხელახლა მოითხოვეთ.", // ka
        ],
        "shell.consent.title": [
            "Allow active-tab lookup?", // en
            "Разрешить определять активную вкладку?", // ru
            "Suche nach dem aktiven Tab erlauben?", // de
            "Autoriser la détection de l’onglet actif ?", // fr
            "¿Permitir detectar la pestaña activa?", // es
            "Permitir a deteção do separador ativo?", // pt
            "允许识别当前标签页吗？", // zh
            "アクティブなタブの特定を許可しますか？", // ja
            "활성 탭 확인을 허용할까요?", // ko
            "Дозволити визначати активну вкладку?", // uk
            "Zezwolić na wykrywanie aktywnej karty?", // pl
            "Дазволіць вызначаць актыўную ўкладку?", // be
            "Να επιτραπεί ο εντοπισμός της ενεργής καρτέλας;", // el
            "Да се разреши ли откриването на активния раздел?", // bg
            "Թույլատրե՞լ ակտիվ ներդիրի որոշումը։", // hy
            "დაიშვას აქტიური ჩანართის დადგენა?", // ka
        ],
        "shell.consent.body": [
            "%@: macOS may call this permission “control the app.” MacSwitcher uses it only to identify the active terminal tab. No commands are run.", // en
            "%@: macOS может назвать разрешение «управлением приложением». MacSwitcher использует его только чтобы определить активную вкладку терминала. Команды не запускаются.", // ru
            "%@: macOS bezeichnet diese Berechtigung möglicherweise als „App steuern“. MacSwitcher nutzt sie nur, um den aktiven Terminal-Tab zu erkennen. Es werden keine Befehle ausgeführt.", // de
            "%@ : macOS peut appeler cette autorisation « contrôler l’app ». MacSwitcher ne l’utilise que pour repérer l’onglet actif du terminal. Aucune commande n’est exécutée.", // fr
            "%@: macOS puede llamar a este permiso «controlar la app». MacSwitcher solo lo usa para identificar la pestaña activa del terminal. No se ejecuta ningún comando.", // es
            "%@: o macOS pode chamar a esta permissão «controlar a app». O MacSwitcher usa-a apenas para identificar o separador ativo do terminal. Nenhum comando é executado.", // pt
            "%@：macOS 可能将此权限称为“控制该 App”。MacSwitcher 仅用它来识别当前终端标签页，不会运行任何命令。", // zh
            "%@：macOS ではこの許可が「アプリの制御」と表示されることがあります。MacSwitcher はアクティブなターミナルのタブを特定するためだけに使い、コマンドは実行しません。", // ja
            "%@: macOS에서 이 권한이 “앱 제어”로 표시될 수 있습니다. MacSwitcher는 활성 터미널 탭을 확인하는 데만 사용하며 명령은 실행하지 않습니다.", // ko
            "%@: macOS може назвати цей дозвіл «керуванням застосунком». MacSwitcher використовує його лише щоб визначити активну вкладку термінала. Команди не виконуються.", // uk
            "%@: macOS może nazwać to uprawnienie „kontrolowaniem aplikacji”. MacSwitcher używa go tylko do rozpoznania aktywnej karty terminala. Żadne polecenia nie są uruchamiane.", // pl
            "%@: macOS можа назваць гэты дазвол «кіраваннем праграмай». MacSwitcher выкарыстоўвае яго толькі каб вызначыць актыўную ўкладку тэрмінала. Каманды не выконваюцца.", // be
            "%@: το macOS μπορεί να ονομάζει αυτό το δικαίωμα «έλεγχος της εφαρμογής». Το MacSwitcher το χρησιμοποιεί μόνο για να εντοπίσει την ενεργή καρτέλα του τερματικού. Δεν εκτελούνται εντολές.", // el
            "%@: macOS може да нарече това разрешение „управление на приложението“. MacSwitcher го използва само за откриване на активния раздел на терминала. Команди не се изпълняват.", // bg
            "%@. macOS-ը կարող է այս թույլտվությունը կոչել «հավելվածի կառավարում»։ MacSwitcher-ը այն օգտագործում է միայն տերմինալի ակտիվ ներդիրը որոշելու համար։ Հրամաններ չեն կատարվում։", // hy
            "%@: macOS-მა ეს ნებართვა შეიძლება «აპის მართვა» უწოდოს. MacSwitcher მას მხოლოდ ტერმინალის აქტიური ჩანართის დასადგენად იყენებს. ბრძანებები არ სრულდება.", // ka
        ],
        "shell.consent.request": [
            "Request access", // en
            "Запросить доступ", // ru
            "Zugriff anfragen", // de
            "Demander l’accès", // fr
            "Solicitar acceso", // es
            "Pedir acesso", // pt
            "请求访问", // zh
            "アクセスをリクエスト", // ja
            "접근 요청", // ko
            "Запросити доступ", // uk
            "Poproś o dostęp", // pl
            "Запытаць доступ", // be
            "Αίτημα πρόσβασης", // el
            "Заявяване на достъп", // bg
            "Խնդրել հասանելիություն", // hy
            "წვდომის მოთხოვნა", // ka
        ],
        "shell.consent.granted": [
            "Selected-tab access is allowed.", // en
            "Доступ к выбранной вкладке разрешён.", // ru
            "Der Zugriff auf den gewählten Tab ist erlaubt.", // de
            "L’accès à l’onglet sélectionné est autorisé.", // fr
            "El acceso a la pestaña seleccionada está permitido.", // es
            "O acesso ao separador selecionado está permitido.", // pt
            "已允许访问所选标签页。", // zh
            "選択したタブへのアクセスが許可されました。", // ja
            "선택한 탭에 대한 접근이 허용되었습니다.", // ko
            "Доступ до вибраної вкладки дозволено.", // uk
            "Dostęp do wybranej karty jest dozwolony.", // pl
            "Доступ да выбранай ўкладкі дазволены.", // be
            "Η πρόσβαση στην επιλεγμένη καρτέλα επιτρέπεται.", // el
            "Достъпът до избрания раздел е разрешен.", // bg
            "Ընտրված ներդիրին հասանելիությունը թույլատրված է։", // hy
            "არჩეულ ჩანართზე წვდომა ნებადართულია.", // ka
        ],
        "shell.consent.denied": [
            "Access was not granted; the terminal line will remain untouched.", // en
            "Доступ пока не получен; строка терминала не будет изменяться.", // ru
            "Der Zugriff wurde nicht erteilt; die Terminalzeile bleibt unverändert.", // de
            "L’accès n’a pas été accordé ; la ligne du terminal ne sera pas modifiée.", // fr
            "No se concedió el acceso; la línea del terminal no se modificará.", // es
            "O acesso não foi concedido; a linha do terminal não será alterada.", // pt
            "尚未获得访问权限；终端中的行不会被修改。", // zh
            "アクセスは許可されていません。ターミナルの行は変更されません。", // ja
            "접근이 허용되지 않았습니다. 터미널 줄은 변경되지 않습니다.", // ko
            "Доступ ще не отримано; рядок термінала не змінюватиметься.", // uk
            "Dostęp nie został przyznany; linia terminala pozostanie nietknięta.", // pl
            "Доступ пакуль не атрыманы; радок тэрмінала не будзе змяняцца.", // be
            "Η πρόσβαση δεν δόθηκε· η γραμμή του τερματικού δεν θα τροποποιηθεί.", // el
            "Достъпът не е получен; редът на терминала няма да се променя.", // bg
            "Հասանելիությունը չի տրվել. տերմինալի տողը չի փոփոխվի։", // hy
            "წვდომა არ არის მიღებული; ტერმინალის ხაზი არ შეიცვლება.", // ka
        ],
    ]
}
