import Foundation

enum BrowserKind: String, CaseIterable {
    case chrome, safari, edge
    var name:String { switch self { case .chrome:return "Chrome";case .safari:return "Safari";case .edge:return "Edge" } }
    var bundleID:String { switch self { case .chrome:return "com.google.Chrome";case .safari:return "com.apple.Safari";case .edge:return "com.microsoft.edgemac" } }
}

struct BrowserTab: Codable, Equatable, Identifiable {
    var browser: String = "chrome"
    var windowID: String
    var tabID: String
    var title: String
    var url: String
    var windowTitle: String
    var windowNumber: Int
    var isActive: Bool
    var browserSession: String? = nil
    var nativeGroup: NativeTabGroup? = nil
    var id: String { "\(browser):\(windowID):\(tabID)" }
    var windowKey:String { "\(browser):\(windowID)" }
    var browserName:String { BrowserKind(rawValue:browser)?.name ?? browser }
    var domain: String {
        guard let parsed = URL(string: url) else { return "其他页面" }
        if let host = parsed.host, !host.isEmpty { return host.lowercased() }
        if let scheme = parsed.scheme { return scheme == "file" ? "本地文件" : "\(scheme)://" }
        return "其他页面"
    }
    var displayTitle: String { title.isEmpty ? (url.isEmpty ? "未命名页面" : url) : title }
    var sourceLabel: String {
        let name = windowTitle.isEmpty ? "" : " · \(windowTitle)"
        return "窗口 \(windowNumber)\(name)"
    }
}

struct NativeTabGroup: Codable, Equatable {
    var key: String
    var title: String
    var color: String
    var collapsed: Bool
}

enum GroupingMode: Int, CaseIterable {
    case automatic, site, window
    var label: String { ["原组优先", "网站", "窗口"][rawValue] }
}

struct TabGroup: Equatable {
    var domain: String
    var tabs: [BrowserTab]
    var key: String = ""
    var color: String? = nil
    var collapsed: Bool = false
    var isNative: Bool = false
}

enum SearchEngine {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func purpose(_ tab: BrowserTab) -> (key: String, title: String) {
        let host = tab.domain
        func at(_ roots: [String]) -> Bool { roots.contains { host == $0 || host.hasSuffix("."+$0) } }
        if at(["arxiv.org", "ar5iv.org", "openreview.net", "aclanthology.org", "semanticscholar.org"]) { return ("papers", "论文与研究") }
        if at(["github.com", "gitlab.com", "stackoverflow.com", "developer.apple.com", "developer.chrome.com", "developers.openai.com", "docs.python.org", "swift.org"]) { return ("development", "代码与开发") }
        if at(["chatgpt.com", "chat.openai.com", "gemini.google.com", "chat.deepseek.com", "claude.ai", "doubao.com"]) { return ("ai", "AI 工具") }
        if at(["notion.so", "notion.site", "docs.google.com", "feishu.cn", "yuque.com", "confluence.atlassian.com"]) { return ("documents", "文档与协作") }
        let retail: Set<String> = ["jd.com", "www.jd.com", "item.jd.com", "search.jd.com", "mall.jd.com", "shop.jd.com", "passport.jd.com"]
        if (host.hasSuffix(".jd.com") && !retail.contains(host)) || at(["slack.com", "linear.app", "atlassian.net"]) { return ("work", "工作平台") }
        return ("other", "其他网页")
    }

    static func site(_ tab: BrowserTab) -> String {
        let host = tab.domain
        if host == "arxiv.org" || host.hasSuffix(".arxiv.org") || host == "ar5iv.org" { return "arXiv" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func groups(tabs: [BrowserTab], query: String, currentWindowID: String?, mode: GroupingMode = .site) -> [TabGroup] {
        let words = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func rank(_ tab: BrowserTab) -> Int? {
            guard !words.isEmpty else { return 0 }
            let title = normalized(tab.displayTitle), url = normalized(tab.url)
            let browser = normalized(tab.browserName)
            guard words.allSatisfy({ title.contains($0) || url.contains($0) || browser.contains($0) }) else { return nil }
            if title == words.joined(separator: " ") || title == words.joined() { return 0 }
            if words.allSatisfy({ title.contains($0) }) { return 1 }
            if words.allSatisfy({ url.contains($0) }) { return 2 }
            return 3
        }
        let ranked = tabs.compactMap { tab -> (BrowserTab, Int)? in
            guard let score = rank(tab) else { return nil }; return (tab, score)
        }
        func groupKey(_ tab: BrowserTab) -> String {
            switch mode {
            case .automatic:
                if let group = tab.nativeGroup { return "native:"+group.key }
                return "purpose:"+purpose(tab).key
            case .site: return "site:"+site(tab)
            case .window: return "window:\(tab.browser):\(tab.windowID)"
            }
        }
        let buckets = Dictionary(grouping: ranked, by: { groupKey($0.0) })
        func precedes(_ a: (BrowserTab, Int), _ b: (BrowserTab, Int)) -> Bool {
            if a.1 != b.1 { return a.1 < b.1 }
            func current(_ tab:BrowserTab) -> Bool { tab.windowKey == currentWindowID || (tab.browser == "chrome" && tab.windowID == currentWindowID) }
            let ac = current(a.0), bc = current(b.0)
            if ac != bc { return ac }
            if a.0.isActive != b.0.isActive { return a.0.isActive }
            if a.0.windowNumber != b.0.windowNumber { return a.0.windowNumber < b.0.windowNumber }
            let cmp = a.0.displayTitle.localizedStandardCompare(b.0.displayTitle)
            return cmp == .orderedSame ? a.0.id < b.0.id : cmp == .orderedAscending
        }
        let sorted = buckets.map { domain, entries in (domain, entries.sorted(by: precedes)) }
            .sorted { a, b in
                guard let firstA = a.1.first, let firstB = b.1.first else { return a.0 < b.0 }
                if firstA.1 != firstB.1 { return firstA.1 < firstB.1 }
                if mode == .automatic, a.0.hasPrefix("native:") != b.0.hasPrefix("native:") { return a.0.hasPrefix("native:") }
                if precedes(firstA, firstB) { return true }
                if precedes(firstB, firstA) { return false }
                return a.0 < b.0
            }
        return sorted.map { key, entries in
            let pages = entries.map(\.0), first = pages[0]
            if mode == .automatic, let native = first.nativeGroup {
                return TabGroup(domain: native.title.isEmpty ? "未命名标签组" : native.title, tabs: pages, key: key, color: native.color, collapsed: native.collapsed, isNative: true)
            }
            let title = mode == .automatic ? purpose(first).title : mode == .window ? "\(first.browserName) · 窗口 \(first.windowNumber)" : site(first)
            return TabGroup(domain: title, tabs: pages, key: key)
        }
    }
}

struct BrowserSnapshot: Codable {
    var status: String
    var tabs: [BrowserTab]
    var currentWindowID: String?
    var normalWindowCount: Int
    var excludedPrivateWindowCount: Int
    var skippedWindowCount: Int
    var errorCode: Int?
    var notices:[BrowserNotice]? = nil
}

struct BrowserNotice: Codable {
    var browser:String
    var message:String
    var permission:Bool = false
}

struct ActivationReply: Codable {
    var status: String
    var selected: Bool?
    var errorCode: Int?
}

struct BrowserFailure: Error {
    enum Kind { case permission, notRunning, notInstalled, timeout, closed, partial, connection, unknown }
    var kind: Kind
    var message: String
    static let denied = BrowserFailure(kind: .permission, message: "需要 Chrome 自动化权限。请在系统设置中允许 BrowserPet 控制 Google Chrome，然后重新检测。")
    static let timeout = BrowserFailure(kind: .timeout, message: "Chrome 暂时没有响应，请稍后重试。搜索内容已保留。")
    static let closed = BrowserFailure(kind: .closed, message: "页面或窗口已关闭，请重新选择。")
}

enum PetAnimation: Int, CaseIterable {
    case idle = 0, runningRight, runningLeft, jumping, running, waiting, failed
}

struct BrowserSessionIdentity {
    private var pid: Int32?
    private(set) var token = UUID().uuidString
    mutating func observe(_ observedPID: Int32?) -> String {
        guard let observedPID else { return token }
        if let previous = pid, previous != observedPID { token = UUID().uuidString }
        pid = observedPID
        return token
    }
    mutating func invalidate() { token = UUID().uuidString; pid = nil }
}

enum DemoData {
    static let tabs: [BrowserTab] = [
        .init(windowID: "101", tabID: "1", title: "项目周报", url: "https://docs.example.com/project/weekly", windowTitle: "工作资料", windowNumber: 1, isActive: true),
        .init(windowID: "102", tabID: "2", title: "项目周报 · 评审版", url: "https://docs.example.com/project/review", windowTitle: "评审窗口", windowNumber: 2, isActive: false),
        .init(windowID: "101", tabID: "3", title: "产品方案", url: "https://docs.example.com/product", windowTitle: "工作资料", windowNumber: 1, isActive: false),
        .init(windowID: "103", tabID: "4", title: "BrowserPet · GitHub", url: "https://github.com/example/BrowserPet", windowTitle: "开发", windowNumber: 3, isActive: false),
        .init(windowID: "103", tabID: "5", title: "Apple Developer Documentation", url: "https://developer.apple.com/documentation/appkit", windowTitle: "开发", windowNumber: 3, isActive: false),
        .init(windowID: "102", tabID: "6", title: "项目周报", url: "https://docs.example.com/project/weekly", windowTitle: "评审窗口", windowNumber: 2, isActive: false)
    ]
}
