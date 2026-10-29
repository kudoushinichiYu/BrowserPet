import Foundation

private final class FakeBrowser: BrowserAdapter {
    var result:Result<BrowserSnapshot,BrowserFailure>
    var selected:BrowserTab?
    init(_ result:Result<BrowserSnapshot,BrowserFailure>) { self.result = result }
    func scan(completion:@escaping (Result<BrowserSnapshot,BrowserFailure>)->Void) { completion(result) }
    func activate(_ tab:BrowserTab,completion:@escaping (Result<Void,BrowserFailure>)->Void) { selected = tab;completion(.success(())) }
}

@main struct MultiBrowserChecks {
    static func request(_ port:UInt16,token:String,origin:String,method:String = "POST",body:Data?) async throws -> (HTTPURLResponse,Data) {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:];config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration:config);defer { session.invalidateAndCancel() }
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/v1/safari/sync")!)
        request.httpMethod = method;request.httpBody = body
        request.setValue(origin,forHTTPHeaderField:"Origin")
        if method == "OPTIONS" { request.setValue("POST",forHTTPHeaderField:"Access-Control-Request-Method") }
        else { request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response) = try await session.data(for:request)
        return (response as! HTTPURLResponse,data)
    }
    static func scan(_ adapter:BrowserAdapter) async -> Result<BrowserSnapshot,BrowserFailure> {
        await withCheckedContinuation { continuation in adapter.scan { continuation.resume(returning:$0) } }
    }
    static func main() async throws {
        var checks = 0
        func check(_ name:String,_ value:Bool) { precondition(value,name);checks += 1;print("PASS "+name) }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("browserpet-setup-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:temporary) }
        let firstRoot = temporary.appendingPathComponent("first"),secondRoot = temporary.appendingPathComponent("second")
        let first = try LocalSetup.pairing(at:firstRoot),second = try LocalSetup.pairing(at:secondRoot)
        check("fresh installs receive distinct random 64-hex pairing secrets",first.token != second.token && first.token.count == 64 && first.token.allSatisfy(\.isHexDigit))
        check("pairing survives repeat initialization",try LocalSetup.pairing(at:firstRoot).token == first.token)
        let legacy = temporary.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(first).write(to:legacy)
        let migrated = try LocalSetup.pairing(at:temporary.appendingPathComponent("migrated"),legacy:legacy)
        check("developer pairing migration retains the existing helper connection",migrated.token == first.token)
        let helper = try LocalSetup.safariHelper(resources:URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("extensions"),at:firstRoot,pairing:first)
        let config = try String(contentsOf:helper.appendingPathComponent("config.js"),encoding:.utf8)
        let helperFiles = Set(try fm.contentsOfDirectory(atPath:helper.path))
        check("generated helper contains its own pairing and exact allowlisted files",config.contains(first.token) && helperFiles == Set(["config.js","manifest.json","protocol.js","background.js"]))
        func permissions(_ file:URL) throws -> Int { (try fm.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber).intValue }
        check("pairing and helper permissions are owner-only",try permissions(firstRoot) == 0o700 && permissions(helper) == 0o700 && permissions(helper.appendingPathComponent("config.js")) == 0o600 && permissions(firstRoot.appendingPathComponent("safari-pairing.json")) == 0o600)
        let brokenRoot = temporary.appendingPathComponent("broken")
        try fm.createDirectory(at:brokenRoot,withIntermediateDirectories:true)
        let broken = brokenRoot.appendingPathComponent("safari-pairing.json"),bad = Data("{\"port\":49731,\"token\":\"invalid\"}".utf8)
        try bad.write(to:broken)
        let brokenPairing = try? LocalSetup.pairing(at:brokenRoot)
        check("invalid pairing is refused without silently overwriting it",try brokenPairing == nil && Data(contentsOf:broken) == bad)
        let app = temporary.appendingPathComponent("Applications with spaces/BrowserPet.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at:resources,withIntermediateDirectories:true)
        try fm.copyItem(atPath:"Resources/group-bridge-config.json",toPath:resources.appendingPathComponent("group-bridge-config.json").path)
        let host = resources.appendingPathComponent("group-native-host")
        try fm.copyItem(atPath:"Resources/group-native-host",toPath:host.path)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:host.path)
        let hostDirectory = temporary.appendingPathComponent("isolated-hosts")
        try LocalSetup.registerChromeHost(app:app,directory:hostDirectory)
        let hostFile = hostDirectory.appendingPathComponent("local.browserpet.groups.json")
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:hostFile)) as! [String:Any]
        check("Chrome registration uses the installed app path including spaces",try manifest["path"] as? String == host.path && permissions(hostFile) == 0o600)
        let unrelated = Data("{\"name\":\"unrelated\",\"allowed_origins\":[]}".utf8)
        try unrelated.write(to:hostFile)
        var refused = false
        do { try LocalSetup.registerChromeHost(app:app,directory:hostDirectory) } catch { refused = true }
        check("unrelated Chrome host registrations are preserved",try refused && Data(contentsOf:hostFile) == unrelated)
        var chrome = DemoData.tabs[0];chrome.windowID = "1";chrome.tabID = "1"
        var edge = chrome;edge.browser = "edge"
        var safari = chrome;safari.browser = "safari"
        let mixed = [chrome,edge,safari]
        check("same numeric IDs remain distinct across all three browsers",Set(mixed.map(\.id)).count == 3)
        let grouped = SearchEngine.groups(tabs:mixed,query:"",currentWindowID:"edge:1",mode:.window)
        check("window groups and current-window ranking are browser-scoped",grouped.count == 3 && grouped.first?.tabs.first?.browser == "edge")
        check("browser name can be included in search",SearchEngine.groups(tabs:mixed,query:"safari",currentWindowID:nil).flatMap(\.tabs).map(\.browser) == ["safari"])
        func snapshot(_ tabs:[BrowserTab]) -> BrowserSnapshot { .init(status:"ok",tabs:tabs,currentWindowID:"1",normalWindowCount:1,excludedPrivateWindowCount:0,skippedWindowCount:0) }
        let a = FakeBrowser(.failure(.denied)),b = FakeBrowser(.success(snapshot([edge]))),c = FakeBrowser(.success(snapshot([safari])))
        let adapter = MultiBrowserAdapter(safari:c,chrome:a,edge:b);adapter.preferredBrowser = .edge
        let merged = try await scan(adapter).get()
        check("Chrome permission denial does not hide Safari and Edge pages",merged.tabs.count == 2 && merged.notices?.count == 1 && merged.currentWindowID == "edge:1")
        _ = await withCheckedContinuation { continuation in adapter.activate(edge) { continuation.resume(returning:$0) } }
        check("activation routed exclusively to the original browser",b.selected?.id == edge.id && a.selected == nil && c.selected == nil)
        let service = SafariAdapter()
        let instance = UUID().uuidString,profile = UUID().uuidString
        var message = SafariExchange(version:1,instanceID:instance,profileID:profile,sequence:1,windows:[.init(id:1,focused:true)],tabs:[.init(id:1,windowID:1,title:"Original",url:"https://example.com",active:true)])
        _ = try service.receive(message)
        let indexed = try await scan(service).get().tabs[0]
        check("Safari profile and worker identities are retained",indexed.windowID == profile+":1" && indexed.browserSession == instance)
        message.sequence = 0;message.tabs[0].title = "Stale";_ = try service.receive(message)
        check("Safari out-of-order snapshot cannot overwrite newer titles",try await scan(service).get().tabs[0].title == "Original")
        message.sequence = 2
        let activation:Result<Void,BrowserFailure> = await withCheckedContinuation { continuation in
            service.activate(indexed) { continuation.resume(returning:$0) }
            do {
                let command = try service.receive(message).command!
                precondition(command.windowID == 1 && command.tabID == 1 && command.instanceID == instance)
                message.sequence += 1;message.reply = .init(id:command.id,status:"selected")
                _ = try service.receive(message)
            } catch { fatalError("Command exchange failed") }
        }
        check("Safari activation requires exact command acknowledgement",(try? activation.get()) != nil)
        var other = message;other.profileID = UUID().uuidString;other.instanceID = UUID().uuidString;other.sequence = 1;other.reply = nil
        _ = try service.receive(other)
        check("Safari profiles with identical numeric IDs do not overwrite each other",try await scan(service).get().tabs.count == 2)
        var restarted = message;restarted.instanceID = UUID().uuidString;restarted.sequence = 1;restarted.reply = nil
        _ = try service.receive(restarted)
        check("retired Safari worker cannot resurrect an old session",(try? service.receive(message)) == nil)
        let rejected:Result<Void,BrowserFailure> = await withCheckedContinuation { continuation in service.activate(indexed) { continuation.resume(returning:$0) } }
        check("old Safari selection cannot activate after worker replacement",(try? rejected.get()) == nil)
        let expired = SafariAdapter();_ = try expired.receive(other,now:Date().addingTimeInterval(-10))
        check("disconnected Safari pages expire instead of remaining clickable",(try? await scan(expired).get()) == nil)
        check("Safari rejects website CORS origins and null origins",!SafariLoopback.allowedOrigin("https://example.com") && !SafariLoopback.allowedOrigin("null") && SafariLoopback.allowedOrigin("safari-web-extension://"+UUID().uuidString))
        let httpService = SafariAdapter(),token = String(repeating:"ab",count:32),origin = "safari-web-extension://"+UUID().uuidString
        var listener:SafariLoopback?,port:UInt16 = 0
        for value:UInt16 in 49741...49760 {
            let candidate = SafariLoopback(pairing:.init(port:value,token:token),adapter:httpService)
            if candidate.start() { listener = candidate;port = value;break }
        }
        precondition(listener != nil,"Private loopback test listener could not start");defer { listener?.stop() }
        let body = try JSONEncoder().encode(other)
        let denied = try await request(port,token:"wrong",origin:origin,body:body)
        check("real loopback rejects unpaired clients without exposing metadata",denied.0.statusCode == 403 && denied.1.isEmpty)
        let website = try await request(port,token:token,origin:"https://example.com",body:body)
        check("real loopback rejects website origins even with a valid token",website.0.statusCode == 403 && website.0.value(forHTTPHeaderField:"Access-Control-Allow-Origin") == nil)
        let preflight = try await request(port,token:"",origin:origin,method:"OPTIONS",body:nil)
        check("Safari preflight is limited to its exact extension origin",preflight.0.statusCode == 204 && preflight.0.value(forHTTPHeaderField:"Access-Control-Allow-Origin") == origin)
        let accepted = try await request(port,token:token,origin:origin,body:body)
        let reply = try JSONDecoder().decode(SafariResponse.self,from:accepted.1)
        let received = try await scan(httpService).get()
        check("real paired HTTP exchange populates the Safari adapter",accepted.0.statusCode == 200 && reply.connected && received.tabs.count == 1)
        var invalid = other;invalid.windows = []
        let malformed = try await request(port,token:token,origin:origin,body:JSONEncoder().encode(invalid))
        check("real loopback refuses tabs without a verified ordinary window",malformed.0.statusCode == 400)
        print("\(checks) multi-browser and Safari protocol checks passed. No real browser data used.")
    }
}
