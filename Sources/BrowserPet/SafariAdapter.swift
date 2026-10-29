import Foundation

struct SafariExchange: Codable {
    struct Window: Codable { var id:Int;var focused:Bool }
    struct Tab: Codable { var id:Int;var windowID:Int;var title:String;var url:String;var active:Bool }
    struct Reply: Codable { var id:String;var status:String }
    var version:Int
    var instanceID:String
    var profileID:String
    var sequence:Int
    var windows:[Window]
    var tabs:[Tab]
    var reply:Reply?
    func validate() throws {
        let ids = Set(windows.map(\.id))
        guard version == 1,UUID(uuidString:instanceID) != nil,UUID(uuidString:profileID) != nil,sequence >= 0,sequence < Int.max-1,
              windows.count <= 1000,tabs.count <= 20000,ids.count == windows.count,windows.allSatisfy({ $0.id > 0 }),
              Set(tabs.map(\.id)).count == tabs.count,
              tabs.allSatisfy({ $0.id > 0 && ids.contains($0.windowID) && $0.title.utf8.count <= 8192 && $0.url.utf8.count <= 32768 }),
              reply == nil || (UUID(uuidString:reply!.id) != nil && ["selected","closed","error"].contains(reply!.status))
        else { throw GroupProtocolError.invalid }
    }
}
struct SafariCommand: Codable { var id:String;var instanceID:String;var windowID:Int;var tabID:Int }
struct SafariResponse: Codable { var connected:Bool;var command:SafariCommand? }

final class SafariAdapter: BrowserAdapter {
    private struct Owner { var snapshot:SafariExchange;var received:Date }
    private struct Pending { var command:SafariCommand;var completion:(Result<Void,BrowserFailure>)->Void }
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
        var resolved:Pending?,result:Result<Void,BrowserFailure>?
        if let reply = exchange.reply,let waiting = pending,reply.id == waiting.command.id,exchange.instanceID == waiting.command.instanceID {
            pending = nil;resolved = waiting
            result = reply.status == "selected" ? .success(()) : .failure(reply.status == "closed" ? .closed : .init(kind:.unknown,message:"Safari 未能切回原标签页，请重试。"))
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
                    windowTitle:"",windowNumber:1,isActive:tab.active && tab.windowID == focused,browserSession:snapshot.instanceID)
            }
        }
        completion(.success(.init(status:"ok",tabs:tabs,currentWindowID:current,normalWindowCount:snapshots.reduce(0) { $0+$1.windows.count },
            excludedPrivateWindowCount:0,skippedWindowCount:0)))
    }
    func activate(_ tab:BrowserTab,completion:@escaping (Result<Void,BrowserFailure>)->Void) {
        lock.lock()
        guard tab.browser == "safari",let ownerID = tab.browserSession,let owner = owners[ownerID],
              Date().timeIntervalSince(owner.received) < 8,tab.windowID.hasPrefix(owner.snapshot.profileID+":"),
              let windowID = Int(tab.windowID.split(separator:":").last ?? ""),let tabID = Int(tab.tabID),
              owner.snapshot.tabs.contains(where:{ $0.id == tabID && $0.windowID == windowID }),pending == nil else {
            lock.unlock();completion(.failure(.closed));return
        }
        let command = SafariCommand(id:UUID().uuidString,instanceID:ownerID,windowID:windowID,tabID:tabID)
        pending = Pending(command:command,completion:completion);lock.unlock()
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
