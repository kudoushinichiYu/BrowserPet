import Foundation

struct SafariExchange: Codable {
    struct Window: Codable { var id:Int;var focused:Bool }
    struct Tab: Codable { var id:Int;var windowID:Int;var title:String;var url:String;var active:Bool;var pinned:Bool? = nil }
    struct Reply: Codable { var id:String;var status:String;var windowID:Int? = nil;var tabID:Int? = nil }
    var version:Int
    var instanceID:String
    var profileID:String
    var sequence:Int
    var windows:[Window]
    var tabs:[Tab]
    var reply:Reply?
    var capabilities:[String]? = nil
    func validate() throws {
        let ids = Set(windows.map(\.id))
        guard version == 1,UUID(uuidString:instanceID) != nil,UUID(uuidString:profileID) != nil,sequence >= 0,sequence < Int.max-1,
              windows.count <= 1000,tabs.count <= 20000,ids.count == windows.count,windows.allSatisfy({ $0.id > 0 }),
              Set(tabs.map(\.id)).count == tabs.count,
              tabs.allSatisfy({ $0.id > 0 && ids.contains($0.windowID) && $0.title.utf8.count <= 8192 && $0.url.utf8.count <= 32768 }),
              (capabilities?.count ?? 0) <= 8,
              reply == nil || (UUID(uuidString:reply!.id) != nil && ["selected","closed","error","removed","opened","changed"].contains(reply!.status))
        else { throw GroupProtocolError.invalid }
    }
}
struct SafariCommand: Codable { var id:String;var instanceID:String;var windowID:Int;var tabID:Int;var action:String? = nil;var url:String? = nil }
struct SafariResponse: Codable { var connected:Bool;var command:SafariCommand? }

final class SafariAdapter: BrowserAdapter {
    private struct Owner { var snapshot:SafariExchange;var received:Date }
    private struct Pending { var command:SafariCommand;var source:BrowserTab;var completion:(Result<BrowserTab,BrowserFailure>)->Void }
    private let lock = NSLock()
    private var owners: [String:Owner] = [:]
    private var pending:Pending?
    private var retired = Set<String>()
    var transportError:String?

    func receive(_ exchange:SafariExchange,now:Date = Date()) throws -> SafariResponse {
        try exchange.validate()
        lock.lock()
        guard !retired.contains(exchange.instanceID) else { lock.unlock();throw GroupProtocolError.invalid }
        let old = owners[exchange.instanceID]
        if old == nil || exchange.sequence > old!.snapshot.sequence {
            let replaced = owners.filter { $0.key != exchange.instanceID && $0.value.snapshot.profileID == exchange.profileID }.map(\.key)
            for id in replaced { owners.removeValue(forKey:id);retired.insert(id) }
            owners[exchange.instanceID] = Owner(snapshot:exchange,received:now)
        }
        var resolved:Pending?,result:Result<BrowserTab,BrowserFailure>?
        if let reply = exchange.reply,let waiting = pending,reply.id == waiting.command.id,exchange.instanceID == waiting.command.instanceID {
            pending = nil;resolved = waiting
            let action = waiting.command.action ?? "activate"
            if action == "activate",reply.status == "selected" { result = .success(waiting.source) }
            else if action == "close",reply.status == "removed",!exchange.tabs.contains(where:{ $0.id == waiting.command.tabID && $0.windowID == waiting.command.windowID }) { result = .success(waiting.source) }
            else if action == "reopen",reply.status == "opened",let window = reply.windowID,let id = reply.tabID,
                    exchange.tabs.contains(where:{ $0.id == id && $0.windowID == window }) {
                var opened = waiting.source;opened.windowID = exchange.profileID+":"+String(window);opened.tabID = String(id);opened.browserSession = exchange.instanceID
                result = .success(opened)
            } else { result = .failure(reply.status == "closed" ? .closed : .init(kind:.unknown,message:"Safari 未确认此操作，工作集已保留，请刷新后重试。")) }
        }
        let command = pending.flatMap { $0.command.instanceID == exchange.instanceID ? $0.command : nil }
        lock.unlock()
        if let resolved,let result { DispatchQueue.main.async { resolved.completion(result) } }
        return SafariResponse(connected:true,command:command)
    }
    func scan(completion:@escaping (Result<BrowserSnapshot,BrowserFailure>)->Void) {
        lock.lock();owners = owners.filter { Date().timeIntervalSince($0.value.received) < 8 }
        let snapshots = owners.values.map(\.snapshot);lock.unlock()
        guard !snapshots.isEmpty else {
            completion(.failure(.init(kind:.connection,message:transportError ?? "连接 Safari 助手后可收纳页面；点击面板中的“Safari 连接”。")));return
        }
        var tabs: [BrowserTab] = [],current:String?
        for snapshot in snapshots.sorted(by:{ $0.instanceID < $1.instanceID }) {
            let focused = snapshot.windows.first { $0.focused }?.id
            if current == nil { current = focused.map { snapshot.profileID+":"+String($0) } }
            tabs += snapshot.tabs.map { tab in
                BrowserTab(browser:"safari",windowID:snapshot.profileID+":"+String(tab.windowID),tabID:String(tab.id),title:tab.title,url:tab.url,
                    windowTitle:"",windowNumber:1,isActive:tab.active && tab.windowID == focused,browserSession:snapshot.instanceID,pinned:tab.pinned)
            }
        }
        completion(.success(.init(status:"ok",tabs:tabs,currentWindowID:current,normalWindowCount:snapshots.reduce(0) { $0+$1.windows.count },
            excludedPrivateWindowCount:0,skippedWindowCount:0)))
    }
    func activate(_ tab:BrowserTab,completion:@escaping (Result<Void,BrowserFailure>)->Void) {
        send(tab,action:"activate") { completion($0.map { _ in () }) }
    }
    func close(_ tab:BrowserTab,completion:@escaping (Result<Void,BrowserFailure>)->Void) {
        send(tab,action:"close") { completion($0.map { _ in () }) }
    }
    func reopen(_ tab:BrowserTab,completion:@escaping (Result<BrowserTab,BrowserFailure>)->Void) { send(tab,action:"reopen",completion:completion) }
    private func send(_ tab:BrowserTab,action:String,completion:@escaping (Result<BrowserTab,BrowserFailure>)->Void) {
        lock.lock()
        let ownerID = action == "reopen" ? owners.first(where:{ tab.windowID.hasPrefix($0.value.snapshot.profileID+":") && Date().timeIntervalSince($0.value.received) < 8 })?.key : tab.browserSession
        guard tab.browser == "safari",let ownerID,let owner = owners[ownerID],
              Date().timeIntervalSince(owner.received) < 8,tab.windowID.hasPrefix(owner.snapshot.profileID+":"),
              let windowID = Int(tab.windowID.split(separator:":").last ?? ""),let tabID = Int(tab.tabID),
              (action == "reopen" || owner.snapshot.tabs.contains(where:{ $0.id == tabID && $0.windowID == windowID })),pending == nil else {
            lock.unlock();completion(.failure(.closed));return
        }
        guard action == "activate" || owner.snapshot.capabilities?.contains("workspaces-v1") == true else {
            lock.unlock();completion(.failure(.init(kind:.connection,message:"请用“Safari 连接”重新生成并重载助手，以启用工作集关闭与恢复。")));return
        }
        if action == "reopen" && !WorkspaceStore.canSave(tab) { lock.unlock();completion(.failure(.closed));return }
        let window = action == "reopen" && !owner.snapshot.windows.contains(where:{ $0.id == windowID }) ? 0 : windowID
        let command = SafariCommand(id:UUID().uuidString,instanceID:ownerID,windowID:window,tabID:tabID,action:action == "activate" ? nil : action,url:action == "activate" ? nil : tab.url)
        pending = Pending(command:command,source:tab,completion:completion);lock.unlock()
        DispatchQueue.main.asyncAfter(deadline:.now()+7) { [weak self] in
            guard let self else { return };self.lock.lock()
            let timed = self.pending?.command.id == command.id ? self.pending : nil
            if timed != nil { self.pending = nil };self.lock.unlock()
            timed?.completion(.failure(.init(kind:.connection,message:"Safari 助手未响应，请确认助手仍在运行后重试。")))
        }
    }
    func clear() {
        lock.lock();retired.formUnion(owners.keys);owners.removeAll();let waiting = pending;pending = nil;lock.unlock()
        if let waiting { DispatchQueue.main.async { waiting.completion(.failure(.closed)) } }
    }
}
