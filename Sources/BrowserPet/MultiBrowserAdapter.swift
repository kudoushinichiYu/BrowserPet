import AppKit

final class MultiBrowserAdapter: BrowserAdapter {
    private let chrome:BrowserAdapter
    private let edge:BrowserAdapter
    let safari: BrowserAdapter
    var preferredBrowser:BrowserKind = .chrome
    init(safari:BrowserAdapter,chrome:BrowserAdapter = ChromeAdapter(),edge:BrowserAdapter = ChromeAdapter(browser:.edge)) {
        self.safari = safari;self.chrome = chrome;self.edge = edge
    }
    func retryPermissions() { (chrome as? ChromeAdapter)?.retryPermissions();(edge as? ChromeAdapter)?.retryPermissions() }
    func scan(completion:@escaping (Result<BrowserSnapshot,BrowserFailure>)->Void) {
        let group = DispatchGroup()
        var snapshots: [BrowserKind:BrowserSnapshot] = [:],notices: [BrowserNotice] = []
        let adapters: [(BrowserKind,BrowserAdapter)] = [(.chrome,chrome),(.safari,safari),(.edge,edge)]
        for (browser,adapter) in adapters {
            group.enter()
            adapter.scan { result in
                DispatchQueue.main.async {
                switch result {
                case let .success(snapshot): snapshots[browser] = snapshot
                case let .failure(error):
                    if error.kind != .notInstalled && error.kind != .notRunning {
                        notices.append(BrowserNotice(browser:browser.rawValue,message:"\(browser.name)：\(error.message)",permission:error.kind == .permission))
                    }
                }
                group.leave()
                }
            }
        }
        group.notify(queue:.main) {
            let order: [BrowserKind] = [self.preferredBrowser]+BrowserKind.allCases.filter { $0 != self.preferredBrowser }
            var tabs: [BrowserTab] = [],normal = 0,excluded = 0,skipped = 0,current:String?
            for browser in order {
                guard let snapshot = snapshots[browser] else { continue }
                tabs += snapshot.tabs.map { value in var tab = value;tab.isActive = browser == self.preferredBrowser && tab.isActive;return tab }
                normal += snapshot.normalWindowCount;excluded += snapshot.excludedPrivateWindowCount;skipped += snapshot.skippedWindowCount
                if current == nil,let id = snapshot.currentWindowID { current = browser.rawValue+":"+id }
            }
            completion(.success(BrowserSnapshot(status:"ok",tabs:tabs,currentWindowID:current,normalWindowCount:normal,
                excludedPrivateWindowCount:excluded,skippedWindowCount:skipped,notices:notices.sorted { $0.browser < $1.browser })))
        }
    }
    func activate(_ tab:BrowserTab,completion:@escaping (Result<Void,BrowserFailure>)->Void) {
        switch BrowserKind(rawValue:tab.browser) {
        case .chrome:chrome.activate(tab,completion:completion)
        case .edge:edge.activate(tab,completion:completion)
        case .safari:safari.activate(tab,completion:completion)
        case nil:completion(.failure(.closed))
        }
    }
    private func source(_ tab:BrowserTab) -> BrowserAdapter? {
        switch BrowserKind(rawValue:tab.browser) { case .chrome:return chrome;case .edge:return edge;case .safari:return safari;case nil:return nil }
    }
    func close(_ tab:BrowserTab,completion:@escaping (Result<Void,BrowserFailure>)->Void) {
        guard let adapter = source(tab) else { completion(.failure(.closed));return };adapter.close(tab,completion:completion)
    }
    func reopen(_ tab:BrowserTab,completion:@escaping (Result<BrowserTab,BrowserFailure>)->Void) {
        guard let adapter = source(tab) else { completion(.failure(.closed));return };adapter.reopen(tab,completion:completion)
    }
}
