import AppKit

private final class WorkspaceBrowser:BrowserAdapter {
    var tabs:[BrowserTab] = []
    var closed:[BrowserTab] = [],opened:[BrowserTab] = []
    var failClose:Set<String> = []
    var notices:[BrowserNotice] = []
    var beforeClose:(()->Void)?
    func scan(completion:@escaping (Result<BrowserSnapshot,BrowserFailure>)->Void) {
        completion(.success(.init(status:"ok",tabs:tabs,currentWindowID:nil,normalWindowCount:1,excludedPrivateWindowCount:0,skippedWindowCount:0,notices:notices)))
    }
    func activate(_ tab:BrowserTab,completion:@escaping (Result<Void,BrowserFailure>)->Void) { completion(.success(())) }
    func close(_ tab:BrowserTab,completion:@escaping (Result<Void,BrowserFailure>)->Void) {
        beforeClose?();closed.append(tab)
        if failClose.contains(tab.id) { completion(.failure(.closed)) }
        else { tabs.removeAll { $0.id == tab.id };completion(.success(())) }
    }
    func reopen(_ tab:BrowserTab,completion:@escaping (Result<BrowserTab,BrowserFailure>)->Void) {
        var value = tab;value.windowID = "restored";value.tabID = UUID().uuidString;value.browserSession = "new-session"
        tabs.append(value);opened.append(value);completion(.success(value))
    }
}
@main struct WorkspaceChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var count = 0
        func check(_ name:String,_ value:Bool) { precondition(value,name);count += 1;print("PASS "+name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browserpet-workspaces-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try WorkspaceStore(root:root.appendingPathComponent("main")),start = Date(timeIntervalSince1970:1700000000)
        let a = BrowserTab(windowID:"window-a",tabID:"1",title:"Diffusion research",url:"https://example.test/paper",windowTitle:"Work",windowNumber:1,isActive:false,browserSession:"session",nativeGroup:.init(key:"group",title:"Diffusion",color:"blue",collapsed:true))
        var b = a;b.tabID = "2";b.url = "https://unrelated.test/";b.title = "Other page";b.nativeGroup = nil
        try store.observe([a,b],foregroundBrowser:nil,now:start)
        check("no project means no timestamp tracking or persistence",store.state.usage.isEmpty && !FileManager.default.fileExists(atPath:store.root.path))
        let project = try store.create(name:"Diffusion",keywords:["diffusion"],automatic:true,now:start)
        try store.observe([a,b],foregroundBrowser:nil,now:start)
        check("automatic project capture matches title across domains without collecting unrelated URLs",store.projects[0].pages.map(\.tab.url) == [a.url])
        let serialized = try String(contentsOf:store.root.appendingPathComponent("workspaces.json"),encoding:.utf8)
        check("unrelated activity stores only hashed keys and timestamps",!serialized.contains("unrelated.test") && store.state.usage.count == 2)
        check("first observation cannot immediately classify existing tabs as three days unused",store.candidates([a,b],projectID:project,now:start).isEmpty)
        try store.observe([b],foregroundBrowser:nil,now:start.addingTimeInterval(2*86400))
        check("background active flags do not count as foreground browser usage",store.usage(for:b)?.lastUsed == nil)
        var active = a;active.isActive = true
        try store.observe([active],foregroundBrowser:"chrome",now:start.addingTimeInterval(2*86400))
        check("real foreground usage postpones an unused candidate",store.candidates([a,b],projectID:project,now:start.addingTimeInterval(3*86400+1)).map(\.id) == [b.id])
        var pinned = b;pinned.pinned = true
        check("current and known pinned tabs are protected from cleanup suggestions",store.candidates([active,pinned],projectID:project,now:start.addingTimeInterval(9*86400)).isEmpty)
        check("unrelated cleanup requires a chosen project and preserves assigned pages",store.candidates([a,b],rule:.unrelated,projectID:project).map(\.id) == [b.id] && store.candidates([b],rule:.unrelated,projectID:nil).isEmpty)
        var newlyOpened = b;newlyOpened.tabID = "reopened"
        let later = start.addingTimeInterval(10*86400)
        try store.observe([newlyOpened],foregroundBrowser:nil,now:later)
        check("a newly opened tab resets the idle baseline even when its URL was seen before",store.candidates([newlyOpened],projectID:project,now:later).isEmpty)
        let loaded = try WorkspaceStore(root:store.root)
        check("round trip retains original group color collapse and observed usage",loaded.projects[0].pages[0].tab.nativeGroup == a.nativeGroup && loaded.projects[0].pages[0].lastUsed != nil)
        let permissions = try FileManager.default.attributesOfItem(atPath:store.root.appendingPathComponent("workspaces.json").path)[.posixPermissions] as! NSNumber
        check("project metadata file is owner-only",permissions.intValue == 0o600)
        var bad = a;bad.url = "javascript:alert(1)"
        var credentials = a;credentials.url = "https://user:password@example.test/"
        check("executable local-file and credential-bearing URLs are not persisted",!WorkspaceStore.canSave(bad) && !WorkspaceStore.canSave(credentials))
        let browser = WorkspaceBrowser();browser.tabs = [a,b];browser.failClose = [b.id]
        browser.beforeClose = {
            let persisted = try! WorkspaceStore(root:store.root)
            precondition(Set(persisted.projects[0].pages.map(\.tab.url)) == Set([a.url,b.url]),"Close ran before the complete archive was saved")
        }
        let coordinator = WorkspaceCoordinator(store:store,adapter:browser)
        let archived:Result<WorkspaceOperationResult,Error> = await withCheckedContinuation { continuation in coordinator.archiveAndClose([a,b],projectID:project) { continuation.resume(returning:$0) } }
        let result = try archived.get()
        check("all selected pages are on disk before the first close; partial failure keeps every recovery record",result.succeeded == 1 && result.failures.count == 1 && store.projects[0].pages.count == 2)
        browser.beforeClose = nil;browser.notices = [.init(browser:"safari",message:"Not connected")]
        let restored = await withCheckedContinuation { continuation in coordinator.restore(store.projects[0].pages) { continuation.resume(returning:$0) } }
        check("restoration skips already open links and unrelated disconnected browsers",restored.succeeded == 1 && restored.skipped == 1 && browser.opened.count == 1)
        let repeated = await withCheckedContinuation { continuation in coordinator.restore(store.projects[0].pages) { continuation.resume(returning:$0) } }
        check("repeat restoration does not duplicate successful pages or erase the archive",repeated.succeeded == 0 && repeated.skipped == 2 && store.projects[0].pages.count == 2)
        try store.observe(browser.tabs,foregroundBrowser:nil)
        check("automatic capture reuses saved URLs after restoration into a replacement window",store.projects[0].pages.count == 2)
        let failedRoot = root.appendingPathComponent("blocked"),failedStore = try WorkspaceStore(root:failedRoot)
        let failedProject = try failedStore.create(name:"Blocked")
        try FileManager.default.moveItem(at:failedRoot,to:root.appendingPathComponent("preserved"))
        try Data("Not a directory".utf8).write(to:failedRoot)
        let untouched = WorkspaceBrowser(),blocked = WorkspaceCoordinator(store:failedStore,adapter:untouched)
        let blockedResult:Result<WorkspaceOperationResult,Error> = await withCheckedContinuation { continuation in blocked.archiveAndClose([a],projectID:failedProject) { continuation.resume(returning:$0) } }
        check("a storage failure prevents every browser close",(try? blockedResult.get()) == nil && untouched.closed.isEmpty)
        let corrupt = root.appendingPathComponent("corrupt");try FileManager.default.createDirectory(at:corrupt,withIntermediateDirectories:true)
        let broken = Data("broken data".utf8);try broken.write(to:corrupt.appendingPathComponent("workspaces.json"))
        let refusedFile = try? WorkspaceStore(root:corrupt)
        check("corrupt files are refused without being overwritten",try refusedFile == nil && Data(contentsOf:corrupt.appendingPathComponent("workspaces.json")) == broken)
        let safari = SafariAdapter(),instance = UUID().uuidString,profile = UUID().uuidString
        var exchange = SafariExchange(version:1,instanceID:instance,profileID:profile,sequence:1,windows:[.init(id:1,focused:true)],tabs:[.init(id:2,windowID:1,title:a.title,url:a.url,active:false)])
        _ = try safari.receive(exchange)
        let indexed:Result<BrowserSnapshot,BrowserFailure> = await withCheckedContinuation { continuation in safari.scan { continuation.resume(returning:$0) } }
        let safariTab = try indexed.get().tabs[0]
        let unsupported:Result<Void,BrowserFailure> = await withCheckedContinuation { continuation in safari.close(safariTab) { continuation.resume(returning:$0) } }
        check("legacy Safari helpers cannot receive destructive workspace commands",try (try? unsupported.get()) == nil && safari.receive(exchange).command == nil)
        exchange.sequence += 1;exchange.capabilities = ["workspaces-v1"];_ = try safari.receive(exchange)
        let closed:Result<Void,BrowserFailure> = await withCheckedContinuation { continuation in
            safari.close(safariTab) { continuation.resume(returning:$0) }
            let command = try! safari.receive(exchange).command!;precondition(command.action == "close" && command.url == a.url)
            exchange.sequence += 1;exchange.tabs = [];exchange.reply = .init(id:command.id,status:"removed");_ = try! safari.receive(exchange)
        }
        check("Safari closure requires a removal acknowledgement and disappearance",(try? closed.get()) != nil)
        let reopened:Result<BrowserTab,BrowserFailure> = await withCheckedContinuation { continuation in
            safari.reopen(safariTab) { continuation.resume(returning:$0) }
            let command = try! safari.receive(exchange).command!;precondition(command.action == "reopen")
            exchange.sequence += 1;exchange.tabs = [.init(id:9,windowID:1,title:a.title,url:a.url,active:false)]
            exchange.reply = .init(id:command.id,status:"opened",windowID:1,tabID:9);_ = try! safari.receive(exchange)
        }
        check("Safari restoration returns a new tab identity in the same paired profile",try reopened.get().tabID == "9")
        let controller = WorkspaceController(store:store,adapter:browser)
        controller.update([a,b],foregroundBrowser:nil);controller.window.contentView?.layoutSubtreeIfNeeded()
        check("workspace window builds offscreen with persisted projects without closing or opening real tabs",controller.projectID == project && !controller.window.isVisible)
        func views(_ root:NSView) -> [NSView] { [root]+root.subviews.flatMap(views) }
        let controls = views(controller.window.contentView!)
        let modes = controls.compactMap { $0 as? NSSegmentedControl }.first!
        modes.selectedSegment = 1;_ = modes.sendAction(modes.action!,to:modes.target)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let table = controls.compactMap { $0 as? NSTableView }.first!
        table.enclosingScrollView?.tile()
        let restoreControl = controls.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("恢复项目") }!
        restoreControl.performClick(nil)
        let busyCells = (0..<table.numberOfRows).compactMap { table.view(atColumn:0,row:$0,makeIfNecessary:true) as? NSButton }
        let busyDisabled = !busyCells.isEmpty && busyCells.allSatisfy { !$0.isEnabled }
        for _ in 0..<1000 { if restoreControl.isEnabled { break };await Task.yield() }
        check("workspace row checkboxes are re-enabled after a completed operation without changed row metadata",busyDisabled && restoreControl.isEnabled && busyCells.allSatisfy { $0.isEnabled })
        try store.removeProject(id:project)
        check("removing the final project clears tracked URL hashes and stops retention",store.projects.isEmpty && store.state.usage.isEmpty)
        print("\(count) workspace storage, lifecycle and offscreen UI checks passed. All browser data synthetic.")
    }
}
