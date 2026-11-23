// Переводы на 16 языков (порядок: en, ru, de, fr, es, pt, zh, ja, ko, uk, pl, be, el, bg, hy, ka).
// Исходники после сбоя, выход, уведомления.

extension L10n {
    static let recoveryStrings: [String: [String]] = [
        "recovery.exception.saveFailed": [
            "Could not save the exception. Open the personal dictionary in Settings.", // en
            "Не удалось сохранить исключение. Откройте личный словарь в настройках.", // ru
            "Die Ausnahme konnte nicht gespeichert werden. Öffnen Sie das persönliche Wörterbuch in den Einstellungen.", // de
            "Impossible d’enregistrer l’exception. Ouvrez le dictionnaire personnel dans les réglages.", // fr
            "No se pudo guardar la excepción. Abre el diccionario personal en los ajustes.", // es
            "Não foi possível guardar a exceção. Abra o dicionário pessoal nas definições.", // pt
            "无法保存该例外。请在设置中打开个人词典。", // zh
            "例外を保存できませんでした。設定で個人辞書を開いてください。", // ja
            "예외를 저장하지 못했습니다. 설정에서 개인 사전을 여세요.", // ko
            "Не вдалося зберегти виняток. Відкрийте особистий словник у налаштуваннях.", // uk
            "Nie udało się zapisać wyjątku. Otwórz słownik osobisty w ustawieniach.", // pl
            "Не атрымалася захаваць выключэнне. Адкрыйце асабісты слоўнік у наладах.", // be
            "Δεν ήταν δυνατή η αποθήκευση της εξαίρεσης. Ανοίξτε το προσωπικό λεξικό στις Ρυθμίσεις.", // el
            "Изключението не можа да бъде запазено. Отворете личния речник в настройките.", // bg
            "Չհաջողվեց պահպանել բացառությունը։ Բացեք անձնական բառարանը կարգավորումներում։", // hy
            "გამონაკლისის შენახვა ვერ მოხერხდა. გახსენით პირადი ლექსიკონი პარამეტრებში.", // ka
        ],
        "recovery.showOriginal": [
            "Show original text", // en
            "Показать исходный текст", // ru
            "Originaltext anzeigen", // de
            "Afficher le texte original", // fr
            "Mostrar el texto original", // es
            "Mostrar o texto original", // pt
            "显示原文", // zh
            "元のテキストを表示", // ja
            "원본 텍스트 보기", // ko
            "Показати початковий текст", // uk
            "Pokaż tekst oryginalny", // pl
            "Паказаць зыходны тэкст", // be
            "Εμφάνιση αρχικού κειμένου", // el
            "Показване на оригиналния текст", // bg
            "Ցույց տալ սկզբնական տեքստը", // hy
            "საწყისი ტექსტის ჩვენება", // ka
        ],
        "recovery.memoryFull": [
            "Original-text memory is full. Save originals locally from the MacSwitcher menu to continue in other fields. Fields with unconfirmed edits stay blocked.", // en
            "Память исходных текстов заполнена. Сохраните их локально через меню MacSwitcher, чтобы продолжить в других полях. Поля с неподтверждённой правкой останутся заблокированы.", // ru
            "Der Speicher für Originaltexte ist voll. Sichern Sie die Originale lokal über das MacSwitcher-Menü, um in anderen Feldern weiterzumachen. Felder mit unbestätigten Änderungen bleiben gesperrt.", // de
            "La mémoire des textes originaux est pleine. Enregistrez-les localement depuis le menu MacSwitcher pour continuer dans d’autres champs. Les champs avec une modification non confirmée restent bloqués.", // fr
            "La memoria de textos originales está llena. Guárdalos localmente desde el menú de MacSwitcher para seguir en otros campos. Los campos con cambios sin confirmar seguirán bloqueados.", // es
            "A memória dos textos originais está cheia. Guarde-os localmente a partir do menu do MacSwitcher para continuar noutros campos. Os campos com alterações por confirmar continuam bloqueados.", // pt
            "原文内存已满。请通过 MacSwitcher 菜单将原文保存到本地，以便继续在其他文本框中使用。存在未确认修改的文本框将保持锁定。", // zh
            "元のテキスト用のメモリがいっぱいです。他のフィールドで続けるには、MacSwitcher のメニューから元のテキストをローカルに保存してください。未確認の変更があるフィールドはロックされたままになります。", // ja
            "원본 텍스트 메모리가 가득 찼습니다. 다른 필드에서 계속하려면 MacSwitcher 메뉴에서 원본을 로컬에 저장하세요. 확인되지 않은 수정이 있는 필드는 계속 잠깁니다.", // ko
            "Пам’ять початкових текстів заповнена. Збережіть їх локально через меню MacSwitcher, щоб продовжити в інших полях. Поля з непідтвердженою правкою залишаться заблокованими.", // uk
            "Pamięć tekstów oryginalnych jest pełna. Zapisz oryginały lokalnie z menu MacSwitcher, aby pracować dalej w innych polach. Pola z niepotwierdzoną zmianą pozostaną zablokowane.", // pl
            "Памяць зыходных тэкстаў запоўнена. Захавайце іх лакальна праз меню MacSwitcher, каб працягнуць у іншых палях. Палі з непацверджанай праўкай застануцца заблакіраванымі.", // be
            "Η μνήμη αρχικών κειμένων είναι γεμάτη. Αποθηκεύστε τα τοπικά από το μενού του MacSwitcher για να συνεχίσετε σε άλλα πεδία. Τα πεδία με μη επιβεβαιωμένη αλλαγή παραμένουν κλειδωμένα.", // el
            "Паметта за оригинални текстове е пълна. Запазете ги локално от менюто на MacSwitcher, за да продължите в други полета. Полетата с непотвърдена промяна остават заключени.", // bg
            "Սկզբնական տեքստերի հիշողությունը լիքն է։ Պահպանեք դրանք տեղում MacSwitcher-ի ընտրացանկից՝ այլ դաշտերում շարունակելու համար։ Չհաստատված փոփոխությամբ դաշտերը մնում են արգելափակված։", // hy
            "საწყისი ტექსტების მეხსიერება გადაივსო. შეინახეთ ისინი ლოკალურად MacSwitcher-ის მენიუდან, რომ სხვა ველებში გააგრძელოთ. ველები დაუდასტურებელი ცვლილებით დაბლოკილი დარჩება.", // ka
        ],
        "recovery.archiveLimitNotice": [
            "Saved-field limit reached. Close affected fields and restart MacSwitcher normally after checking the archives.", // en
            "Достигнут предел сохранённых полей. Закройте затронутые поля и штатно перезапустите MacSwitcher после проверки архивов.", // ru
            "Das Limit gesicherter Felder ist erreicht. Schließen Sie die betroffenen Felder und starten Sie MacSwitcher nach Prüfung der Archive normal neu.", // de
            "La limite de champs enregistrés est atteinte. Fermez les champs concernés et redémarrez normalement MacSwitcher après avoir vérifié les archives.", // fr
            "Se alcanzó el límite de campos guardados. Cierra los campos afectados y reinicia MacSwitcher normalmente tras revisar los archivos.", // es
            "O limite de campos guardados foi atingido. Feche os campos afetados e reinicie normalmente o MacSwitcher depois de verificar os arquivos.", // pt
            "已达到已保存文本框的上限。请关闭受影响的文本框，检查存档后正常重新启动 MacSwitcher。", // zh
            "保存済みフィールドの上限に達しました。該当するフィールドを閉じ、アーカイブを確認してから MacSwitcher を通常どおり再起動してください。", // ja
            "저장된 필드 한도에 도달했습니다. 해당 필드를 닫고 보관 파일을 확인한 후 MacSwitcher를 정상적으로 다시 시작하세요.", // ko
            "Досягнуто ліміту збережених полів. Закрийте відповідні поля й штатно перезапустіть MacSwitcher після перевірки архівів.", // uk
            "Osiągnięto limit zapisanych pól. Zamknij pola, których to dotyczy, i po sprawdzeniu archiwów uruchom MacSwitcher ponownie w zwykły sposób.", // pl
            "Дасягнуты ліміт захаваных палёў. Зачыніце закранутыя палі і штатна перазапусціце MacSwitcher пасля праверкі архіваў.", // be
            "Επιτεύχθηκε το όριο αποθηκευμένων πεδίων. Κλείστε τα επηρεαζόμενα πεδία και επανεκκινήστε κανονικά το MacSwitcher αφού ελέγξετε τα αρχεία.", // el
            "Достигнат е лимитът на запазените полета. Затворете засегнатите полета и рестартирайте MacSwitcher нормално след проверка на архивите.", // bg
            "Պահպանված դաշտերի սահմանաչափը լրացել է։ Փակեք համապատասխան դաշտերը և արխիվները ստուգելուց հետո սովորական կերպով վերագործարկեք MacSwitcher-ը։", // hy
            "შენახული ველების ლიმიტი ამოიწურა. დახურეთ შესაბამისი ველები და არქივების შემოწმების შემდეგ MacSwitcher ჩვეულებრივ გადატვირთეთ.", // ka
        ],
        "recovery.openOriginals": [
            "Open originals", // en
            "Открыть исходники", // ru
            "Originale öffnen", // de
            "Ouvrir les originaux", // fr
            "Abrir originales", // es
            "Abrir originais", // pt
            "打开原文", // zh
            "元のテキストを開く", // ja
            "원본 열기", // ko
            "Відкрити першоджерела", // uk
            "Otwórz oryginały", // pl
            "Адкрыць зыходнікі", // be
            "Άνοιγμα πρωτοτύπων", // el
            "Отваряне на оригиналите", // bg
            "Բացել սկզբնականները", // hy
            "საწყისების გახსნა", // ka
        ],
        "recovery.failed.title": [
            "Originals were not saved", // en
            "Исходники не сохранены", // ru
            "Originale wurden nicht gesichert", // de
            "Les originaux n’ont pas été enregistrés", // fr
            "No se guardaron los originales", // es
            "Os originais não foram guardados", // pt
            "原文未保存", // zh
            "元のテキストを保存できませんでした", // ja
            "원본이 저장되지 않았습니다", // ko
            "Першоджерела не збережено", // uk
            "Oryginały nie zostały zapisane", // pl
            "Зыходнікі не захаваны", // be
            "Τα πρωτότυπα δεν αποθηκεύτηκαν", // el
            "Оригиналите не са запазени", // bg
            "Սկզբնականները չեն պահպանվել", // hy
            "საწყისები არ შეინახა", // ka
        ],
        "recovery.failed.limit.manual": [
            "The Recovery folder reached its limit. Originals remain in memory. Check archives before deleting any; normal quit will be cancelled if saving fails.", // en
            "Папка Recovery достигла лимита. Исходники остаются в памяти. Проверьте архивы перед удалением; штатный выход отменится, если сохранить их не удастся.", // ru
            "Der Ordner „Recovery“ hat sein Limit erreicht. Die Originale bleiben im Speicher. Prüfen Sie die Archive, bevor Sie etwas löschen; das normale Beenden wird abgebrochen, wenn das Sichern fehlschlägt.", // de
            "Le dossier Recovery a atteint sa limite. Les originaux restent en mémoire. Vérifiez les archives avant d’en supprimer ; la fermeture normale sera annulée si l’enregistrement échoue.", // fr
            "La carpeta Recovery alcanzó su límite. Los originales siguen en memoria. Revisa los archivos antes de borrar alguno; la salida normal se cancelará si no se puede guardar.", // es
            "A pasta Recovery atingiu o limite. Os originais permanecem na memória. Verifique os arquivos antes de apagar algum; a saída normal será cancelada se a gravação falhar.", // pt
            "Recovery 文件夹已达上限。原文仍保留在内存中。删除任何存档前请先检查；如果保存失败，将取消正常退出。", // zh
            "Recovery フォルダが上限に達しました。元のテキストはメモリに残っています。削除する前にアーカイブを確認してください。保存できない場合、通常の終了は取り消されます。", // ja
            "Recovery 폴더가 한도에 도달했습니다. 원본은 메모리에 남아 있습니다. 삭제하기 전에 보관 파일을 확인하세요. 저장에 실패하면 일반 종료가 취소됩니다.", // ko
            "Папка Recovery досягла ліміту. Першоджерела залишаються в пам’яті. Перевірте архіви перед видаленням; штатний вихід буде скасовано, якщо зберегти їх не вдасться.", // uk
            "Folder Recovery osiągnął limit. Oryginały pozostają w pamięci. Sprawdź archiwa przed usunięciem; zwykłe zakończenie zostanie anulowane, jeśli zapis się nie powiedzie.", // pl
            "Папка Recovery дасягнула ліміту. Зыходнікі застаюцца ў памяці. Праверце архівы перад выдаленнем; штатны выхад будзе скасаваны, калі захаваць іх не атрымаецца.", // be
            "Ο φάκελος Recovery έφτασε το όριό του. Τα πρωτότυπα παραμένουν στη μνήμη. Ελέγξτε τα αρχεία πριν διαγράψετε· η κανονική έξοδος θα ακυρωθεί αν η αποθήκευση αποτύχει.", // el
            "Папката Recovery достигна лимита си. Оригиналите остават в паметта. Проверете архивите преди изтриване; нормалното излизане ще бъде отменено, ако запазването не успее.", // bg
            "Recovery պանակը հասել է սահմանաչափին։ Սկզբնականները մնում են հիշողության մեջ։ Ջնջելուց առաջ ստուգեք արխիվները. եթե պահպանումը չհաջողվի, սովորական ելքը կչեղարկվի։", // hy
            "Recovery საქაღალდემ ლიმიტს მიაღწია. საწყისები მეხსიერებაში რჩება. წაშლამდე შეამოწმეთ არქივები; თუ შენახვა ვერ მოხერხდა, ჩვეულებრივი გასვლა გაუქმდება.", // ka
        ],
        "recovery.failed.generic.manual": [
            "Originals remain in memory. Check the Recovery folder and retry from the menu. Normal quit will be cancelled if saving fails.", // en
            "Исходники остаются в памяти. Проверьте папку Recovery и повторите сохранение через меню. Штатный выход отменится, если сохранить их не удастся.", // ru
            "Die Originale bleiben im Speicher. Prüfen Sie den Ordner „Recovery“ und versuchen Sie das Sichern erneut über das Menü. Das normale Beenden wird abgebrochen, wenn das Sichern fehlschlägt.", // de
            "Les originaux restent en mémoire. Vérifiez le dossier Recovery et réessayez depuis le menu. La fermeture normale sera annulée si l’enregistrement échoue.", // fr
            "Los originales siguen en memoria. Revisa la carpeta Recovery y vuelve a intentarlo desde el menú. La salida normal se cancelará si no se puede guardar.", // es
            "Os originais permanecem na memória. Verifique a pasta Recovery e tente novamente a partir do menu. A saída normal será cancelada se a gravação falhar.", // pt
            "原文仍保留在内存中。请检查 Recovery 文件夹，并从菜单重试。如果保存失败，将取消正常退出。", // zh
            "元のテキストはメモリに残っています。Recovery フォルダを確認し、メニューからもう一度保存してください。保存できない場合、通常の終了は取り消されます。", // ja
            "원본은 메모리에 남아 있습니다. Recovery 폴더를 확인하고 메뉴에서 다시 시도하세요. 저장에 실패하면 일반 종료가 취소됩니다.", // ko
            "Першоджерела залишаються в пам’яті. Перевірте папку Recovery і повторіть збереження через меню. Штатний вихід буде скасовано, якщо зберегти їх не вдасться.", // uk
            "Oryginały pozostają w pamięci. Sprawdź folder Recovery i spróbuj ponownie z menu. Zwykłe zakończenie zostanie anulowane, jeśli zapis się nie powiedzie.", // pl
            "Зыходнікі застаюцца ў памяці. Праверце папку Recovery і паўтарыце захаванне праз меню. Штатны выхад будзе скасаваны, калі захаваць іх не атрымаецца.", // be
            "Τα πρωτότυπα παραμένουν στη μνήμη. Ελέγξτε τον φάκελο Recovery και δοκιμάστε ξανά από το μενού. Η κανονική έξοδος θα ακυρωθεί αν η αποθήκευση αποτύχει.", // el
            "Оригиналите остават в паметта. Проверете папката Recovery и опитайте отново от менюто. Нормалното излизане ще бъде отменено, ако запазването не успее.", // bg
            "Սկզբնականները մնում են հիշողության մեջ։ Ստուգեք Recovery պանակը և նորից փորձեք ընտրացանկից։ Եթե պահպանումը չհաջողվի, սովորական ելքը կչեղարկվի։", // hy
            "საწყისები მეხსიერებაში რჩება. შეამოწმეთ Recovery საქაღალდე და ხელახლა სცადეთ მენიუდან. თუ შენახვა ვერ მოხერხდა, ჩვეულებრივი გასვლა გაუქმდება.", // ka
        ],
        "recovery.failed.limit.auto": [
            "Recovery archive limit reached. Originals remain in memory. Open archives; check that files are no longer needed before deleting any.", // en
            "Папка Recovery достигла лимита. Исходники остаются в памяти. Откройте архивы; перед удалением проверьте, что они больше не нужны.", // ru
            "Das Limit des Recovery-Archivs ist erreicht. Die Originale bleiben im Speicher. Öffnen Sie die Archive und prüfen Sie vor dem Löschen, ob die Dateien nicht mehr gebraucht werden.", // de
            "La limite de l’archive Recovery est atteinte. Les originaux restent en mémoire. Ouvrez les archives ; vérifiez que les fichiers ne sont plus utiles avant d’en supprimer.", // fr
            "Se alcanzó el límite del archivo Recovery. Los originales siguen en memoria. Abre los archivos; comprueba que ya no hacen falta antes de borrar alguno.", // es
            "O limite do arquivo Recovery foi atingido. Os originais permanecem na memória. Abra os arquivos; verifique se já não são necessários antes de apagar algum.", // pt
            "Recovery 存档已达上限。原文仍保留在内存中。请打开存档；删除前先确认这些文件已不再需要。", // zh
            "Recovery アーカイブが上限に達しました。元のテキストはメモリに残っています。アーカイブを開き、不要になったことを確認してから削除してください。", // ja
            "Recovery 보관 파일이 한도에 도달했습니다. 원본은 메모리에 남아 있습니다. 보관 파일을 열고 더 이상 필요하지 않은지 확인한 후 삭제하세요.", // ko
            "Архів Recovery досяг ліміту. Першоджерела залишаються в пам’яті. Відкрийте архіви; перед видаленням переконайтеся, що вони більше не потрібні.", // uk
            "Archiwum Recovery osiągnęło limit. Oryginały pozostają w pamięci. Otwórz archiwa; przed usunięciem sprawdź, czy pliki nie są już potrzebne.", // pl
            "Архіў Recovery дасягнуў ліміту. Зыходнікі застаюцца ў памяці. Адкрыйце архівы; перад выдаленнем праверце, што яны больш не патрэбны.", // be
            "Το αρχείο Recovery έφτασε το όριό του. Τα πρωτότυπα παραμένουν στη μνήμη. Ανοίξτε τα αρχεία· πριν διαγράψετε, βεβαιωθείτε ότι δεν χρειάζονται πια.", // el
            "Архивът Recovery достигна лимита си. Оригиналите остават в паметта. Отворете архивите; преди изтриване проверете, че файловете вече не са нужни.", // bg
            "Recovery արխիվը հասել է սահմանաչափին։ Սկզբնականները մնում են հիշողության մեջ։ Բացեք արխիվները. ջնջելուց առաջ համոզվեք, որ ֆայլերն այլևս պետք չեն։", // hy
            "Recovery არქივმა ლიმიტს მიაღწია. საწყისები მეხსიერებაში რჩება. გახსენით არქივები; წაშლამდე დარწმუნდით, რომ ფაილები აღარ გჭირდებათ.", // ka
        ],
        "recovery.failed.generic.auto": [
            "Could not save originals locally. They remain in memory; retry from the menu.", // en
            "Не удалось сохранить исходники локально. Они остаются в памяти; повторите сохранение через меню.", // ru
            "Die Originale konnten nicht lokal gesichert werden. Sie bleiben im Speicher; versuchen Sie es erneut über das Menü.", // de
            "Impossible d’enregistrer les originaux localement. Ils restent en mémoire ; réessayez depuis le menu.", // fr
            "No se pudieron guardar los originales localmente. Siguen en memoria; vuelve a intentarlo desde el menú.", // es
            "Não foi possível guardar os originais localmente. Permanecem na memória; tente novamente a partir do menu.", // pt
            "无法在本地保存原文。它们仍保留在内存中；请从菜单重试。", // zh
            "元のテキストをローカルに保存できませんでした。メモリには残っています。メニューからもう一度お試しください。", // ja
            "원본을 로컬에 저장하지 못했습니다. 메모리에는 남아 있으니 메뉴에서 다시 시도하세요.", // ko
            "Не вдалося зберегти першоджерела локально. Вони залишаються в пам’яті; повторіть збереження через меню.", // uk
            "Nie udało się zapisać oryginałów lokalnie. Pozostają w pamięci; spróbuj ponownie z menu.", // pl
            "Не атрымалася захаваць зыходнікі лакальна. Яны застаюцца ў памяці; паўтарыце захаванне праз меню.", // be
            "Δεν ήταν δυνατή η τοπική αποθήκευση των πρωτοτύπων. Παραμένουν στη μνήμη· δοκιμάστε ξανά από το μενού.", // el
            "Оригиналите не можаха да бъдат запазени локално. Остават в паметта; опитайте отново от менюто.", // bg
            "Չհաջողվեց սկզբնականները պահպանել տեղում։ Դրանք մնում են հիշողության մեջ. նորից փորձեք ընտրացանկից։", // hy
            "საწყისების ლოკალურად შენახვა ვერ მოხერხდა. ისინი მეხსიერებაში რჩება; ხელახლა სცადეთ მენიუდან.", // ka
        ],
        "recovery.openRecovery": [
            "Open Recovery", // en
            "Открыть Recovery", // ru
            "Recovery öffnen", // de
            "Ouvrir Recovery", // fr
            "Abrir Recovery", // es
            "Abrir Recovery", // pt
            "打开 Recovery", // zh
            "Recovery を開く", // ja
            "Recovery 열기", // ko
            "Відкрити Recovery", // uk
            "Otwórz Recovery", // pl
            "Адкрыць Recovery", // be
            "Άνοιγμα Recovery", // el
            "Отваряне на Recovery", // bg
            "Բացել Recovery-ն", // hy
            "Recovery-ის გახსნა", // ka
        ],
        "recovery.archiveReadFailed": [
            "Could not read the archive", // en
            "Не удалось прочитать архив", // ru
            "Das Archiv konnte nicht gelesen werden", // de
            "Impossible de lire l’archive", // fr
            "No se pudo leer el archivo", // es
            "Não foi possível ler o arquivo", // pt
            "无法读取存档", // zh
            "アーカイブを読み込めませんでした", // ja
            "보관 파일을 읽지 못했습니다", // ko
            "Не вдалося прочитати архів", // uk
            "Nie udało się odczytać archiwum", // pl
            "Не атрымалася прачытаць архіў", // be
            "Δεν ήταν δυνατή η ανάγνωση του αρχείου", // el
            "Архивът не можа да бъде прочетен", // bg
            "Չհաջողվեց կարդալ արխիվը", // hy
            "არქივის წაკითხვა ვერ მოხერხდა", // ka
        ],
        "quit.wait.title": [
            "Wait for the line edit to finish", // en
            "Подождите завершения исправления строки", // ru
            "Warten Sie, bis die Zeilenkorrektur abgeschlossen ist", // de
            "Attendez la fin de la correction de la ligne", // fr
            "Espera a que termine la corrección de la línea", // es
            "Aguarde a conclusão da correção da linha", // pt
            "请等待该行修正完成", // zh
            "行の修正が完了するまでお待ちください", // ja
            "줄 수정이 끝날 때까지 기다리세요", // ko
            "Зачекайте завершення виправлення рядка", // uk
            "Poczekaj na zakończenie poprawiania linii", // pl
            "Пачакайце завяршэння выпраўлення радка", // be
            "Περιμένετε να ολοκληρωθεί η διόρθωση της γραμμής", // el
            "Изчакайте завършването на поправката на реда", // bg
            "Սպասեք տողի ուղղման ավարտին", // hy
            "დაელოდეთ ხაზის შესწორების დასრულებას", // ka
        ],
        "quit.wait.body": [
            "The original line remains in memory until the edit is verified. Quit again after verification finishes.", // en
            "Исходная строка хранится в памяти, пока результат записи не подтверждён. Повторите выход после завершения проверки.", // ru
            "Die ursprüngliche Zeile bleibt im Speicher, bis die Änderung bestätigt ist. Beenden Sie erneut, wenn die Prüfung abgeschlossen ist.", // de
            "La ligne d’origine reste en mémoire tant que la modification n’est pas vérifiée. Quittez de nouveau une fois la vérification terminée.", // fr
            "La línea original permanece en memoria hasta que se verifique el cambio. Vuelve a salir cuando termine la verificación.", // es
            "A linha original permanece na memória até a alteração ser verificada. Saia novamente quando a verificação terminar.", // pt
            "在修改得到验证之前，原始行会保留在内存中。验证完成后请再次退出。", // zh
            "変更が確認されるまで、元の行はメモリに保持されます。確認が終わってからもう一度終了してください。", // ja
            "수정이 확인될 때까지 원래 줄은 메모리에 보관됩니다. 확인이 끝난 후 다시 종료하세요.", // ko
            "Початковий рядок зберігається в пам’яті, доки результат запису не підтверджено. Повторіть вихід після завершення перевірки.", // uk
            "Oryginalna linia pozostaje w pamięci, dopóki zmiana nie zostanie zweryfikowana. Zakończ ponownie po zakończeniu weryfikacji.", // pl
            "Зыходны радок захоўваецца ў памяці, пакуль вынік запісу не пацверджаны. Паўтарыце выхад пасля завяршэння праверкі.", // be
            "Η αρχική γραμμή παραμένει στη μνήμη μέχρι να επαληθευτεί η αλλαγή. Κάντε ξανά έξοδο όταν ολοκληρωθεί η επαλήθευση.", // el
            "Първоначалният ред остава в паметта, докато промяната не бъде потвърдена. Излезте отново след приключване на проверката.", // bg
            "Սկզբնական տողը մնում է հիշողության մեջ, մինչև փոփոխությունը հաստատվի։ Ավարտվելուց հետո նորից դուրս եկեք։", // hy
            "საწყისი ხაზი მეხსიერებაში რჩება, სანამ ცვლილება არ დადასტურდება. გადამოწმების დასრულების შემდეგ გასვლა გაიმეორეთ.", // ka
        ],
        "quit.save.title": [
            "Save the original text first", // en
            "Сначала сохраните исходный текст", // ru
            "Sichern Sie zuerst den Originaltext", // de
            "Enregistrez d’abord le texte original", // fr
            "Guarda primero el texto original", // es
            "Guarde primeiro o texto original", // pt
            "请先保存原文", // zh
            "先に元のテキストを保存してください", // ja
            "먼저 원본 텍스트를 저장하세요", // ko
            "Спершу збережіть початковий текст", // uk
            "Najpierw zapisz tekst oryginalny", // pl
            "Спачатку захавайце зыходны тэкст", // be
            "Αποθηκεύστε πρώτα το αρχικό κείμενο", // el
            "Първо запазете оригиналния текст", // bg
            "Նախ պահպանեք սկզբնական տեքստը", // hy
            "ჯერ შეინახეთ საწყისი ტექსტი", // ka
        ],
        "quit.save.body": [
            "Full originals from unconfirmed edits remain in MacSwitcher memory. Before quitting, save them to a local file in Library/Application Support/MacSwitcher/Recovery. Clipboard copying is not a saved backup.", // en
            "После неподтверждённой замены полные исходные тексты остались в памяти MacSwitcher. Перед выходом их можно сохранить в локальный файл в Library/Application Support/MacSwitcher/Recovery. Обычное копирование в буфер не считается сохранением.", // ru
            "Vollständige Originaltexte unbestätigter Änderungen liegen noch im Speicher von MacSwitcher. Sichern Sie sie vor dem Beenden in einer lokalen Datei unter Library/Application Support/MacSwitcher/Recovery. Das Kopieren in die Zwischenablage ist keine Sicherung.", // de
            "Les textes originaux complets des modifications non confirmées sont encore en mémoire dans MacSwitcher. Avant de quitter, enregistrez-les dans un fichier local sous Library/Application Support/MacSwitcher/Recovery. Une copie dans le presse-papiers n’est pas une sauvegarde.", // fr
            "Los textos originales completos de los cambios sin confirmar siguen en la memoria de MacSwitcher. Antes de salir, guárdalos en un archivo local en Library/Application Support/MacSwitcher/Recovery. Copiarlos al portapapeles no es una copia guardada.", // es
            "Os textos originais completos das alterações por confirmar permanecem na memória do MacSwitcher. Antes de sair, guarde-os num ficheiro local em Library/Application Support/MacSwitcher/Recovery. Copiar para a área de transferência não é uma cópia guardada.", // pt
            "未确认修改的完整原文仍保留在 MacSwitcher 的内存中。退出前，请将其保存到 Library/Application Support/MacSwitcher/Recovery 中的本地文件。复制到剪贴板不算已保存的备份。", // zh
            "未確認の変更の元のテキスト全体が MacSwitcher のメモリに残っています。終了する前に、Library/Application Support/MacSwitcher/Recovery のローカルファイルに保存してください。クリップボードへのコピーは保存とは見なされません。", // ja
            "확인되지 않은 수정의 전체 원본 텍스트가 MacSwitcher 메모리에 남아 있습니다. 종료하기 전에 Library/Application Support/MacSwitcher/Recovery의 로컬 파일로 저장하세요. 클립보드 복사는 저장된 백업이 아닙니다.", // ko
            "Після непідтвердженої заміни повні початкові тексти залишилися в пам’яті MacSwitcher. Перед виходом їх можна зберегти в локальний файл у Library/Application Support/MacSwitcher/Recovery. Звичайне копіювання в буфер не вважається збереженням.", // uk
            "Pełne teksty oryginalne po niepotwierdzonych zmianach pozostały w pamięci MacSwitcher. Przed zakończeniem zapisz je w pliku lokalnym w Library/Application Support/MacSwitcher/Recovery. Skopiowanie do schowka nie jest zapisaną kopią.", // pl
            "Пасля непацверджанай замены поўныя зыходныя тэксты засталіся ў памяці MacSwitcher. Перад выхадам іх можна захаваць у лакальны файл у Library/Application Support/MacSwitcher/Recovery. Звычайнае капіраванне ў буфер не лічыцца захаваннем.", // be
            "Τα πλήρη αρχικά κείμενα μη επιβεβαιωμένων αλλαγών παραμένουν στη μνήμη του MacSwitcher. Πριν την έξοδο, αποθηκεύστε τα σε τοπικό αρχείο στο Library/Application Support/MacSwitcher/Recovery. Η αντιγραφή στο πρόχειρο δεν αποτελεί αποθηκευμένο αντίγραφο.", // el
            "Пълните оригинални текстове от непотвърдени промени остават в паметта на MacSwitcher. Преди излизане ги запазете в локален файл в Library/Application Support/MacSwitcher/Recovery. Копирането в клипборда не е запазено резервно копие.", // bg
            "Չհաստատված փոփոխությունների ամբողջական սկզբնական տեքստերը մնացել են MacSwitcher-ի հիշողության մեջ։ Դուրս գալուց առաջ պահպանեք դրանք Library/Application Support/MacSwitcher/Recovery-ի տեղային ֆայլում։ Clipboard-ում պատճենելը պահպանված կրկնօրինակ չէ։", // hy
            "დაუდასტურებელი ცვლილებების სრული საწყისი ტექსტები MacSwitcher-ის მეხსიერებაში დარჩა. გასვლამდე შეინახეთ ისინი ლოკალურ ფაილში: Library/Application Support/MacSwitcher/Recovery. ბუფერში კოპირება შენახულ ასლად არ ითვლება.", // ka
        ],
        "quit.save.button": [
            "Save locally and quit", // en
            "Сохранить локально и выйти", // ru
            "Lokal sichern und beenden", // de
            "Enregistrer localement et quitter", // fr
            "Guardar localmente y salir", // es
            "Guardar localmente e sair", // pt
            "保存到本地并退出", // zh
            "ローカルに保存して終了", // ja
            "로컬에 저장하고 종료", // ko
            "Зберегти локально й вийти", // uk
            "Zapisz lokalnie i zakończ", // pl
            "Захаваць лакальна і выйсці", // be
            "Τοπική αποθήκευση και έξοδος", // el
            "Запазване локално и излизане", // bg
            "Պահպանել տեղում և դուրս գալ", // hy
            "ლოკალურად შენახვა და გასვლა", // ka
        ],
        "quit.failed": [
            "Originals were not saved. Quit cancelled.", // en
            "Исходники не сохранены. Выход отменён.", // ru
            "Originale wurden nicht gesichert. Beenden abgebrochen.", // de
            "Les originaux n’ont pas été enregistrés. Fermeture annulée.", // fr
            "No se guardaron los originales. Salida cancelada.", // es
            "Os originais não foram guardados. Saída cancelada.", // pt
            "原文未保存。已取消退出。", // zh
            "元のテキストを保存できませんでした。終了を取り消しました。", // ja
            "원본이 저장되지 않았습니다. 종료가 취소되었습니다.", // ko
            "Першоджерела не збережено. Вихід скасовано.", // uk
            "Oryginały nie zostały zapisane. Zakończenie anulowane.", // pl
            "Зыходнікі не захаваны. Выхад скасаваны.", // be
            "Τα πρωτότυπα δεν αποθηκεύτηκαν. Η έξοδος ακυρώθηκε.", // el
            "Оригиналите не са запазени. Излизането е отменено.", // bg
            "Սկզբնականները չեն պահպանվել։ Ելքը չեղարկվեց։", // hy
            "საწყისები არ შეინახა. გასვლა გაუქმდა.", // ka
        ],
        "update.manual.body": [
            "In-app updates are not configured yet. Open official MacSwitcher releases to install a new version manually.", // en
            "Встроенная установка обновлений пока недоступна. Откройте официальные выпуски MacSwitcher и установите новую версию вручную.", // ru
            "Die Installation von Updates in der App ist noch nicht eingerichtet. Öffnen Sie die offiziellen MacSwitcher-Versionen, um eine neue Version manuell zu installieren.", // de
            "L’installation des mises à jour depuis l’app n’est pas encore configurée. Ouvrez les versions officielles de MacSwitcher pour installer manuellement une nouvelle version.", // fr
            "Las actualizaciones dentro de la app aún no están configuradas. Abre las versiones oficiales de MacSwitcher para instalar una nueva manualmente.", // es
            "As atualizações na própria app ainda não estão configuradas. Abra as versões oficiais do MacSwitcher para instalar uma nova versão manualmente.", // pt
            "应用内更新尚未配置。请打开 MacSwitcher 官方发布页面，手动安装新版本。", // zh
            "アプリ内アップデートはまだ設定されていません。MacSwitcher の公式リリースを開いて、新しいバージョンを手動でインストールしてください。", // ja
            "앱 내 업데이트가 아직 설정되지 않았습니다. MacSwitcher 공식 릴리스를 열어 새 버전을 직접 설치하세요.", // ko
            "Вбудоване встановлення оновлень поки недоступне. Відкрийте офіційні випуски MacSwitcher і встановіть нову версію вручну.", // uk
            "Aktualizacje w aplikacji nie są jeszcze skonfigurowane. Otwórz oficjalne wydania MacSwitcher, aby zainstalować nową wersję ręcznie.", // pl
            "Убудаванае ўсталяванне абнаўленняў пакуль недаступнае. Адкрыйце афіцыйныя выпускі MacSwitcher і ўсталюйце новую версію ўручную.", // be
            "Οι ενημερώσεις μέσα από την εφαρμογή δεν έχουν ρυθμιστεί ακόμη. Ανοίξτε τις επίσημες εκδόσεις του MacSwitcher για να εγκαταστήσετε μια νέα έκδοση χειροκίνητα.", // el
            "Актуализациите в приложението още не са настроени. Отворете официалните версии на MacSwitcher, за да инсталирате нова версия ръчно.", // bg
            "Հավելվածում թարմացումները դեռ կարգավորված չեն։ Բացեք MacSwitcher-ի պաշտոնական թողարկումները՝ նոր տարբերակը ձեռքով տեղադրելու համար։", // hy
            "აპლიკაციაში განახლებები ჯერ არ არის გამართული. გახსენით MacSwitcher-ის ოფიციალური გამოშვებები ახალი ვერსიის ხელით დასაყენებლად.", // ka
        ],
        "update.openReleases": [
            "Open Releases", // en
            "Открыть выпуски", // ru
            "Versionen öffnen", // de
            "Ouvrir les versions", // fr
            "Abrir versiones", // es
            "Abrir versões", // pt
            "打开发布页面", // zh
            "リリースを開く", // ja
            "릴리스 열기", // ko
            "Відкрити випуски", // uk
            "Otwórz wydania", // pl
            "Адкрыць выпускі", // be
            "Άνοιγμα εκδόσεων", // el
            "Отваряне на версиите", // bg
            "Բացել թողարկումները", // hy
            "გამოშვებების გახსნა", // ka
        ],
        "notice.close": [
            "Close notification", // en
            "Закрыть уведомление", // ru
            "Hinweis schließen", // de
            "Fermer la notification", // fr
            "Cerrar notificación", // es
            "Fechar notificação", // pt
            "关闭通知", // zh
            "通知を閉じる", // ja
            "알림 닫기", // ko
            "Закрити сповіщення", // uk
            "Zamknij powiadomienie", // pl
            "Закрыць апавяшчэнне", // be
            "Κλείσιμο ειδοποίησης", // el
            "Затваряне на известието", // bg
            "Փակել ծանուցումը", // hy
            "შეტყობინების დახურვა", // ka
        ],
        "toast.undo": [
            "Undo", // en
            "Отменить", // ru
            "Widerrufen", // de
            "Annuler", // fr
            "Deshacer", // es
            "Anular", // pt
            "撤销", // zh
            "取り消す", // ja
            "실행 취소", // ko
            "Скасувати", // uk
            "Cofnij", // pl
            "Адмяніць", // be
            "Αναίρεση", // el
            "Отмяна", // bg
            "Հետարկել", // hy
            "გაუქმება", // ka
        ],
        "toast.never": [
            "Never correct this phrase", // en
            "Больше не исправлять фразу", // ru
            "Diese Wendung nie korrigieren", // de
            "Ne plus corriger cette phrase", // fr
            "No corregir nunca esta frase", // es
            "Nunca corrigir esta frase", // pt
            "不再修正此短语", // zh
            "このフレーズを今後修正しない", // ja
            "이 구문은 더 이상 수정하지 않음", // ko
            "Більше не виправляти фразу", // uk
            "Nigdy nie poprawiaj tej frazy", // pl
            "Больш не выпраўляць фразу", // be
            "Να μην διορθώνεται ποτέ αυτή η φράση", // el
            "Никога не поправяй тази фраза", // bg
            "Այս արտահայտությունը այլևս չուղղել", // hy
            "ამ ფრაზას აღარასოდეს ასწორებდეს", // ka
        ],
        "feedback.retry": [
            "Text was not changed. Click the intended field, select the text, and press Shift twice again.", // en
            "Текст не изменён. Кликните в нужное поле, выделите фрагмент и повторите двойной Shift.", // ru
            "Der Text wurde nicht geändert. Klicken Sie in das gewünschte Feld, markieren Sie den Text und drücken Sie erneut zweimal Umschalt.", // de
            "Le texte n’a pas été modifié. Cliquez dans le champ voulu, sélectionnez le texte et appuyez de nouveau deux fois sur Maj.", // fr
            "El texto no se ha modificado. Haz clic en el campo deseado, selecciona el texto y vuelve a pulsar Mayús dos veces.", // es
            "O texto não foi alterado. Clique no campo pretendido, selecione o texto e prima Shift duas vezes novamente.", // pt
            "文本未更改。请点击目标文本框，选中文本，然后再次连按两次 Shift。", // zh
            "テキストは変更されませんでした。目的のフィールドをクリックし、テキストを選択して、もう一度 Shift を2回押してください。", // ja
            "텍스트가 변경되지 않았습니다. 원하는 필드를 클릭하고 텍스트를 선택한 다음 Shift를 다시 두 번 누르세요.", // ko
            "Текст не змінено. Клацніть потрібне поле, виділіть фрагмент і повторіть подвійний Shift.", // uk
            "Tekst nie został zmieniony. Kliknij właściwe pole, zaznacz tekst i ponownie naciśnij dwa razy Shift.", // pl
            "Тэкст не зменены. Пстрыкніце ў патрэбным полі, вылучыце фрагмент і паўтарыце двайны Shift.", // be
            "Το κείμενο δεν άλλαξε. Κάντε κλικ στο πεδίο που θέλετε, επιλέξτε το κείμενο και πατήστε ξανά δύο φορές Shift.", // el
            "Текстът не е променен. Щракнете в нужното поле, изберете текста и натиснете Shift два пъти отново.", // bg
            "Տեքստը չի փոխվել։ Սեղմեք ցանկալի դաշտում, ընտրեք տեքստը և նորից երկու անգամ սեղմեք Shift։", // hy
            "ტექსტი არ შეცვლილა. დააწკაპუნეთ საჭირო ველზე, მონიშნეთ ტექსტი და Shift ხელახლა ორჯერ დააჭირეთ.", // ka
        ],
        "feedback.recovery.noArchive": [
            "The edit could not be confirmed. Check the field. If another attempt there changes nothing, start typing in a different field or window.", // en
            "Результат правки не подтверждён. Проверьте поле. Если повтор в нём ничего не меняет, начните ввод в другом поле или окне.", // ru
            "Die Änderung konnte nicht bestätigt werden. Prüfen Sie das Feld. Wenn ein weiterer Versuch dort nichts ändert, tippen Sie in einem anderen Feld oder Fenster weiter.", // de
            "La modification n’a pas pu être confirmée. Vérifiez le champ. Si une nouvelle tentative n’y change rien, commencez à saisir dans un autre champ ou une autre fenêtre.", // fr
            "No se pudo confirmar el cambio. Revisa el campo. Si otro intento no cambia nada, empieza a escribir en otro campo o ventana.", // es
            "Não foi possível confirmar a alteração. Verifique o campo. Se outra tentativa não mudar nada, comece a escrever noutro campo ou janela.", // pt
            "无法确认修改结果。请检查文本框。如果再次尝试仍无变化，请在其他文本框或窗口中继续输入。", // zh
            "編集の結果を確認できませんでした。フィールドを確認してください。もう一度試しても変化がない場合は、別のフィールドまたはウインドウで入力を始めてください。", // ja
            "수정 결과를 확인할 수 없었습니다. 필드를 확인하세요. 다시 시도해도 변화가 없으면 다른 필드나 창에서 입력을 시작하세요.", // ko
            "Результат правки не підтверджено. Перевірте поле. Якщо повтор у ньому нічого не змінює, почніть введення в іншому полі або вікні.", // uk
            "Nie udało się potwierdzić zmiany. Sprawdź pole. Jeśli kolejna próba nic nie zmienia, zacznij pisać w innym polu lub oknie.", // pl
            "Вынік праўкі не пацверджаны. Праверце поле. Калі паўтор у ім нічога не мяняе, пачніце ўвод у іншым полі або акне.", // be
            "Η αλλαγή δεν μπόρεσε να επιβεβαιωθεί. Ελέγξτε το πεδίο. Αν μια νέα προσπάθεια δεν αλλάζει τίποτα, ξεκινήστε να πληκτρολογείτε σε άλλο πεδίο ή παράθυρο.", // el
            "Промяната не можа да бъде потвърдена. Проверете полето. Ако нов опит там не променя нищо, започнете да пишете в друго поле или прозорец.", // bg
            "Փոփոխությունը չհաջողվեց հաստատել։ Ստուգեք դաշտը։ Եթե կրկնակի փորձը ոչինչ չի փոխում, սկսեք մուտքագրել մեկ այլ դաշտում կամ պատուհանում։", // hy
            "ცვლილების დადასტურება ვერ მოხერხდა. შეამოწმეთ ველი. თუ განმეორებითი ცდა არაფერს ცვლის, აკრეფა სხვა ველში ან ფანჯარაში დაიწყეთ.", // ka
        ],
        "feedback.recovery.withArchive": [
            "The edit could not be confirmed. Open the original text with the button or MacSwitcher menu, then copy it. If another attempt in the same field changes nothing, start typing in a different field or window.", // en
            "Результат правки не подтверждён. Откройте исходный текст кнопкой или через меню MacSwitcher, затем скопируйте его. Если повтор в том же поле ничего не меняет, начните ввод в другом поле или окне.", // ru
            "Die Änderung konnte nicht bestätigt werden. Öffnen Sie den Originaltext über die Taste oder das MacSwitcher-Menü und kopieren Sie ihn. Wenn ein weiterer Versuch im selben Feld nichts ändert, tippen Sie in einem anderen Feld oder Fenster weiter.", // de
            "La modification n’a pas pu être confirmée. Ouvrez le texte original avec le bouton ou le menu MacSwitcher, puis copiez-le. Si une nouvelle tentative dans le même champ n’y change rien, commencez à saisir dans un autre champ ou une autre fenêtre.", // fr
            "No se pudo confirmar el cambio. Abre el texto original con el botón o el menú de MacSwitcher y cópialo. Si otro intento en el mismo campo no cambia nada, empieza a escribir en otro campo o ventana.", // es
            "Não foi possível confirmar a alteração. Abra o texto original com o botão ou o menu do MacSwitcher e copie-o. Se outra tentativa no mesmo campo não mudar nada, comece a escrever noutro campo ou janela.", // pt
            "无法确认修改结果。请通过按钮或 MacSwitcher 菜单打开原文并拷贝。如果在同一文本框中再次尝试仍无变化，请在其他文本框或窗口中继续输入。", // zh
            "編集の結果を確認できませんでした。ボタンまたは MacSwitcher のメニューから元のテキストを開き、コピーしてください。同じフィールドでもう一度試しても変化がない場合は、別のフィールドまたはウインドウで入力を始めてください。", // ja
            "수정 결과를 확인할 수 없었습니다. 버튼이나 MacSwitcher 메뉴로 원본 텍스트를 열어 복사하세요. 같은 필드에서 다시 시도해도 변화가 없으면 다른 필드나 창에서 입력을 시작하세요.", // ko
            "Результат правки не підтверджено. Відкрийте початковий текст кнопкою або через меню MacSwitcher, потім скопіюйте його. Якщо повтор у тому самому полі нічого не змінює, почніть введення в іншому полі або вікні.", // uk
            "Nie udało się potwierdzić zmiany. Otwórz tekst oryginalny przyciskiem lub z menu MacSwitcher, a potem skopiuj go. Jeśli kolejna próba w tym samym polu nic nie zmienia, zacznij pisać w innym polu lub oknie.", // pl
            "Вынік праўкі не пацверджаны. Адкрыйце зыходны тэкст кнопкай або праз меню MacSwitcher, потым скапіруйце яго. Калі паўтор у тым жа полі нічога не мяняе, пачніце ўвод у іншым полі або акне.", // be
            "Η αλλαγή δεν μπόρεσε να επιβεβαιωθεί. Ανοίξτε το αρχικό κείμενο με το κουμπί ή από το μενού του MacSwitcher και αντιγράψτε το. Αν μια νέα προσπάθεια στο ίδιο πεδίο δεν αλλάζει τίποτα, ξεκινήστε να πληκτρολογείτε σε άλλο πεδίο ή παράθυρο.", // el
            "Промяната не можа да бъде потвърдена. Отворете оригиналния текст с бутона или от менюто на MacSwitcher и го копирайте. Ако нов опит в същото поле не променя нищо, започнете да пишете в друго поле или прозорец.", // bg
            "Փոփոխությունը չհաջողվեց հաստատել։ Բացեք սկզբնական տեքստը կոճակով կամ MacSwitcher-ի ընտրացանկից և պատճենեք այն։ Եթե նույն դաշտում կրկնակի փորձը ոչինչ չի փոխում, սկսեք մուտքագրել մեկ այլ դաշտում կամ պատուհանում։", // hy
            "ცვლილების დადასტურება ვერ მოხერხდა. გახსენით საწყისი ტექსტი ღილაკით ან MacSwitcher-ის მენიუდან და დააკოპირეთ. თუ იმავე ველში განმეორებითი ცდა არაფერს ცვლის, აკრეფა სხვა ველში ან ფანჯარაში დაიწყეთ.", // ka
        ],
        "feedback.source": [
            "Text corrected. Choose the needed keyboard layout in the MacSwitcher menu.", // en
            "Текст исправлен. Выберите нужную раскладку в меню MacSwitcher.", // ru
            "Text korrigiert. Wählen Sie die gewünschte Tastaturbelegung im MacSwitcher-Menü.", // de
            "Texte corrigé. Choisissez la disposition de clavier voulue dans le menu MacSwitcher.", // fr
            "Texto corregido. Elige la distribución de teclado que necesites en el menú de MacSwitcher.", // es
            "Texto corrigido. Escolha o layout de teclado pretendido no menu do MacSwitcher.", // pt
            "文本已修正。请在 MacSwitcher 菜单中选择所需的键盘布局。", // zh
            "テキストを修正しました。MacSwitcher のメニューで必要なキーボードレイアウトを選んでください。", // ja
            "텍스트가 수정되었습니다. MacSwitcher 메뉴에서 필요한 키보드 레이아웃을 선택하세요.", // ko
            "Текст виправлено. Виберіть потрібну розкладку в меню MacSwitcher.", // uk
            "Tekst poprawiony. Wybierz potrzebny układ klawiatury w menu MacSwitcher.", // pl
            "Тэкст выпраўлены. Абярыце патрэбную раскладку ў меню MacSwitcher.", // be
            "Το κείμενο διορθώθηκε. Επιλέξτε την απαραίτητη διάταξη πληκτρολογίου από το μενού του MacSwitcher.", // el
            "Текстът е поправен. Изберете нужната подредба на клавиатурата от менюто на MacSwitcher.", // bg
            "Տեքստն ուղղվեց։ Ընտրեք անհրաժեշտ ստեղնաշարի դասավորությունը MacSwitcher-ի ընտրացանկում։", // hy
            "ტექსტი შესწორდა. აირჩიეთ საჭირო კლავიატურის განლაგება MacSwitcher-ის მენიუში.", // ka
        ],
    ]
}
