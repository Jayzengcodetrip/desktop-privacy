import AppKit

/// A small menu-bar controller. All file and layout operations belong to PrivacyService.
@MainActor
final class PrivacyAppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSOpenSavePanelDelegate {
    private let service: any PrivacyService
    private let desktopURL: URL
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var listWindow: NSWindow?
    private var listTable: NSTableView?
    private var listIntro: NSTextField?
    private var addButton: NSButton?
    private var removeButton: NSButton?
    private var listNames: [String] = []
    private var stateSymbol: NSImageView!
    private var stateTitle: NSTextField!
    private var stateDetail: NSTextField!
    private var primaryButton: NSButton!
    private var listButton: NSButton!
    private var progress: NSProgressIndicator!
    private var isBusy = false
    private var quitAfterRestore = false

    init(service: any PrivacyService, desktopURL: URL) {
        self.service = service
        self.desktopURL = desktopURL.standardizedFileURL.resolvingSymlinksInPath()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildWindow()
        refresh()
        showPanel(nil)
        performOperation(title: "正在核对隐藏名单…") { [self] in
            try service.initialize()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isBusy { return .terminateCancel }
        switch service.presentation.mode {
        case .visible, .blocked:
            return .terminateNow
        case .hidden, .recovery:
            let alert = NSAlert()
            alert.messageText = "先恢复文件，再退出？"
            alert.informativeText = "这批桌面文件仍处于隐藏或待恢复状态。继续运行可保留菜单栏的一键恢复入口。"
            alert.addButton(withTitle: "继续运行")
            alert.addButton(withTitle: "恢复并退出")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                quitAfterRestore = true
                performOperation(title: "正在恢复桌面…") { [self] in
                    try service.restore()
                }
            }
            return .terminateCancel
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel(AppConfiguration.displayName)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 450),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "桌面文件隐身"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView()
        window.contentView = content

        stateSymbol = NSImageView()
        stateSymbol.imageScaling = .scaleProportionallyUpOrDown
        stateSymbol.translatesAutoresizingMaskIntoConstraints = false
        stateSymbol.contentTintColor = .controlAccentColor

        stateTitle = label("桌面文件已显示", size: 23, weight: .semibold)
        stateTitle.alignment = .center
        stateDetail = label("正在核对隐藏名单…", size: 13, weight: .regular)
        stateDetail.alignment = .center
        stateDetail.textColor = .secondaryLabelColor
        stateDetail.maximumNumberOfLines = 5
        stateDetail.preferredMaxLayoutWidth = 380
        stateDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        primaryButton = NSButton(title: "添加桌面文件…", target: self, action: #selector(primaryAction(_:)))
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.font = .systemFont(ofSize: 15, weight: .semibold)
        primaryButton.keyEquivalent = "\r"
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        listButton = NSButton(title: "管理隐藏名单", target: self, action: #selector(showManagedList(_:)))
        listButton.bezelStyle = .rounded
        listButton.controlSize = .small

        progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false

        let tip = label("每次隐藏前记录最新位置，恢复到该次隐藏前的布局。\n单击菜单栏图标即可切换 · 右键打开更多操作", size: 11, weight: .regular)
        tip.alignment = .center
        tip.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [stateSymbol, stateTitle, stateDetail, primaryButton, listButton, tip])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(20, after: stateSymbol)
        stack.setCustomSpacing(22, after: stateDetail)
        stack.setCustomSpacing(22, after: listButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(progress)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            stateSymbol.widthAnchor.constraint(equalToConstant: 42),
            stateSymbol.heightAnchor.constraint(equalToConstant: 42),
            stateDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            primaryButton.heightAnchor.constraint(equalToConstant: 36),
            progress.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -10)
        ])
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.isSelectable = false
        return field
    }

    private func refresh() {
        let state = service.presentation
        let title: String
        let symbol: String
        let action: String
        switch state.mode {
        case .visible:
            title = state.count == 0 ? "还没有需要隐藏的文件" : "桌面文件已显示"
            symbol = "eye"
            action = state.count == 0 ? "添加桌面文件…" : "隐藏这 \(state.count) 项"
        case .hidden:
            title = "这 \(state.count) 项已隐藏"
            symbol = "eye.slash"
            action = "恢复桌面文件"
        case .recovery:
            title = "需要完成恢复"
            symbol = "arrow.counterclockwise.circle"
            action = "恢复桌面文件"
        case .blocked:
            title = "暂时无法切换"
            symbol = "exclamationmark.circle"
            action = "重新检查"
        }
        stateTitle.stringValue = title
        stateDetail.stringValue = state.mode == .visible && state.count == 0
            ? "选择需要隐藏的桌面文件或文件夹。只有加入名单的项目会被隐藏。"
            : state.detail
        stateSymbol.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        stateSymbol.contentTintColor = state.mode == .blocked || state.mode == .recovery ? .systemOrange : .controlAccentColor
        primaryButton.title = action
        primaryButton.isEnabled = !isBusy
        listButton.isEnabled = !isBusy
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "\(AppConfiguration.displayName)：\(title)\n单击切换，右键打开菜单"
        statusItem.button?.setAccessibilityLabel("\(AppConfiguration.displayName)：\(title)")
        refreshManagedList()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            primaryAction(sender)
        }
    }

    private func showStatusMenu() {
        let state = service.presentation
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled && !isBusy
            menu.addItem(entry)
        }
        item("显示控制面板", #selector(showPanel(_:)))
        menu.addItem(.separator())
        item("隐藏这 \(state.count) 项", #selector(hideAction(_:)), enabled: state.mode == .visible && state.count > 0)
        item("恢复桌面文件", #selector(restoreAction(_:)), enabled: state.mode == .hidden || state.mode == .recovery)
        item("重新检查", #selector(validateAction(_:)))
        item("管理隐藏名单", #selector(showManagedList(_:)))
        menu.addItem(.separator())
        item("退出\(AppConfiguration.displayName)", #selector(quitAction(_:)))
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
    }

    @objc private func showPanel(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func primaryAction(_ sender: Any?) {
        guard !isBusy else { return }
        switch service.presentation.mode {
        case .visible:
            if service.presentation.count == 0 { addDesktopFiles(sender) }
            else { hideAction(sender) }
        case .hidden, .recovery: restoreAction(sender)
        case .blocked: validateAction(sender)
        }
    }

    @objc private func hideAction(_ sender: Any?) {
        guard service.presentation.count > 0 else { showManagedList(sender); return }
        performOperation(title: "正在保存位置并隐藏…") { [self] in try service.hide() }
    }

    @objc private func restoreAction(_ sender: Any?) {
        performOperation(title: "正在恢复文件与位置…") { [self] in try service.restore() }
    }

    @objc private func validateAction(_ sender: Any?) {
        performOperation(title: "正在检查文件与桌面布局…") { [self] in try service.validate() }
    }

    @objc private func quitAction(_ sender: Any?) { NSApp.terminate(nil) }

    private func performOperation(title: String, action: @escaping () throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        primaryButton.isEnabled = false
        listButton.isEnabled = false
        updateListControls()
        stateDetail.stringValue = title
        progress.startAnimation(nil)
        window.contentView?.displayIfNeeded()
        DispatchQueue.main.async { [self] in
            do {
                try action()
                isBusy = false
                progress.stopAnimation(nil)
                refresh()
                if quitAfterRestore {
                    quitAfterRestore = false
                    if service.presentation.mode == .visible { NSApp.terminate(nil) }
                }
            } catch {
                quitAfterRestore = false
                isBusy = false
                progress.stopAnimation(nil)
                refresh()
                showPanel(nil)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "操作未完成"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "知道了")
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func showManagedList(_ sender: Any?) {
        if let listWindow {
            refreshManagedList()
            listWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "管理隐藏名单"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 360)
        panel.center()
        let content = NSView()
        panel.contentView = content
        let intro = label("只隐藏名单内的桌面项目。新增文件不会自动加入。", size: 13, weight: .regular)
        intro.textColor = .secondaryLabelColor
        intro.translatesAutoresizingMaskIntoConstraints = false
        listIntro = intro
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fileName"))
        column.title = "桌面文件或文件夹"
        column.width = 570
        column.minWidth = 200
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 30
        table.setAccessibilityLabel("隐藏名单，可选择多项后从名单移除")
        scroll.documentView = table
        listTable = table

        let add = NSButton(title: "添加桌面文件…", target: self, action: #selector(addDesktopFiles(_:)))
        add.bezelStyle = .rounded
        let remove = NSButton(title: "从名单移除", target: self, action: #selector(removeSelectedFiles(_:)))
        remove.bezelStyle = .rounded
        addButton = add
        removeButton = remove
        let buttons = NSStackView(views: [add, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let footer = label("可按 Command 或 Shift 多选。移除只修改名单，不会删除、移动真实文件。", size: 11, weight: .regular)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(intro)
        content.addSubview(scroll)
        content.addSubview(buttons)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        listWindow = panel
        refreshManagedList()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshManagedList() {
        guard let table = listTable else { return }
        let selectedNames = Set(table.selectedRowIndexes.compactMap { listNames.indices.contains($0) ? listNames[$0] : nil })
        let state = service.presentation
        listNames = state.names
        listWindow?.title = "管理隐藏名单 · \(state.count) 项"
        table.reloadData()
        let selection = IndexSet(listNames.indices.filter { selectedNames.contains(listNames[$0]) })
        table.selectRowIndexes(selection, byExtendingSelection: false)
        updateListControls()
    }

    private func updateListControls() {
        let state = service.presentation
        let canEdit = !isBusy && state.mode == .visible
        addButton?.isEnabled = canEdit
        removeButton?.isEnabled = canEdit && (listTable?.numberOfSelectedRows ?? 0) > 0
        switch state.mode {
        case .hidden, .recovery:
            listIntro?.stringValue = "请先恢复桌面文件，再添加或移除名单项目。当前名单仍可查看。"
        case .blocked:
            listIntro?.stringValue = "请先在控制面板完成检查，再修改名单。当前名单仍可查看。"
        case .visible:
            listIntro?.stringValue = state.count == 0
                ? "名单为空。添加需要临时隐藏的桌面文件或文件夹。"
                : "只隐藏名单内的桌面项目。新增文件不会自动加入。"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { listNames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard listNames.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("fileNameCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: 13)
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = listNames[row]
        cell.toolTip = listNames[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateListControls() }

    @objc private func addDesktopFiles(_ sender: Any?) {
        guard !isBusy, service.presentation.mode == .visible else { return }
        let panel = NSOpenPanel()
        panel.title = "添加桌面文件"
        panel.message = "请选择桌面上的文件或文件夹。只记录名单，不移动文件；子文件夹内的项目不能单独添加。"
        panel.prompt = "添加到名单"
        panel.directoryURL = desktopURL
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.delegate = self
        isBusy = true
        refresh()
        let presenter = listWindow?.isVisible == true ? listWindow! : window!
        presenter.makeKeyAndOrderFront(nil)
        panel.beginSheetModal(for: presenter) { [self] response in
            isBusy = false
            refresh()
            guard response == .OK else { return }
            // Resolve only the parent directory. Keep the selected final item
            // intact so Core can still reject a symbolic link as a target.
            let urls = panel.urls.map {
                $0.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent($0.lastPathComponent)
            }
            guard !urls.isEmpty, service.presentation.mode == .visible else { return }
            performOperation(title: "正在添加隐藏名单…") { [self] in
                try service.addTargets(urls)
            }
        }
    }

    @objc private func removeSelectedFiles(_ sender: Any?) {
        guard !isBusy, service.presentation.mode == .visible, let table = listTable else { return }
        let selected = table.selectedRowIndexes.compactMap { listNames.indices.contains($0) ? listNames[$0] : nil }
        guard !selected.isEmpty else { return }
        performOperation(title: "正在从隐藏名单移除…") { [self] in
            try service.removeTargets(named: selected)
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        let selectedParent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard url.isFileURL, selectedParent.path == desktopURL.path else {
            throw PrivacyError("请选择桌面顶层的文件或文件夹，不能添加其他位置或子文件夹内的项目。")
        }
    }
}
