import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var petPanel: PetPanel!
    private var petView: PetView!
    private var search: SearchController!
    private var settings: SettingsController!
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private let isDemo = CommandLine.arguments.contains("--demo")
    private var adapter: BrowserAdapter!
    private var refreshTimer: Timer?
    private var loadingHint: DispatchWorkItem?
    private var outsideMonitor: Any?
    private var localClickMonitor: Any?
    private var previousApplication: NSRunningApplication?
    private var scanning = false
    private var switching = false
    private var pendingActivation: BrowserTab?
    private var autoRefresh = true
    private var generation = 0
    private var windowNumbers: [String:Int] = [:]
    private var nextWindowNumber: [String:Int] = [:]
    private var initialHotkeyError: OSStatus = noErr
    private let groupBridge = GroupBridgeServer()
    private var groupRepository = NativeGroupRepository()
    private let safariAdapter = SafariAdapter()
    private var safariLoopback:SafariLoopback?
    private var safariObserver:NSObjectProtocol?
    private var workspaces:WorkspaceController?
    private var workspaceError:Error?
    private var activityTimer:Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        adapter = isDemo ? DemoAdapter() : MultiBrowserAdapter(safari:safariAdapter)
        if !isDemo,let pairing = SafariPairing.load() {
            safariLoopback = SafariLoopback(pairing:pairing,adapter:safariAdapter)
            if safariLoopback?.start() != true { safariAdapter.transportError = "本机连接端口被占用，Safari 助手暂不可用。Chrome 和 Edge 仍可使用。" }
        }
        safariObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didTerminateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == BrowserKind.safari.bundleID { self?.safariAdapter.clear() }
        }
        setupPet()
        search = SearchController(isDemo: isDemo)
        search.onClose = { [weak self] in self?.closeSearch(restoreFocus: true) }
        search.onRefresh = { [weak self] in self?.refresh(manual: true) }
        search.onActivate = { [weak self] tab in self?.activate(tab) }
        search.onCaretChanged = { [weak self] point in self?.petView.gazePoint = point }
        search.onPermissionHelp = { [weak self] in self?.permissionHelp() }
        search.onGroupSetup = { [weak self] in self?.groupSetup() }
        search.onSafariSetup = { [weak self] in self?.safariSetup() }
        search.onWorkspaces = { [weak self] in self?.showWorkspaces() }
        groupBridge.onMessage = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                do { try self.groupRepository.apply(message); self.updateNativeGroups() } catch { }
            }
        }
        groupBridge.start()
        settings = SettingsController()
        settings.onPetVisibility = { [weak self] visible in self?.setPetVisible(visible) }
        settings.onShortcut = { [weak self] shortcut in self?.hotKey.register(shortcut) ?? OSStatus(-1) }
        settings.onHelp = { [weak self] in self?.permissionHelp() }
        hotKey.onPressed = { [weak self] in self?.toggleSearch() }
        initialHotkeyError = hotKey.register(.saved())
        setupStatusItem()
        if !isDemo { setupWorkspaces() }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown]) { [weak self] event in
            guard let self, self.search.panel.isVisible else { return event }
            if event.window !== self.search.panel && event.window !== self.petPanel { self.closeSearch(restoreFocus: false) }
            return event
        }
        NotificationCenter.default.addObserver(self,selector: #selector(screensChanged),name: NSApplication.didChangeScreenParametersNotification,object: nil)
        if isDemo || CommandLine.arguments.contains("--search") { DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { self.openSearch() } }
    }

    private func setupPet() {
        petPanel = PetPanel(contentRect: NSRect(x: 0,y: 0,width: 108,height: 116),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        petPanel.title = "BrowserPet 桌宠"; petPanel.identifier = NSUserInterfaceItemIdentifier("BrowserPetPet")
        petPanel.isOpaque = false; petPanel.backgroundColor = .clear; petPanel.hasShadow = false
        petPanel.level = .floating; petPanel.isFloatingPanel = true; petPanel.hidesOnDeactivate = false
        petPanel.canHide = false; petPanel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        petPanel.isReleasedWhenClosed = false
        petView = PetView(frame: NSRect(origin: .zero,size: petPanel.frame.size)); petPanel.contentView = petView
        petView.onClick = { [weak self] in self?.toggleSearch() }
        petView.onDragStart = { [weak self] in self?.closeSearch(restoreFocus: false) }
        petView.onDragEnd = { [weak self] in self?.savePetPosition() }
        petView.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pet.x") != nil {
            petPanel.setFrameOrigin(NSPoint(x: defaults.double(forKey: "pet.x"),y: defaults.double(forKey: "pet.y")))
        } else if let screen = NSScreen.main {
            petPanel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX-132,y: screen.visibleFrame.minY+22))
        }
        clampPetPosition()
        if defaults.object(forKey: "pet.visible") == nil || defaults.bool(forKey: "pet.visible") { petPanel.orderFrontRegardless() }
        petView.visibilityChanged()
    }
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill",accessibilityDescription: "BrowserPet")
        statusItem.button?.toolTip = "BrowserPet · 搜索 Chrome、Safari、Edge 已打开的页面"
        statusItem.menu = makeMenu()
    }
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String,_ action: Selector) {
            let item = NSMenuItem(title: title,action: action,keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        add(isDemo ? "搜索页面（演示）" : "搜索页面",#selector(searchPressed))
        add("项目工作集与清理…",#selector(showWorkspaces))
        let shortcut = NSMenuItem(title: initialHotkeyError == noErr ? "快捷键：\((hotKey.current ?? .saved()).label)" : "快捷键注册失败，请在设置中更换",action: nil,keyEquivalent: "")
        shortcut.isEnabled = false; menu.addItem(shortcut)
        add(petPanel.isVisible ? "隐藏桌宠" : "显示桌宠",#selector(togglePet))
        menu.addItem(.separator()); add("设置…",#selector(showSettings)); add("浏览器授权与连接…",#selector(helpPressed))
        menu.addItem(.separator()); add("退出 BrowserPet",#selector(quit))
        menu.delegate = self
        return menu
    }
    @objc private func searchPressed() { openSearch() }
    @objc private func togglePet() { setPetVisible(!petPanel.isVisible) }
    private func setPetVisible(_ visible: Bool) {
        if visible { clampPetPosition(); petPanel.orderFrontRegardless() } else { petPanel.orderOut(nil) }
        petView.visibilityChanged()
        UserDefaults.standard.set(visible,forKey: "pet.visible")
    }
    @objc private func showSettings() {
        closeSearch(restoreFocus: false)
        settings.show(petVisible: petPanel.isVisible,shortcut: hotKey.current ?? .saved())
    }
    @objc private func helpPressed() { permissionHelp() }
    private func setupWorkspaces() {
        do {
            let controller = WorkspaceController(store:try WorkspaceStore(),adapter:adapter)
            controller.onRefresh = { [weak self] in self?.refresh(manual:true,background:true) }
            controller.onChanged = { [weak self] in self?.configureActivityTracking() }
            workspaces = controller;configureActivityTracking()
        } catch { workspaceError = error }
    }
    private func configureActivityTracking() {
        guard let workspaces,!workspaces.store.projects.isEmpty else { activityTimer?.invalidate();activityTimer = nil;return }
        if activityTimer == nil {
            let timer = Timer(timeInterval:15,repeats:true) { [weak self] _ in self?.refresh(manual:false,background:true) }
            RunLoop.main.add(timer,forMode:.common);activityTimer = timer
        }
    }
    @objc private func showWorkspaces() {
        closeSearch(restoreFocus:false)
        if let workspaces { workspaces.show() }
        else { showSetupError(workspaceError?.localizedDescription ?? "演示模式不记录真实工作集，请从正常模式打开。") }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func toggleSearch() {
        if search.panel.isVisible { closeSearch(restoreFocus: true) } else { openSearch() }
    }
    private func openSearch() {
        if !search.panel.isVisible { previousApplication = NSWorkspace.shared.frontmostApplication }
        if let browser = BrowserKind.allCases.first(where:{ $0.bundleID == previousApplication?.bundleIdentifier }) {
            (adapter as? MultiBrowserAdapter)?.preferredBrowser = browser
        }
        positionSearch()
        petView.interactionActive = true
        search.focus()
        outsideMonitor = outsideMonitor ?? NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closeSearch(restoreFocus: false) }
        }
        refresh(manual: true)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh(manual: false) }
    }
    private func closeSearch(restoreFocus: Bool) {
        guard search != nil else { return }
        search.suspendHover();search.panel.orderOut(nil);petView.gazePoint = nil;petView.interactionActive = false
        pendingActivation = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        loadingHint?.cancel(); loadingHint = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if restoreFocus, let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate(options: [])
        }
        self.previousApplication = nil
    }
    private func positionSearch() {
        let anchor = petPanel.isVisible ? petPanel.frame : NSRect(origin: NSEvent.mouseLocation,size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX,y: anchor.midY)) } ?? NSScreen.main
        guard let screen else { return }
        let usable = screen.visibleFrame.insetBy(dx: 12,dy: 12)
        var size = NSSize(width: min(SearchController.preferredSize.width,usable.width),height: min(SearchController.preferredSize.height,usable.height))
        size.height = max(300,size.height)
        var x = anchor.maxX-size.width, y = anchor.maxY+8
        if y+size.height > usable.maxY { y = max(usable.minY,anchor.minY-size.height-8) }
        x = min(max(x,usable.minX),usable.maxX-size.width)
        y = min(max(y,usable.minY),usable.maxY-size.height)
        search.panel.setFrame(NSRect(x: x,y: y,width: size.width,height: size.height),display: true)
    }
    private func refresh(manual: Bool,background:Bool = false) {
        updateNativeGroups()
        guard search.panel.isVisible || background, !scanning, !switching,workspaces?.isBusy != true, manual || autoRefresh || background else { return }
        if let browser = BrowserKind.allCases.first(where:{ $0.bundleID == NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
            (adapter as? MultiBrowserAdapter)?.preferredBrowser = browser
        }
        if manual { (adapter as? MultiBrowserAdapter)?.retryPermissions();autoRefresh = true; search.showMessage(nil); petView.baseState = .idle }
        scanning = true; generation += 1
        let token = generation
        let hint = DispatchWorkItem { [weak self] in
            guard let self, self.scanning, self.generation == token, self.search.panel.isVisible else { return }
            self.petView.baseState = .running
            // Background polling must not insert/remove an arranged view above the list.
            if manual && !self.search.hasIndexedTabs { self.search.showMessage("正在更新页面列表…",retry:false) }
        }
        loadingHint = hint; DispatchQueue.main.asyncAfter(deadline: .now()+0.35,execute: hint)
        adapter.scan { [weak self] result in
            guard let self else { return }
            self.scanning = false; self.loadingHint?.cancel(); self.loadingHint = nil
            guard self.generation == token else { return }
            switch result {
            case var .success(snapshot):
                for index in snapshot.tabs.indices {
                    let id = snapshot.tabs[index].windowKey,browser = snapshot.tabs[index].browser
                    if self.windowNumbers[id] == nil {
                        let next = self.nextWindowNumber[browser] ?? 1
                        self.windowNumbers[id] = next;self.nextWindowNumber[browser] = next+1
                    }
                    snapshot.tabs[index].windowNumber = self.windowNumbers[id]!
                }
                let native = self.groupRepository.snapshot().tabs
                for index in snapshot.tabs.indices { snapshot.tabs[index].nativeGroup = native[snapshot.tabs[index].id] ?? snapshot.tabs[index].nativeGroup }
                let foreground = BrowserKind.allCases.first { $0.bundleID == NSWorkspace.shared.frontmostApplication?.bundleIdentifier }?.rawValue
                self.workspaces?.update(snapshot.tabs,foregroundBrowser:foreground)
                self.search.setTabs(snapshot.tabs,currentWindowID: snapshot.currentWindowID,excludedCount: snapshot.excludedPrivateWindowCount)
                let notices = snapshot.notices ?? []
                self.search.setSafariConnected(!notices.contains { $0.browser == "safari" })
                self.petView.baseState = notices.contains(where: { $0.permission }) ? .waiting : .idle
                if !notices.isEmpty {
                    self.search.showMessage(notices.map(\.message).joined(separator:"\n"),permission:notices.contains { $0.permission })
                } else if snapshot.skippedWindowCount > 0 {
                    self.search.showMessage("部分页面在刷新时发生变化，列表可能不完整。可重新检测。")
                } else { self.search.showMessage(nil) }
                if let pending = self.pendingActivation, self.search.panel.isVisible {
                    self.pendingActivation = nil; self.activate(pending)
                }
            case let .failure(error):
                self.pendingActivation = nil
                self.autoRefresh = false
                if error.kind == .permission || error.kind == .notRunning || error.kind == .notInstalled {
                    self.search.setTabs([],currentWindowID: nil)
                }
                self.petView.baseState = error.kind == .permission ? .waiting : .failed
                self.search.showMessage(error.message,permission: error.kind == .permission,isError: error.kind != .permission)
            }
        }
    }
    private func activate(_ tab: BrowserTab) {
        guard !switching else { return }
        if scanning {
            pendingActivation = tab
            search.showMessage("正在完成刷新，随后切回所选页面…",retry: false); return
        }
        switching = true; petView.baseState = .running
        search.showMessage("正在切回原页面…",retry: false)
        adapter.activate(tab) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.workspaces?.markUsed(tab)
                let target = BrowserKind(rawValue:tab.browser)?.bundleID
                if tab.browser == "safari",let target {
                    NSRunningApplication.runningApplications(withBundleIdentifier:target).first?.activate(options:[])
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
                self.switching = false
                let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target
                if foreground {
                    self.petView.baseState = .idle; self.closeSearch(restoreFocus: false)
                } else {
                    self.autoRefresh = false
                    self.petView.baseState = .failed
                    self.search.showMessage("已在 \(tab.browserName) 中选中页面，但尚未切到前台。请检查所在桌面或重试。",isError: true)
                    self.search.focus()
                }
                }
            case let .failure(error):
                self.switching = false
                self.autoRefresh = false
                self.petView.baseState = error.kind == .permission ? .waiting : .failed
                self.search.showMessage(error.message,permission: error.kind == .permission,isError: error.kind != .permission)
                self.search.focus()
            }
        }
    }
    private func permissionHelp() {
        let alert = NSAlert()
        alert.messageText = "连接 Chrome、Safari 和 Edge"
        alert.informativeText = "Chrome 和 Edge：在系统设置 → 隐私与安全性 → 自动化中，允许 BrowserPet 控制对应浏览器，然后重新检测。未安装或未运行的浏览器不会被自动启动；单个浏览器拒绝授权不影响其他来源。\n\nSafari：使用面板的“Safari 连接”加载配套助手。Safari 脚本缺少可靠的隐私标记和稳定标签 ID，因此不使用下标或同名页面猜测。\n\n仅处理普通窗口的标题、网址和定位 ID，不读取网页正文。Chrome、Edge 无需打开“允许 Apple Events 执行 JavaScript”。"
        alert.addButton(withTitle: "打开系统设置"); alert.addButton(withTitle: "知道了")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }
    private func safariSetup() {
        let alert = NSAlert()
        alert.messageText = "连接 Safari 页面助手"
        alert.informativeText = "点击下方按钮，会在本用户的“资源库/Application Support/BrowserPet/SafariHelper”生成或更新专用配对助手并打开文件夹。\n\n在 Safari 设置 → 开发者 → 添加临时扩展中选择该文件夹；已加载的助手需重载才能启用工作集关闭/恢复。授予网站访问以读取标题和网址，不要开启隐私浏览权限。\n\n助手不注入网页，只与 127.0.0.1 通信；启用项目后可在本机保存所选/匹配页面的标题、网址、分组和使用时间。临时扩展退出 Safari 或 24 小时后需重新加载。"
        alert.addButton(withTitle:"打开助手文件夹");alert.addButton(withTitle:"稍后连接")
        if alert.runModal() == .alertFirstButtonReturn,let resources = Bundle.main.resourceURL {
            do {
                let pairing = try LocalSetup.pairing(legacy:resources.appendingPathComponent("safari-bridge-config.json"))
                let folder = try LocalSetup.safariHelper(resources:resources,pairing:pairing)
                NSWorkspace.shared.open(folder)
            } catch { showSetupError("无法准备 Safari 助手，请检查本用户资源库的写入权限。") }
        }
    }
    private func updateNativeGroups() {
        let snapshot = groupRepository.snapshot()
        search.setNativeGroups(snapshot.tabs,connected:snapshot.connected)
    }
    private func groupSetup() {
        let alert = NSAlert()
        alert.messageText = "连接 Chrome 原有分组"
        alert.informativeText = "注册本用户的 Chrome 本机连接后，加载只读“BrowserPet 分组助手”，即可保留原组名、颜色和折叠状态；未分组页面按用途归类。\n\n助手仅在本机传递分组信息与定位 ID，不读取正文、不上传数据。各 Chrome 配置文件需分别加载助手。\n\n按钮会更新此应用对应的 Native Messaging 注册并打开扩展文件夹；不会更改其他主机。建议先将 BrowserPet 安装到“应用程序”，以后移动应用需重新注册。"
        alert.addButton(withTitle:"注册连接并打开助手文件夹"); alert.addButton(withTitle:"暂时按用途分类")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try LocalSetup.registerChromeHost(app:Bundle.main.bundleURL)
                NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("chrome-groups"))
            } catch { showSetupError("无法注册 Chrome 本机连接。请检查写入权限，或确认没有其他程序占用同名注册。") }
        }
    }
    private func showSetupError(_ text:String) {
        let alert = NSAlert();alert.messageText = text;alert.addButton(withTitle:"知道了");alert.runModal()
    }
    private func savePetPosition() {
        UserDefaults.standard.set(petPanel.frame.minX,forKey: "pet.x")
        UserDefaults.standard.set(petPanel.frame.minY,forKey: "pet.y")
    }
    private func clampPetPosition() {
        let point = NSPoint(x: petPanel.frame.midX,y: petPanel.frame.midY)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        let rect = screen.visibleFrame
        petPanel.setFrameOrigin(NSPoint(x: min(max(petPanel.frame.minX,rect.minX),rect.maxX-petPanel.frame.width),y: min(max(petPanel.frame.minY,rect.minY),rect.maxY-petPanel.frame.height)))
    }
    @objc private func screensChanged() { clampPetPosition(); if search.panel.isVisible { positionSearch() } }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { openSearch(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        groupBridge.stop()
        safariLoopback?.stop()
        if let safariObserver { NSWorkspace.shared.notificationCenter.removeObserver(safariObserver) }
        refreshTimer?.invalidate(); if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        activityTimer?.invalidate()
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let replacement = makeMenu()
        guard menu.items.map(\.title) != replacement.items.map(\.title) ||
              menu.items.map(\.isEnabled) != replacement.items.map(\.isEnabled) else { return }
        menu.removeAllItems()
        for item in replacement.items { replacement.removeItem(item); menu.addItem(item) }
    }
}
