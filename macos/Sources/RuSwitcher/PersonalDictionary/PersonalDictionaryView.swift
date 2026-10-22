import AppKit
import UniformTypeIdentifiers

/// Explicit editor for private words and phrase exceptions.
@MainActor
final class PersonalDictionaryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case word(PersonalWordStore.PersonalWord)
        case phrase(PersonalWordStore.PhraseException)
    }

    private let store = PersonalWordStore.shared
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [Row] = []
    var onChanged: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: text("Личный словарь и исключения", "Personal dictionary and exceptions"))
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 447, width: 420, height: 22)
        addSubview(title)

        let hint = NSTextField(wrappingLabelWithString: text(
            "Добавляйте имена и бренды вручную. Фразы ниже сохраняются как точные исключения автокоррекции.",
            "Add names and brands explicitly. Phrases below are exact autocorrection exceptions."))
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 405, width: 420, height: 38)
        addSubview(hint)

        let kind = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kind.title = text("Тип", "Type")
        kind.width = 70
        table.addTableColumn(kind)
        let language = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        language.title = text("Язык", "Language")
        language.width = 60
        table.addTableColumn(language)
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        value.title = text("Запись", "Entry")
        value.width = 270
        table.addTableColumn(value)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 120, width: 420, height: 275))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)

        addButton(text("Добавить слово", "Add word"), #selector(addWord), x: 20, y: 83, width: 135)
        addButton(text("Добавить фразу", "Add phrase"), #selector(addPhrase), x: 162, y: 83, width: 135)
        addButton(text("Удалить", "Remove"), #selector(removeSelected), x: 304, y: 83, width: 136)
        addButton(text("Импорт", "Import"), #selector(importFile), x: 20, y: 44, width: 202)
        addButton(text("Экспорт", "Export"), #selector(exportFile), x: 230, y: 44, width: 210)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 9, width: 420, height: 29)
        addSubview(status)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addButton(_ title: String, _ action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = NSRect(x: x, y: y, width: width, height: 28)
        addSubview(button)
    }

    private func reload() {
        rows = store.words().sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }.map(Row.word)
        rows += store.phrases().sorted { $0.original.localizedCaseInsensitiveCompare($1.original) == .orderedAscending }.map(Row.phrase)
        table.reloadData()
        status.stringValue = store.readOnlyError ?? text("Локально на этом Mac", "Stored locally on this Mac")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: "")
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return field }
        switch rows[row] {
        case .word(let entry):
            field.stringValue = id == "kind" ? text("Слово", "Word") : id == "language" ? entry.language.uppercased() : entry.word
        case .phrase(let entry):
            field.stringValue = id == "kind" ? text("Фраза", "Phrase") : id == "language" ? entry.sourceLanguage.uppercased() : "\(entry.original) → \(entry.replacement)"
        }
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = field.stringValue
        return field
    }

    @objc private func addWord() {
        guard let word = prompt(title: text("Новое слово", "New word"), fields: [text("Слово", "Word")]),
              let value = word.first else { return }
        let language = chooseLanguage() ?? ""
        guard !language.isEmpty else { return }
        perform { try store.addWord(value, language: language) }
    }

    @objc private func addPhrase() {
        guard let language = chooseLanguage(),
              let values = prompt(title: text("Исключение фразы", "Phrase exception"),
                                  fields: [text("Исходная фраза", "Original phrase"), text("Исправленная фраза", "Replacement phrase")]),
              values.count == 2 else { return }
        perform { try store.addPhrase(original: values[0], replacement: values[1], sourceLanguage: language) }
    }

    @objc private func removeSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let row = rows[table.selectedRow]
        perform {
            switch row {
            case .word(let word): try store.removeWord(word.word, language: word.language)
            case .phrase(let phrase): try store.removePhrase(original: phrase.original, sourceLanguage: phrase.sourceLanguage)
            }
        }
    }

    @objc private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 1_048_576 else { throw PersonalWordStore.StoreError.tooLarge }
            let data = try Data(contentsOf: url)
            let confirmation = NSAlert()
            confirmation.messageText = text("Заменить личный словарь?", "Replace personal dictionary?")
            confirmation.informativeText = text("Импорт заменит все текущие слова и исключения.",
                                                "Import replaces all current words and exceptions.")
            confirmation.addButton(withTitle: text("Заменить", "Replace"))
            confirmation.addButton(withTitle: text("Отмена", "Cancel"))
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
            try store.importData(data)
            reload()
            onChanged?()
        } catch { showError(error) }
    }

    @objc private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacSwitcher-PersonalDictionary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { showError(error) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); reload(); onChanged?() } catch { showError(error) }
    }

    private func prompt(title: String, fields: [String]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: text("Добавить", "Add"))
        alert.addButton(withTitle: text("Отмена", "Cancel"))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        var inputs: [NSTextField] = []
        for label in fields {
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.placeholderString = label
            stack.addArrangedSubview(input)
            inputs.append(input)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(fields.count) * 32)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map(\.stringValue)
    }

    private func chooseLanguage() -> String? {
        let alert = NSAlert()
        alert.messageText = text("Язык записи", "Entry language")
        alert.addButton(withTitle: "RU")
        alert.addButton(withTitle: "EN")
        alert.addButton(withTitle: text("Отмена", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return "ru"
        case .alertSecondButtonReturn: return "en"
        default: return nil
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = text("Не удалось изменить словарь", "Could not change dictionary")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func text(_ ru: String, _ en: String) -> String { L10n.languageCode == "ru" ? ru : en }
}
