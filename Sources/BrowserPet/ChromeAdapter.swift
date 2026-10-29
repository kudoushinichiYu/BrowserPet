import AppKit

protocol BrowserAdapter {
    func scan(completion: @escaping (Result<BrowserSnapshot, BrowserFailure>) -> Void)
    func activate(_ tab: BrowserTab, completion: @escaping (Result<Void, BrowserFailure>) -> Void)
}

enum AppResources {
    static func url(_ filename: String) -> URL {
        if let url = Bundle.main.url(forResource: filename, withExtension: nil) { return url }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/\(filename)")
    }
}

enum BrowserAvailability {
    static func installed(_ browser:BrowserKind) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier:browser.bundleID) != nil { return true }
        let name = browser == .chrome ? "Google Chrome" : browser == .edge ? "Microsoft Edge" : "Safari"
        return ["/Applications/\(name).app",NSHomeDirectory()+"/Applications/\(name).app"].contains {
            Bundle(path:$0)?.bundleIdentifier == browser.bundleID
        }
    }
}

final class ChromeAdapter: BrowserAdapter {
    private let queue:DispatchQueue
    private let browser:BrowserKind
    private var denied = false
    private var identity = BrowserSessionIdentity()
    private var workspaceObservers: [NSObjectProtocol] = []
    init(browser:BrowserKind = .chrome) {
        self.browser = browser
        queue = DispatchQueue(label:"local.browserpet."+browser.rawValue,qos:.userInitiated)
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == self.browser.bundleID else { return }
                self.identity.invalidate()
                if name == NSWorkspace.didLaunchApplicationNotification { _ = self.identity.observe(app.processIdentifier) }
            }
            workspaceObservers.append(observer)
        }
    }
    deinit { for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    private func diagnose(_ event: String, _ fields: [String:String]) {
        #if BP_DIAGNOSTICS
        let url = URL(fileURLWithPath: "/private/tmp/browserpet-diagnostics.jsonl")
        var values = fields; values["event"] = event; values["time"] = String(Date().timeIntervalSince1970)
        guard var data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close() }
        #endif
    }
    private func chromeSession() -> String {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.chromeSession() } }
        // Workspace queries can transiently return no process while JXA still
        // reads Chrome successfully. Absence is unknown, not proof of restart.
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first?.processIdentifier
        return identity.observe(pid)
    }
    private func failure(_ code: Int?) -> BrowserFailure {
        switch code {
        case -1743, -1744: return .init(kind:.permission,message:"请在系统设置 → 隐私与安全性 → 自动化中，允许 BrowserPet 控制 \(browser.name)，然后重新检测。")
        case -1712: return .init(kind:.timeout,message:"\(browser.name) 暂时没有响应，请稍后重试。")
        case -600, -609: return .init(kind: .notRunning, message: "\(browser.name) 尚未运行或正在退出，打开后再试。")
        case -1728, -1719: return .closed
        default: return .init(kind: .unknown, message: "暂时无法读取或切换 \(browser.name) 页面，请重新检测。\(code.map { "（错误 \($0)）" } ?? "")")
        }
    }

    func scan(completion: @escaping (Result<BrowserSnapshot, BrowserFailure>) -> Void) {
        if denied { completion(.failure(failure(-1743)));return }
        guard BrowserAvailability.installed(browser) else {
            completion(.failure(.init(kind: .notInstalled, message: "未找到 \(browser.name)。"))); return
        }
        let session = chromeSession()
        diagnose("scan-start",["session":session])
        queue.async {
            let result: Result<BrowserSnapshot, BrowserFailure>
            do {
                let script = try self.script("chrome-scan.js")
                let data = try self.execute(script, timeout: 12)
                var snapshot = try JSONDecoder().decode(BrowserSnapshot.self, from: data)
                self.diagnose("scan-reply",["status":snapshot.status,"count":String(snapshot.tabs.count),"before":session,"after":self.chromeSession(),"code":String(snapshot.errorCode ?? 0)])
                for index in snapshot.tabs.indices { snapshot.tabs[index].browserSession = session; snapshot.tabs[index].browser = self.browser.rawValue }
                if snapshot.status == "ok", self.chromeSession() == session { result = .success(snapshot) }
                else if snapshot.status == "ok" { result = .failure(.init(kind: .closed, message: "\(self.browser.name) 已重新启动，请重新检测页面列表。")) }
                else { result = .failure(self.failure(snapshot.status == "notRunning" ? -600 : snapshot.errorCode)) }
            } catch let error as BrowserFailure { self.diagnose("scan-failure",["kind":String(describing:error.kind)]); result = .failure(error) }
            catch { self.diagnose("scan-decode-failure",["type":String(describing:type(of:error))]); result = .failure(self.failure(nil)) }
            DispatchQueue.main.async {
                if case let .failure(error) = result,error.kind == .permission { self.denied = true }
                completion(result)
            }
        }
    }

    func activate(_ tab: BrowserTab, completion: @escaping (Result<Void, BrowserFailure>) -> Void) {
        guard tab.browser == browser.rawValue else { completion(.failure(.closed));return }
        let session = chromeSession()
        diagnose("activate-start",["expected":tab.browserSession ?? "nil","actual":session])
        guard session == tab.browserSession else {
            completion(.failure(.init(kind: .closed, message: "\(browser.name) 已退出或重新启动，请重新检测页面列表。"))); return
        }
        queue.async {
            let result: Result<Void, BrowserFailure>
            do {
                var script = try self.script("chrome-activate.js")
                let identifiers = String(data: try JSONEncoder().encode(["windowID":tab.windowID,"tabID":tab.tabID]), encoding: .utf8)!
                script = script.replacingOccurrences(of: "TARGET_IDENTIFIERS", with: identifiers)
                let data = try self.execute(script, timeout: 8)
                let reply = try JSONDecoder().decode(ActivationReply.self, from: data)
                if reply.status == "selected", reply.selected == true { result = .success(()) }
                else if reply.status == "closed" { result = .failure(.closed) }
                else { result = .failure(self.failure(reply.status == "notRunning" ? -600 : reply.errorCode)) }
            } catch let error as BrowserFailure { result = .failure(error) }
            catch { result = .failure(self.failure(nil)) }
            DispatchQueue.main.async {
                if case let .failure(error) = result,error.kind == .permission { self.denied = true }
                completion(result)
            }
        }
    }

    func retryPermissions() { denied = false }
    private func script(_ name:String) throws -> String {
        try String(contentsOf:AppResources.url(name),encoding:.utf8).replacingOccurrences(of:"com.google.Chrome",with:browser.bundleID)
    }

    // stdout is drained concurrently, so large tab lists cannot fill a pipe and deadlock.
    // Metadata is never written to temporary files or application logs.
    private func execute(_ script: String, timeout: TimeInterval) throws -> Data {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        process.standardOutput = out; process.standardError = err
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        let readers = DispatchGroup(), lock = NSLock()
        var output = Data(), errors = Data()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); output = data; lock.unlock(); readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errors = data; lock.unlock(); readers.leave()
        }
        let timedOut = ended.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if ended.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        readers.wait()
        if timedOut { throw BrowserFailure(kind:.timeout,message:"\(browser.name) 暂时没有响应，请稍后重试。") }
        guard process.terminationStatus == 0 else {
            let text = String(data: errors, encoding: .utf8) ?? ""
            let code = [-1743, -1744, -1712, -600, -609, -1728, -1719].first { text.contains("\($0)") }
            throw failure(code)
        }
        return output
    }
}

final class DemoAdapter: BrowserAdapter {
    func scan(completion: @escaping (Result<BrowserSnapshot, BrowserFailure>) -> Void) {
        completion(.success(.init(status: "ok", tabs: DemoData.tabs, currentWindowID: "101", normalWindowCount: 3, excludedPrivateWindowCount: 0, skippedWindowCount: 0)))
    }
    func activate(_ tab: BrowserTab, completion: @escaping (Result<Void, BrowserFailure>) -> Void) {
        completion(.failure(.init(kind: .unknown, message: "这是演示数据。退出演示模式后才能切换真实 Chrome 页面。")))
    }
}
