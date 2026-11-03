import AppKit

@MainActor
final class AdaptiveRulesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store = AdaptiveRuleStore.shared
    private let toggle = NSButton(checkboxWithTitle: "Запоминать мои исправления на этом компьютере",
                                  target: nil, action: nil)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [AdaptiveRule] = []
    var onChanged: (() -> Void)?
    private func text(_ ru: String, _ en: String) -> String { L10n.languageCode == "ru" ? ru : en }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toggle.title = text("Запоминать мои исправления на этом компьютере",
            "Remember my corrections on this computer")
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.frame = NSRect(x: 20, y: 435, width: 420, height: 28)
        addSubview(toggle)
        let explanation = NSTextField(wrappingLabelWithString: text(
            "После двух независимых исправлений одного слова MacSwitcher запомнит выбор только на этом Mac. История набора и текст полей не сохраняются. Можно отключить, удалить правило или очистить список.",
            "After two separate corrections of a word, MacSwitcher remembers the choice only on this Mac. Typed history and field text are not saved. You can turn this off or delete rules."))
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 20, y: 367, width: 420, height: 62)
        addSubview(explanation)
        for (name, title, width) in [("pair", "RU / EN", 265.0),
                                     ("preferred", text("Выбор", "Choice"), 80.0),
                                     ("count", text("Случаи", "Cases"), 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = false
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 80, width: 420, height: 280))
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)
        let delete = NSButton(title: text("Удалить выбранное", "Delete selected"), target: self, action: #selector(deleteSelected))
        delete.frame = NSRect(x: 20, y: 43, width: 195, height: 28); addSubview(delete)
        let reset = NSButton(title: text("Очистить все правила…", "Clear all rules…"), target: self, action: #selector(resetRules))
        reset.frame = NSRect(x: 225, y: 43, width: 215, height: 28); addSubview(reset)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 10, width: 420, height: 27); addSubview(status)
        NotificationCenter.default.addObserver(self, selector: #selector(ruleStoreChanged),
            name: AdaptiveRuleStore.didChange, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func ruleStoreChanged() { reload() }

    private func reload() {
        toggle.state = SettingsManager.shared.adaptiveLearningEnabled ? .on : .off
        rows = store.allRules().sorted { $0.confirmedAt > $1.confirmedAt }
        table.reloadData()
        status.stringValue = store.readOnlyError ??
            "\(text("Кандидатов", "Candidates")): \(rows.filter { $0.confirmations == 1 }.count) · \(text("Активных", "Active")): \(rows.filter { $0.confirmations == 2 }.count)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: "")
        guard rows.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return field }
        let rule = rows[row]
        switch key {
        case "pair": field.stringValue = "\(rule.pair.ru) / \(rule.pair.en)"
        case "preferred": field.stringValue = rule.preferred.uppercased()
        default: field.stringValue = "\(rule.confirmations)/2"
        }
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    @objc private func toggleChanged() {
        let enabled = toggle.state == .on
        SettingsManager.shared.adaptiveLearningEnabled = enabled
        store.setEnabled(enabled)
        onChanged?(); reload()
    }

    @objc private func deleteSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        do { try store.delete(rows[table.selectedRow].pair); onChanged?() }
        catch { status.stringValue = store.readOnlyError ?? text("Не удалось сохранить изменение", "Could not save the change"); return }
        reload()
    }

    @objc private func resetRules() {
        let alert = NSAlert()
        alert.messageText = text("Очистить все выученные правила?", "Clear all learned rules?")
        alert.informativeText = text("Ручной словарь останется без изменений.", "The manual dictionary will remain unchanged.")
        alert.addButton(withTitle: text("Очистить", "Clear"))
        alert.addButton(withTitle: text("Отмена", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.reset(); onChanged?() }
        catch { status.stringValue = store.readOnlyError ?? text("Не удалось сохранить изменение", "Could not save the change"); return }
        reload()
    }
}
