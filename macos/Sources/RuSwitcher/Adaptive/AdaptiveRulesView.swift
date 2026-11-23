import AppKit

@MainActor
final class AdaptiveRulesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store = AdaptiveRuleStore.shared
    private let toggle = NSButton(checkboxWithTitle: L10n.text("adaptive.toggle"),
                                  target: nil, action: nil)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [AdaptiveRule] = []
    var onChanged: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Content spans the whole frame width: the settings column places this view.
        let width = frameRect.width
        toggle.title = L10n.text("adaptive.toggle")
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.frame = NSRect(x: 0, y: 435, width: width, height: 28)
        addSubview(toggle)
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("adaptive.explain"))
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 0, y: 367, width: width, height: 62)
        addSubview(explanation)
        for (name, title, width) in [("pair", "RU / EN", max(265.0, Double(width) - 170)),
                                     ("preferred", L10n.text("adaptive.col.choice"), 80.0),
                                     ("count", L10n.text("adaptive.col.cases"), 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 80, width: width, height: 280))
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)
        let half = (width - 10) / 2
        let delete = NSButton(title: L10n.text("adaptive.delete"), target: self, action: #selector(deleteSelected))
        delete.frame = NSRect(x: 0, y: 43, width: half, height: 28); addSubview(delete)
        let reset = NSButton(title: L10n.text("adaptive.reset"), target: self, action: #selector(resetRules))
        reset.frame = NSRect(x: half + 10, y: 43, width: half, height: 28); addSubview(reset)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 0, y: 10, width: width, height: 27); addSubview(status)
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
            L10n.text("adaptive.status", rows.filter { $0.confirmations == 1 }.count,
                rows.filter { $0.confirmations == 2 }.count)
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
        catch { status.stringValue = store.readOnlyError ?? L10n.text("adaptive.saveFailed"); return }
        reload()
    }

    @objc private func resetRules() {
        let alert = NSAlert()
        alert.messageText = L10n.text("adaptive.reset.title")
        alert.informativeText = L10n.text("adaptive.reset.body")
        alert.addButton(withTitle: L10n.text("adaptive.reset.confirm"))
        alert.addButton(withTitle: L10n.commonCancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.reset(); onChanged?() }
        catch { status.stringValue = store.readOnlyError ?? L10n.text("adaptive.saveFailed"); return }
        reload()
    }
}
