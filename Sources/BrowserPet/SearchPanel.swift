import AppKit

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private enum SearchRow {
    case header(TabGroup), tab(BrowserTab)
    var key:String {
        switch self { case let .header(group):return "group:"+group.key;case let .tab(tab):return "tab:"+tab.id }
    }
    func rendersSame(as other:SearchRow) -> Bool {
        switch (self,other) {
        case let (.header(a),.header(b)):
            return a.key == b.key && a.domain == b.domain && a.tabs.count == b.tabs.count && a.color == b.color && a.collapsed == b.collapsed && a.isNative == b.isNative
        case let (.tab(a),.tab(b)):
            return a.id == b.id && a.displayTitle == b.displayTitle && SearchEngine.site(a) == SearchEngine.site(b) && a.windowNumber == b.windowNumber && a.isActive == b.isActive
        default:return false
        }
    }
}

private final class TabCell: NSTableCellView {
    private let titleLabel = HoverTitleView(frame:.zero)
    private let detailLabel = NSTextField(labelWithString:"")
    private let siteLabel = NSTextField(labelWithString:"")
    private let windowLabel = NSTextField(labelWithString:"")
    override init(frame: NSRect) {
        super.init(frame:frame)
        identifier = NSUserInterfaceItemIdentifier("tab")
        detailLabel.font = .systemFont(ofSize:10); detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        windowLabel.font = .systemFont(ofSize:10); windowLabel.textColor = .secondaryLabelColor
        windowLabel.alignment = .right
        siteLabel.font = .systemFont(ofSize:10,weight:.semibold); siteLabel.alignment = .center
        siteLabel.wantsLayer = true; siteLabel.layer?.cornerRadius = 5
        for view in [siteLabel,titleLabel,detailLabel,windowLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            siteLabel.leadingAnchor.constraint(equalTo:leadingAnchor,constant:6),
            siteLabel.centerYAnchor.constraint(equalTo:centerYAnchor),
            siteLabel.widthAnchor.constraint(equalToConstant:20),siteLabel.heightAnchor.constraint(equalToConstant:20),
            titleLabel.leadingAnchor.constraint(equalTo:siteLabel.trailingAnchor,constant:8),
            titleLabel.centerYAnchor.constraint(equalTo:centerYAnchor),titleLabel.heightAnchor.constraint(equalToConstant:22),
            titleLabel.trailingAnchor.constraint(equalTo:detailLabel.leadingAnchor,constant:-10),
            detailLabel.centerYAnchor.constraint(equalTo:centerYAnchor),
            detailLabel.widthAnchor.constraint(equalToConstant:100),
            detailLabel.trailingAnchor.constraint(equalTo:windowLabel.leadingAnchor,constant:-8),
            windowLabel.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),
            windowLabel.centerYAnchor.constraint(equalTo:centerYAnchor),
            windowLabel.widthAnchor.constraint(equalToConstant:78)
        ])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func title(atWindowPoint point:NSPoint) -> HoverTitleView? {
        titleLabel.visibleRect.contains(titleLabel.convert(point,from:nil)) ? titleLabel : nil
    }
    func show(_ tab:BrowserTab,mode:GroupingMode) {
        titleLabel.show(tab.displayTitle)
        detailLabel.stringValue = SearchEngine.site(tab)
        windowLabel.stringValue = "\(tab.isActive ? "● " : "")\(tab.browserName) \(tab.windowNumber)"
        siteLabel.stringValue = String(tab.browserName.first ?? "↗").uppercased()
        let tint:NSColor = tab.browser == "edge" ? .systemTeal : tab.browser == "safari" ? .systemIndigo : .controlAccentColor
        siteLabel.textColor = tint;siteLabel.toolTip = tab.browserName
        siteLabel.layer?.backgroundColor = tint.withAlphaComponent(0.09).cgColor
        updateContext(tab); toolTip = nil
    }
    func updateContext(_ tab:BrowserTab) {
        if detailLabel.toolTip != tab.url { detailLabel.toolTip = tab.url }
        let source = "\(tab.browserName) · \(tab.sourceLabel)"
        if windowLabel.toolTip != source { windowLabel.toolTip = source }
        setAccessibilityLabel("\(tab.displayTitle)，\(tab.browserName)，\(tab.domain)，窗口 \(tab.windowNumber)\(tab.isActive ? "，当前页面" : "")")
    }
}

final class SearchController: NSObject,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
    static let preferredSize = NSSize(width:560,height:430)
    let panel: SearchPanel
    let searchField = NSSearchField()
    private let table:NSTableView
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString:"")
    private let grouping = NSSegmentedControl(labels:GroupingMode.allCases.map(\.label),trackingMode:.selectOne,target:nil,action:nil)
    private let bridgeButton = NSButton(title:"连接原分组",target:nil,action:nil)
    private let safariButton = NSButton(title:"Safari 连接",target:nil,action:nil)
    private let browserFilter = NSPopUpButton(frame:.zero,pullsDown:false)
    private let messageBox = NSStackView(), messageLabel = NSTextField(wrappingLabelWithString:"")
    private let retryButton = NSButton(title:"重新检测",target:nil,action:nil)
    private let permissionButton = NSButton(title:"授权说明",target:nil,action:nil)
    private let emptyLabel = NSTextField(labelWithString:"")
    private var rows: [SearchRow] = [], allTabs: [BrowserTab] = []
    private var currentWindowID: String?
    private var nativeGroups: [String:NativeTabGroup] = [:]
    private var bridgeConnected = false
    private var collapseOverrides: [String:Bool] = [:]
    private var keyMonitor: Any?
    private var hoverTimer: Timer?
    private weak var hoveredTitle: HoverTitleView?
    private struct MessageState:Equatable { var text:String?;var permission:Bool;var retry:Bool;var error:Bool }
    private var messageState:MessageState?
    private var mode: GroupingMode { GroupingMode(rawValue:grouping.selectedSegment) ?? .automatic }
    var onActivate: ((BrowserTab)->Void)?
    var onClose: (()->Void)?
    var onRefresh: (()->Void)?
    var onPermissionHelp: (()->Void)?
    var onGroupSetup: (()->Void)?
    var onSafariSetup: (()->Void)?
    var onCaretChanged: ((NSPoint?)->Void)?

    init(isDemo:Bool,table:NSTableView = NSTableView()) {
        self.table = table
        panel = SearchPanel(contentRect:NSRect(origin:.zero,size:Self.preferredSize),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        panel.title = "BrowserPet 搜索"; panel.identifier = NSUserInterfaceItemIdentifier("BrowserPetSearch")
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.state = .active; effect.blendingMode = .behindWindow
        effect.wantsLayer = true; effect.layer?.cornerRadius = 14; effect.layer?.masksToBounds = true
        panel.contentView = effect
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:effect.leadingAnchor,constant:12),stack.trailingAnchor.constraint(equalTo:effect.trailingAnchor,constant:-12),
            stack.topAnchor.constraint(equalTo:effect.topAnchor,constant:12),stack.bottomAnchor.constraint(equalTo:effect.bottomAnchor,constant:-10)
        ])
        let searchRow = NSStackView(); searchRow.orientation = .horizontal; searchRow.alignment = .centerY; searchRow.spacing = 6
        searchField.placeholderString = isDemo ? "搜索示例页面…" : "搜索已打开的页面…"
        searchField.controlSize = .regular; searchField.font = .systemFont(ofSize:14); searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true; searchField.sendsWholeSearchString = false; searchField.delegate = self
        searchField.setAccessibilityLabel("搜索 Chrome、Safari 和 Edge 已打开的页面")
        let refresh = NSButton(image:NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"刷新页面列表")!,target:self,action:#selector(refreshPressed))
        refresh.isBordered = false; refresh.toolTip = "刷新页面列表"
        searchRow.addArrangedSubview(searchField); searchRow.addArrangedSubview(refresh)
        stack.addArrangedSubview(searchRow); searchRow.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        searchField.heightAnchor.constraint(equalToConstant:32).isActive = true
        refresh.widthAnchor.constraint(equalToConstant:24).isActive = true
        let modeRow = NSStackView(); modeRow.orientation = .horizontal; modeRow.alignment = .centerY; modeRow.spacing = 8
        grouping.controlSize = .small
        grouping.selectedSegment = GroupingMode(rawValue:UserDefaults.standard.integer(forKey:"grouping.mode"))?.rawValue ?? 0
        grouping.target = self; grouping.action = #selector(groupingChanged)
        grouping.toolTip = "原组优先：沿用已同步的 Chrome 标签组，其他页面按本地用途规则归类。网站和窗口是可选视图。"
        summary.font = .systemFont(ofSize:10.5); summary.textColor = .secondaryLabelColor
        bridgeButton.isBordered = false; bridgeButton.font = .systemFont(ofSize:10.5)
        bridgeButton.contentTintColor = .secondaryLabelColor; bridgeButton.target = self; bridgeButton.action = #selector(groupSetupPressed)
        safariButton.isBordered = false;safariButton.font = .systemFont(ofSize:10.5)
        safariButton.target = self;safariButton.action = #selector(safariSetupPressed)
        safariButton.toolTip = "Safari 通过本机助手读取普通窗口并切回原标签页。"
        browserFilter.addItems(withTitles:["全部浏览器"]+BrowserKind.allCases.map(\.name))
        browserFilter.controlSize = .small;browserFilter.font = .systemFont(ofSize:10.5)
        browserFilter.target = self;browserFilter.action = #selector(browserFilterChanged)
        browserFilter.setAccessibilityLabel("筛选浏览器")
        browserFilter.widthAnchor.constraint(equalToConstant:90).isActive = true
        modeRow.spacing = 5
        modeRow.addArrangedSubview(browserFilter);modeRow.addArrangedSubview(grouping); modeRow.addArrangedSubview(NSView())
        modeRow.addArrangedSubview(summary); modeRow.addArrangedSubview(bridgeButton);modeRow.addArrangedSubview(safariButton)
        stack.addArrangedSubview(modeRow); modeRow.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        messageBox.orientation = .horizontal; messageBox.alignment = .centerY; messageBox.spacing = 6
        messageLabel.font = .systemFont(ofSize:11); messageLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        retryButton.target = self; retryButton.action = #selector(refreshPressed); retryButton.bezelStyle = .rounded
        permissionButton.target = self; permissionButton.action = #selector(permissionPressed); permissionButton.bezelStyle = .rounded
        messageBox.addArrangedSubview(messageLabel); messageBox.addArrangedSubview(permissionButton); messageBox.addArrangedSubview(retryButton)
        stack.addArrangedSubview(messageBox); messageBox.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true; messageBox.isHidden = true
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("page")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.action = #selector(clicked)
        table.backgroundColor = .clear; table.focusRingType = .none
        table.selectionHighlightStyle = .regular; table.allowsEmptySelection = true; table.intercellSpacing = NSSize(width:0,height:1)
        table.setAccessibilityLabel("所有浏览器的页面搜索结果，优先原有分组")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autohidesScrollers = true
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:130).isActive = true
        emptyLabel.textColor = .secondaryLabelColor; emptyLabel.font = .systemFont(ofSize:12); emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(emptyLabel)
        NSLayoutConstraint.activate([emptyLabel.centerXAnchor.constraint(equalTo:scroll.centerXAnchor),emptyLabel.centerYAnchor.constraint(equalTo:scroll.centerYAnchor)])
        let help = NSTextField(labelWithString:"↑↓ 选择    ↩ 切换    Esc 收起")
        help.font = .systemFont(ofSize:10.5); help.textColor = .secondaryLabelColor; help.alignment = .right
        stack.addArrangedSubview(help); help.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,self.panel.isVisible,event.window === self.panel else { return event }
            if let editor = self.panel.firstResponder as? NSTextView,editor.hasMarkedText() { return event }
            switch event.keyCode {
            case 125: self.moveSelection(1); return nil
            case 126: self.moveSelection(-1); return nil
            case 36,76: self.activateSelected(); return nil
            case 53: self.onClose?(); return nil
            default: DispatchQueue.main.async { self.updateCaret() }; return event
            }
        }
        rebuild()
    }
    deinit { hoverTimer?.invalidate(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    var query: String { searchField.stringValue }
    var hasIndexedTabs:Bool { !allTabs.isEmpty }
    var selectedTab: BrowserTab? {
        guard rows.indices.contains(table.selectedRow),case let .tab(tab) = rows[table.selectedRow] else { return nil }; return tab
    }
    func setNativeGroups(_ groups:[String:NativeTabGroup],connected:Bool) {
        guard nativeGroups != groups || bridgeConnected != connected else { return }
        nativeGroups = groups; bridgeConnected = connected; rebuild(preservingViewport:true)
    }
    func setSafariConnected(_ connected:Bool) {
        let title = connected ? "Safari 已连接" : "Safari 连接"
        if safariButton.title != title { safariButton.title = title }
    }
    func setTabs(_ tabs:[BrowserTab],currentWindowID:String?,excludedCount:Int = 0) {
        let canonical = tabs.sorted { $0.id < $1.id }
        guard allTabs != canonical || self.currentWindowID != currentWindowID else { return }
        allTabs = canonical; self.currentWindowID = currentWindowID; rebuild(preservingViewport:true)
        summary.toolTip = "隐私窗口排除；Chrome、Safari、Edge 索引仅存于本机内存。"
    }
    private func rebuild(preservingViewport:Bool = false) {
        let selectedID = selectedTab?.id
        let oldRows = rows,oldOrigin = scroll.contentView.bounds.origin
        let topRow = table.row(at:NSPoint(x:0,y:oldOrigin.y))
        let anchor = oldRows.indices.contains(topRow) ? oldRows[topRow].key : nil
        let anchorOffset = oldRows.indices.contains(topRow) ? oldOrigin.y-table.rect(ofRow:topRow).minY : 0
        let filter = browserFilter.indexOfSelectedItem
        let scoped = filter == 0 ? allTabs : allTabs.filter { $0.browser == BrowserKind.allCases[filter-1].rawValue }
        let tabs = scoped.map { value -> BrowserTab in var tab = value; tab.nativeGroup = nativeGroups[tab.id] ?? value.nativeGroup; return tab }
        let groups = SearchEngine.groups(tabs:tabs,query:query,currentWindowID:currentWindowID,mode:mode)
        let searching = !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        rows = groups.flatMap { group in
            let hidden = !searching && (collapseOverrides[group.key] ?? group.collapsed)
            var header = group;header.collapsed = hidden
            return [.header(header)] + (hidden ? [] : group.tabs.map(SearchRow.tab))
        }
        let sameStructure = oldRows.map(\.key) == rows.map(\.key)
        if sameStructure {
            let changed = IndexSet(rows.indices.filter { !rows[$0].rendersSame(as:oldRows[$0]) })
            if !changed.isEmpty { table.reloadData(forRowIndexes:changed,columnIndexes:IndexSet(integer:0)) }
            for index in rows.indices where !changed.contains(index) {
                if case let .tab(tab) = rows[index],case let .tab(old) = oldRows[index],tab != old {
                    (table.view(atColumn:0,row:index,makeIfNecessary:false) as? TabCell)?.updateContext(tab)
                }
            }
        } else {
            table.reloadData()
            let index = anchor.flatMap { key in rows.firstIndex { $0.key == key } }
            let y = preservingViewport ? (index.map { table.rect(ofRow:$0).minY+anchorOffset } ?? oldOrigin.y) : 0
            scroll.contentView.scroll(to:NSPoint(x:preservingViewport ? oldOrigin.x : 0,y:max(0,min(y,table.bounds.height-scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let preferred = selectedID.flatMap { id in rows.firstIndex { if case let .tab(tab) = $0 { return tab.id == id }; return false } }
        let first = rows.firstIndex { if case .tab = $0 { return true }; return false }
        if let index = preferred ?? first {
            if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        } else if table.selectedRow != -1 { table.deselectAll(nil) }
        let count = "\(groups.reduce(0) { $0+$1.tabs.count }) 页 · \(groups.count) 组"
        if summary.stringValue != count { summary.stringValue = count }
        emptyLabel.stringValue = query.isEmpty ? "暂无普通窗口中的页面" : "没有匹配页面，试试标题或网址"
        emptyLabel.isHidden = !groups.isEmpty
        bridgeButton.isHidden = mode != .automatic || (filter != 0 && BrowserKind.allCases[filter-1] != .chrome)
        bridgeButton.title = bridgeConnected ? "Chrome 原组 ✓" : "Chrome 原组"
        bridgeButton.toolTip = bridgeConnected ? "仅已连接分组助手的 Chrome 配置文件会同步原分组。其他页面按用途分类。" : "Chrome 原分组尚未连接，当前仅按用途分类。点击查看连接步骤。"
        updateCaret()
    }
    func showMessage(_ text:String?,permission:Bool = false,retry:Bool = true,isError:Bool = false) {
        let state = MessageState(text:text,permission:permission,retry:retry,error:isError)
        guard messageState != state else { return };messageState = state
        messageBox.isHidden = text == nil; messageLabel.stringValue = text ?? ""
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        permissionButton.isHidden = !permission; retryButton.isHidden = !retry
    }
    func focus() {
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); panel.makeFirstResponder(searchField)
        if hoverTimer == nil {
            // Reconcile stationary pointers after table reuse, scrolling and floating-panel focus changes.
            let timer = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in self?.updateHover() }
            hoverTimer = timer; RunLoop.main.add(timer,forMode:.common)
        }
        if let editor = searchField.currentEditor() as? NSTextView { editor.setSelectedRange(NSRange(location:(query as NSString).length,length:0)) }
        updateCaret()
    }
    func suspendHover() {
        hoverTimer?.invalidate(); hoverTimer = nil
        hoveredTitle?.setHovered(false); hoveredTitle = nil
    }
    private func updateHover() {
        guard panel.isVisible else { suspendHover(); return }
        let point = panel.convertPoint(fromScreen:NSEvent.mouseLocation)
        let row = table.row(at:table.convert(point,from:nil))
        let cell = row >= 0 ? table.view(atColumn:0,row:row,makeIfNecessary:false) as? TabCell : nil
        let title = cell?.title(atWindowPoint:point)
        if hoveredTitle !== title {
            hoveredTitle?.setHovered(false); hoveredTitle = title
        }
        title?.setHovered(true)
    }
    func updateCaret() {
        guard panel.isVisible,let editor = searchField.currentEditor() as? NSTextView else { onCaretChanged?(nil); return }
        let rect = editor.firstRect(forCharacterRange:NSRange(location:editor.selectedRange().location,length:0),actualRange:nil)
        onCaretChanged?(NSPoint(x:rect.midX,y:rect.midY))
    }
    func controlTextDidChange(_ obj:Notification) { rebuild() }
    func controlTextDidBeginEditing(_ obj:Notification) { updateCaret() }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,heightOfRow row:Int) -> CGFloat { if case .header = rows[row] { return 22 }; return 30 }
    func tableView(_ tableView:NSTableView,shouldSelectRow row:Int) -> Bool { if case .tab = rows[row] { return true }; return false }
    private func color(_ name:String?) -> NSColor {
        switch name { case "blue":return .systemBlue; case "red":return .systemRed; case "yellow":return .systemYellow; case "green":return .systemGreen; case "pink":return .systemPink; case "purple":return .systemPurple; case "cyan":return .systemTeal; case "orange":return .systemOrange; default:return .secondaryLabelColor }
    }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        switch rows[row] {
        case let .header(group):
            let identifier = NSUserInterfaceItemIdentifier("group")
            let button = (tableView.makeView(withIdentifier:identifier,owner:self) as? NSButton) ?? NSButton()
            button.identifier = identifier; button.isBordered = false; button.alignment = .left
            button.font = .systemFont(ofSize:11,weight:.semibold); button.contentTintColor = color(group.color)
            let collapsed = query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && (collapseOverrides[group.key] ?? group.collapsed)
            button.title = "\(collapsed ? "▸" : "▾") \(group.isNative ? "● " : "")\(group.domain)  ·  \(group.tabs.count)"
            button.tag = row; button.target = self; button.action = #selector(toggleGroup(_:))
            button.toolTip = "\(group.domain)\(group.isNative ? " · Chrome 原分组" : "")；仅折叠本面板，不改变浏览器标签组。"
            button.setAccessibilityLabel("\(group.domain)，\(group.tabs.count) 个页面，\(collapsed ? "已折叠，点击展开" : "已展开，点击折叠")")
            return button
        case let .tab(tab):
            let cell = (tableView.makeView(withIdentifier:NSUserInterfaceItemIdentifier("tab"),owner:self) as? TabCell) ?? TabCell(frame:.zero)
            cell.show(tab,mode:mode); return cell
        }
    }
    func moveSelection(_ direction:Int) {
        guard !rows.isEmpty else { return }; var index = table.selectedRow
        if index < 0 { index = direction > 0 ? -1 : rows.count }
        repeat { index += direction } while rows.indices.contains(index) && !tableView(table,shouldSelectRow:index)
        if rows.indices.contains(index) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false); table.scrollRowToVisible(index) }
    }
    private func activateSelected() { if let selectedTab { onActivate?(selectedTab) } }
    @objc private func clicked() { if rows.indices.contains(table.clickedRow),case .tab = rows[table.clickedRow] { activateSelected() } }
    @objc private func toggleGroup(_ sender:NSButton) { guard rows.indices.contains(sender.tag),case let .header(group) = rows[sender.tag] else { return }; collapseOverrides[group.key] = !(collapseOverrides[group.key] ?? group.collapsed); rebuild(preservingViewport:true) }
    @objc private func groupingChanged() { UserDefaults.standard.set(grouping.selectedSegment,forKey:"grouping.mode"); rebuild() }
    @objc private func refreshPressed() { onRefresh?() }
    @objc private func permissionPressed() { onPermissionHelp?() }
    @objc private func groupSetupPressed() { onGroupSetup?() }
    @objc private func safariSetupPressed() { onSafariSetup?() }
    @objc private func browserFilterChanged() { rebuild() }
}
