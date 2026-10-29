import Foundation

struct WorkspaceOperationResult {
    var succeeded = 0
    var skipped = 0
    var failures:[String] = []
    var summary:String { "完成 \(succeeded) 页，跳过 \(skipped) 页，失败 \(failures.count) 页。"+(failures.isEmpty ? "" : "\n"+failures.prefix(3).joined(separator:"\n")) }
}
/// Saves the entire selection durably before the first destructive browser operation.
final class WorkspaceCoordinator {
    let store:WorkspaceStore
    let adapter:BrowserAdapter
    private(set) var busy = false
    init(store:WorkspaceStore,adapter:BrowserAdapter) { self.store = store;self.adapter = adapter }
    func archiveAndClose(_ tabs:[BrowserTab],projectID:String,completion:@escaping (Result<WorkspaceOperationResult,Error>)->Void) {
        guard !busy else { return };busy = true
        do { try store.save(tabs,projectID:projectID) }
        catch { busy = false;completion(.failure(error));return }
        let pages = tabs.filter { WorkspaceStore.canSave($0) && $0.pinned != true }
        var result = WorkspaceOperationResult();result.skipped = tabs.count-pages.count
        func next(_ index:Int) {
            guard index < pages.count else { self.busy = false;completion(.success(result));return }
            self.adapter.close(pages[index]) { response in
                switch response {
                case .success:result.succeeded += 1
                case let .failure(error):result.failures.append(pages[index].displayTitle+"："+error.message)
                }
                DispatchQueue.main.async { next(index+1) }
            }
        }
        next(0)
    }
    func restore(_ pages:[SavedPage],completion:@escaping (WorkspaceOperationResult)->Void) {
        guard !busy else { return };busy = true
        adapter.scan { response in
            // A failed scan is unknown, never proof that no matching tabs exist.
            guard case let .success(snapshot) = response,snapshot.skippedWindowCount == 0 else {
                self.busy = false;completion(.init(failures:["当前浏览器列表不完整，请先完成连接并刷新后再恢复，以免重复打开。"]));return
            }
            var result = WorkspaceOperationResult()
            let unavailable = Set((snapshot.notices ?? []).map(\.browser))
            var existing = Set(snapshot.tabs.map { WorkspaceStore.usageKey($0) })
            var windows:[String:BrowserTab] = [:]
            func next(_ index:Int) {
                guard index < pages.count else { self.busy = false;completion(result);return }
                let page = pages[index],key = WorkspaceStore.usageKey(page.tab)
                if unavailable.contains(page.tab.browser) { result.failures.append(page.tab.displayTitle+"：请先连接该浏览器再恢复。");DispatchQueue.main.async { next(index+1) };return }
                guard WorkspaceStore.canSave(page.tab),!existing.contains(key) else { result.skipped += 1;DispatchQueue.main.async { next(index+1) };return }
                var target = page.tab
                if let opened = windows[page.tab.windowKey] { target.windowID = opened.windowID;target.browserSession = opened.browserSession }
                self.adapter.reopen(target) { response in
                    switch response {
                    case let .success(opened):result.succeeded += 1;existing.insert(key);windows[page.tab.windowKey] = opened
                    case let .failure(error):result.failures.append(page.tab.displayTitle+"："+error.message)
                    }
                    DispatchQueue.main.async { next(index+1) }
                }
            }
            next(0)
        }
    }
}
