import AppKit

final class WorkspaceController:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    let window:NSWindow
    let store:WorkspaceStore
    private let coordinator:WorkspaceCoordinator
    private let projects = NSPopUpButton(frame:.zero,pullsDown:false)
    private let keywords = NSTextField()
    private let automatic = NSButton(checkboxWithTitle:"自动记录匹配页面",target:nil,action:nil)
    private let modes = NSSegmentedControl(labels:["当前页面","项目已保存","清理候选"],trackingMode:.selectOne,target:nil,action:nil)
    private let days = NSPopUpButton(frame:.zero,pullsDown:false),rule = NSPopUpButton(frame:.zero,pullsDown:false)
    private let cleanupOptions = NSStackView()
    private let table = NSTableView(),scroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString:"")
    private let saveButton = NSButton(title:"保存所选",target:nil,action:nil)
    private let closeButton = NSButton(title:"归档并关闭所选",target:nil,action:nil)
    private let restoreButton = NSButton(title:"恢复项目",target:nil,action:nil)
    private let applyButton = NSButton(title:"保存规则",target:nil,action:nil)
    private let newButton = NSButton(title:"新建项目",target:nil,action:nil)
    private let deleteButton = NSButton(title:"删除项目",target:nil,action:nil)
    private var tabs:[BrowserTab] = []
    private struct Row:Equatable { var key:String;var tab:BrowserTab;var savedID:String? }
    private var rows:[Row] = [],checked = Set<String>()
    private var currentProjectID:String?
    private var feedback:String?
    private var paintedMinute:Int = 0
    private func showStatus(_ text:String) { feedback = text;status.stringValue = text }
    var onRefresh:(()->Void)?
    var onChanged:(()->Void)?
    var isBusy:Bool { coordinator.busy }
    var projectID:String? { currentProjectID }
    init(store:WorkspaceStore,adapter:BrowserAdapter) {
        self.store = store;coordinator = WorkspaceCoordinator(store:store,adapter:adapter)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:560),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title = "BrowserPet · 项目工作集与清理";window.isReleasedWhenClosed = false
        window.minSize = NSSize(width:680,height:480)
        let root = NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false;window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-14)])
        func line(_ views:[NSView]) -> NSStackView {
            let row = NSStackView(views:views);row.orientation = .horizontal;row.spacing = 8;row.alignment = .centerY
            root.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true;return row
        }
        let refresh = NSButton(image:NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"刷新当前页面")!,target:self,action:#selector(refreshTapped))
        _ = line([NSTextField(labelWithString:"项目"),projects,newButton,deleteButton,NSView(),refresh])
        projects.widthAnchor.constraint(equalToConstant:240).isActive = true
        projects.target = self;projects.action = #selector(projectChanged)
        newButton.target = self;newButton.action = #selector(newProject)
        deleteButton.target = self;deleteButton.action = #selector(deleteProject)
        keywords.placeholderString = "自动收纳关键词，如 diffusion, FLUX, ObjectClear（任一匹配）"
        keywords.setAccessibilityLabel("项目自动收纳关键词")
        applyButton.target = self;applyButton.action = #selector(applyRules)
        _ = line([keywords,automatic,applyButton])
        modes.selectedSegment = 0;modes.target = self;modes.action = #selector(modeChanged)
        _ = line([modes,NSView(),NSTextField(labelWithString:"仅在本机保存链接资料")])
        days.addItems(withTitles:["3 天","7 天","14 天"]);rule.addItems(withTitles:["未使用","与当前项目无关","未使用且与项目无关"])
        days.target = self;days.action = #selector(filterChanged);rule.target = self;rule.action = #selector(filterChanged)
        cleanupOptions.orientation = .horizontal;cleanupOptions.spacing = 8
        for view in [NSTextField(labelWithString:"候选条件"),rule,days] { cleanupOptions.addArrangedSubview(view) }
        root.addArrangedSubview(cleanupOptions)
        for (id,title,width) in [("check","",32.0),("title","页面",340.0),("source","浏览器 / 原分组",170.0),("time","最近观测使用",145.0)] {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title = title;column.width = width
            column.minWidth = id == "check" ? 32 : 70
            column.resizingMask = id == "title" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.delegate = self;table.dataSource = self;table.rowHeight = 30;table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle;table.selectionHighlightStyle = .none
        table.setAccessibilityLabel("工作集页面，勾选后保存或归档关闭")
        scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true
        root.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:160).isActive = true
        let all = NSButton(title:"全选",target:self,action:#selector(selectAll)),none = NSButton(title:"取消选择",target:self,action:#selector(selectNone))
        _ = line([all,none,NSView(),saveButton,closeButton,restoreButton])
        saveButton.target = self;saveButton.action = #selector(saveTapped)
        closeButton.target = self;closeButton.action = #selector(closeTapped)
        restoreButton.target = self;restoreButton.action = #selector(restoreTapped)
        status.font = .systemFont(ofSize:11);status.textColor = .secondaryLabelColor;status.maximumNumberOfLines = 4
        root.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        let note = NSTextField(wrappingLabelWithString:"关闭前先保存标题、网址、分组和使用时间；不会保存正文、表单或登录状态。\n恢复会重新打开链接；原窗口不在时新建普通窗口，Chrome/Edge 不保证原配置文件，原标签组只作为资料保留。")
        note.font = .systemFont(ofSize:10.5);note.textColor = .secondaryLabelColor
        root.addArrangedSubview(note);note.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        refreshProjects();reload()
    }
    func show() { refreshProjects();reload();window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);onRefresh?() }
    func update(_ tabs:[BrowserTab],foregroundBrowser:String?) {
        self.tabs = tabs
        do { try store.observe(tabs,foregroundBrowser:foregroundBrowser) }
        catch { showStatus(error.localizedDescription) }
        if window.isVisible && !isBusy { reload() }
    }
    func markUsed(_ tab:BrowserTab) {
        var active = tab;active.isActive = true
        do { try store.observe([active],foregroundBrowser:active.browser) } catch { showStatus(error.localizedDescription) }
    }
    private var project:PageProject? { store.projects.first { $0.id == currentProjectID } }
    private func refreshProjects() {
        // Commit an old field editor before loading the selected project's saved rule.
        window.makeFirstResponder(nil)
        let values = store.projects
        if !values.contains(where:{ $0.id == currentProjectID }) { currentProjectID = values.first?.id }
        projects.removeAllItems();projects.addItems(withTitles:values.isEmpty ? ["请新建项目，如 Diffusion 研究"] : values.map(\.name))
        projects.isEnabled = !values.isEmpty && !isBusy
        if let index = values.firstIndex(where:{ $0.id == currentProjectID }) { projects.selectItem(at:index) }
        keywords.stringValue = project?.keywords.joined(separator:", ") ?? "";automatic.state = project?.automatic == true ? .on : .off
    }
    private func reload() {
        cleanupOptions.isHidden = modes.selectedSegment != 2;days.isHidden = rule.indexOfSelectedItem == 1
        let oldChecked = checked,oldRows = rows
        switch modes.selectedSegment {
        case 1:rows = (project?.pages ?? []).map { Row(key:$0.id,tab:$0.tab,savedID:$0.id) }
        case 2:
            let cutoff = [3,7,14][max(0,days.indexOfSelectedItem)]
            rows = store.candidates(tabs,days:cutoff,rule:CleanupRule(rawValue:rule.indexOfSelectedItem) ?? .unused,projectID:currentProjectID).map { Row(key:$0.id,tab:$0,savedID:nil) }
        default:rows = tabs.filter(WorkspaceStore.canSave).map { Row(key:$0.id,tab:$0,savedID:nil) }
        }
        rows.sort { $0.tab.displayTitle.localizedStandardCompare($1.tab.displayTitle) == .orderedAscending }
        checked = oldChecked.intersection(rows.map(\.key))
        if oldRows.map(\.key) != rows.map(\.key) { table.reloadData() }
        else {
            let changed = IndexSet(rows.indices.filter { rows[$0] != oldRows[$0] })
            if !changed.isEmpty { table.reloadData(forRowIndexes:changed,columnIndexes:IndexSet(integersIn:0..<table.numberOfColumns)) }
            let minute = Int(Date().timeIntervalSince1970/60)
            if minute != paintedMinute { table.reloadData(forRowIndexes:IndexSet(integersIn:0..<rows.count),columnIndexes:IndexSet(integer:3));paintedMinute = minute }
        }
        updateControls()
    }
    private func updateControls() {
        let available = project != nil && !isBusy
        for button in [saveButton,closeButton,restoreButton,applyButton,deleteButton] { button.isEnabled = available }
        modes.isEnabled = !isBusy;newButton.isEnabled = !isBusy;projects.isEnabled = !store.projects.isEmpty && !isBusy
        days.isEnabled = !isBusy;rule.isEnabled = !isBusy
        saveButton.title = modes.selectedSegment == 1 ? "移除所选记录" : "保存所选"
        saveButton.isEnabled = available && !checked.isEmpty
        closeButton.isHidden = modes.selectedSegment == 1;closeButton.isEnabled = available && !checked.isEmpty
        let savedSelection = modes.selectedSegment == 1 ? checked.count : 0
        let count = savedSelection > 0 ? savedSelection : (project?.pages.count ?? 0)
        restoreButton.title = savedSelection > 0 ? "恢复所选（\(count)）" : "恢复项目（\(count)）";restoreButton.isEnabled = available && count > 0
        let visible = table.rows(in:scroll.documentVisibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<min(table.numberOfRows,NSMaxRange(visible)) {
                (table.view(atColumn:0,row:row,makeIfNecessary:false) as? NSButton)?.isEnabled = !isBusy
            }
        }
        status.stringValue = feedback ?? ("\(rows.count) 页 · 已选 \(checked.count) 页。"+(modes.selectedSegment == 2 ? "候选排除当前页及已知固定页；只统计运行期间观测的使用，Chrome/Edge 无法可靠识别固定标签，请检查勾选。" : "创建项目后每 15 秒观察普通页面；自动收纳按关键词匹配，不读取正文。"))
    }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        guard rows.indices.contains(row),let column else { return nil };let item = rows[row]
        if column.identifier.rawValue == "check" {
            let button = NSButton(checkboxWithTitle:"",target:self,action:#selector(toggleChecked(_:)));button.tag = row
            button.state = checked.contains(item.key) ? .on : .off;button.isEnabled = !isBusy
            button.setAccessibilityLabel("选择 "+item.tab.displayTitle);return button
        }
        let label = NSTextField(labelWithString:"");label.lineBreakMode = .byTruncatingTail;label.font = .systemFont(ofSize:12)
        switch column.identifier.rawValue {
        case "title":label.stringValue = item.tab.displayTitle;label.toolTip = item.tab.displayTitle+"\n"+item.tab.url
        case "source":label.stringValue = item.tab.browserName+" · "+(item.tab.nativeGroup?.title ?? SearchEngine.purpose(item.tab).title)
        default:
            let usage = store.usage(for:item.tab)
            let date = item.savedID.flatMap { id in project?.pages.first { $0.id == id }?.lastUsed } ?? usage?.lastUsed
            if let date { label.stringValue = DateFormatter.localizedString(from:date,dateStyle:.short,timeStyle:.short) }
            else if let first = usage?.firstSeen { label.stringValue = "首次观察 "+DateFormatter.localizedString(from:first,dateStyle:.short,timeStyle:.none) }
            else { label.stringValue = "尚无使用记录" }
        }
        return label
    }
    @objc private func toggleChecked(_ sender:NSButton) {
        guard !isBusy,rows.indices.contains(sender.tag) else { return }
        feedback = nil;let id = rows[sender.tag].key;if !checked.insert(id).inserted { checked.remove(id) };updateControls()
    }
    @objc private func selectAll() { guard !isBusy else { return };checked = Set(rows.map(\.key));table.reloadData();updateControls() }
    @objc private func selectNone() { guard !isBusy else { return };checked.removeAll();table.reloadData();updateControls() }
    @objc private func modeChanged() { feedback = nil;checked.removeAll();reload() }
    @objc private func filterChanged() { feedback = nil;checked.removeAll();reload() }
    @objc private func refreshTapped() { onRefresh?() }
    @objc private func projectChanged() { guard store.projects.indices.contains(projects.indexOfSelectedItem) else { return };currentProjectID = store.projects[projects.indexOfSelectedItem].id;checked.removeAll();refreshProjects();reload() }
    @objc private func newProject() {
        let alert = NSAlert();alert.messageText = "新建项目工作集";alert.informativeText = "例如 Diffusion 研究。关键词可稍后设置，自动记录默认关闭。资料仅保存在本机。"
        let name = NSTextField(frame:NSRect(x:0,y:0,width:340,height:24));name.placeholderString = "项目名称"
        alert.accessoryView = name;alert.addButton(withTitle:"创建");alert.addButton(withTitle:"取消");alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { currentProjectID = try store.create(name:name.stringValue);refreshProjects();reload();onChanged?();onRefresh?() }
        catch { showStatus(error.localizedDescription) }
    }
    @objc private func applyRules() {
        guard let id = currentProjectID else { return }
        let values = keywords.stringValue.components(separatedBy:CharacterSet(charactersIn:",，;；\n")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if automatic.state == .on && values.isEmpty { showStatus("请先填写关键词，再开启自动记录，避免将所有网页收纳进项目。");return }
        do { try store.configure(id:id,keywords:values,automatic:automatic.state == .on);onChanged?();onRefresh?();showStatus("项目规则已保存，匹配标题、网址或原组名的任意关键词。") }
        catch { showStatus(error.localizedDescription) }
    }
    @objc private func deleteProject() {
        guard let value = project else { return }
        let alert = NSAlert();alert.messageText = "删除项目“\(value.name)”？";alert.informativeText = "移除本机保存的 \(value.pages.count) 条链接记录，不会关闭浏览器页面。";alert.addButton(withTitle:"删除项目");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.removeProject(id:value.id);refreshProjects();reload();onChanged?() } catch { showStatus(error.localizedDescription) }
    }
    @objc private func saveTapped() {
        guard let id = currentProjectID else { return }
        do {
            if modes.selectedSegment == 1 { try store.removePages(projectID:id,ids:checked) }
            else { try store.save(rows.filter { checked.contains($0.key) }.map(\.tab),projectID:id) }
            checked.removeAll();reload();onChanged?()
        } catch { showStatus(error.localizedDescription) }
    }
    @objc private func closeTapped() {
        guard let id = currentProjectID,!isBusy else { return }
        let selected = rows.filter { checked.contains($0.key) }.map(\.tab)
        guard !selected.isEmpty else { return }
        showStatus("正在保存整批链接，随后关闭所选页面…")
        coordinator.archiveAndClose(selected,projectID:id) { [weak self] result in
            guard let self else { return };self.checked.removeAll();self.reload()
            switch result { case let .success(value):self.showStatus(value.summary);case let .failure(error):self.showStatus(error.localizedDescription) }
            self.onChanged?();self.onRefresh?()
        }
        updateControls();table.reloadData()
    }
    @objc private func restoreTapped() {
        guard let value = project,!isBusy else { return }
        let selected = modes.selectedSegment == 1 && !checked.isEmpty ? value.pages.filter { checked.contains($0.id) } : value.pages
        showStatus("正在检查已打开页面并恢复项目…")
        coordinator.restore(selected) { [weak self] result in
            guard let self else { return };self.reload();self.showStatus(result.summary);self.onRefresh?()
        }
        updateControls();table.reloadData()
    }
}
