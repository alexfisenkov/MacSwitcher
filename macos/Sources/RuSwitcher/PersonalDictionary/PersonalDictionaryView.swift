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
        // Content spans the whole frame width: the settings column places this view.
        let width = frameRect.width
        let title = NSTextField(labelWithString: L10n.text("dict.title"))
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 0, y: 447, width: width, height: 22)
        addSubview(title)

        let hint = NSTextField(wrappingLabelWithString: L10n.text("dict.hint"))
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 405, width: width, height: 38)
        addSubview(hint)

        let kind = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kind.title = L10n.text("dict.col.type")
        kind.width = 70
        table.addTableColumn(kind)
        let language = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        language.title = L10n.text("dict.col.language")
        language.width = 60
        table.addTableColumn(language)
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        value.title = L10n.text("dict.col.entry")
        value.width = max(270, width - 150)
        table.addTableColumn(value)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 120, width: width, height: 275))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)

        let third = (width - 16) / 3, half = (width - 8) / 2
        addButton(L10n.text("dict.addWord"), #selector(addWord), x: 0, y: 83, width: third)
        addButton(L10n.text("dict.addPhrase"), #selector(addPhrase), x: third + 8, y: 83, width: third)
        addButton(L10n.text("dict.remove"), #selector(removeSelected), x: 2 * (third + 8), y: 83, width: third)
        addButton(L10n.text("dict.import"), #selector(importFile), x: 0, y: 44, width: half)
        addButton(L10n.text("dict.export"), #selector(exportFile), x: half + 8, y: 44, width: half)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 0, y: 9, width: width, height: 29)
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
        status.stringValue = store.readOnlyError ?? L10n.text("dict.status")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: "")
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return field }
        switch rows[row] {
        case .word(let entry):
            field.stringValue = id == "kind" ? L10n.text("dict.word") : id == "language" ? entry.language.uppercased() : entry.word
        case .phrase(let entry):
            field.stringValue = id == "kind" ? L10n.text("dict.phrase") : id == "language" ? entry.sourceLanguage.uppercased() : "\(entry.original) → \(entry.replacement)"
        }
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = field.stringValue
        return field
    }

    @objc private func addWord() {
        guard let word = prompt(title: L10n.text("dict.newWord"), fields: [L10n.text("dict.word")]),
              let value = word.first else { return }
        let language = chooseLanguage() ?? ""
        guard !language.isEmpty else { return }
        perform { try store.addWord(value, language: language) }
    }

    @objc private func addPhrase() {
        guard let language = chooseLanguage(),
              let values = prompt(title: L10n.text("dict.phraseException"),
                                  fields: [L10n.text("dict.originalPhrase"), L10n.text("dict.replacementPhrase")]),
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
            confirmation.messageText = L10n.text("dict.replace.title")
            confirmation.informativeText = L10n.text("dict.replace.body")
            confirmation.addButton(withTitle: L10n.text("dict.replace.confirm"))
            confirmation.addButton(withTitle: L10n.commonCancel)
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
        alert.addButton(withTitle: L10n.text("dict.add"))
        alert.addButton(withTitle: L10n.commonCancel)
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
        alert.messageText = L10n.text("dict.entryLanguage")
        alert.addButton(withTitle: "RU")
        alert.addButton(withTitle: "EN")
        alert.addButton(withTitle: L10n.commonCancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return "ru"
        case .alertSecondButtonReturn: return "en"
        default: return nil
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.text("dict.error")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

}
