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
    var pinned:Bool? = nil
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
    private struct MatchRank:Comparable {
        var tier:Int
        var cost:Int = 0
        static func < (a:Self,b:Self) -> Bool { a.tier == b.tier ? a.cost < b.cost : a.tier < b.tier }
    }
    private final class Phonetics:NSObject {
        let full:String,initials:String
        init(_ title:String) {
            let romanized = (title.applyingTransform(.toLatin,reverse:false) ?? title)
                .folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            let words = romanized.split { !$0.isLetter && !$0.isNumber }
            full = words.joined();initials = String(words.compactMap(\.first))
        }
    }
    private static let phonetics:NSCache<NSString,Phonetics> = {
        let cache = NSCache<NSString,Phonetics>();cache.countLimit = 4096;cache.totalCostLimit = 4*1024*1024;return cache
    }()
    private static func phonetic(_ title:String) -> Phonetics? {
        guard title.unicodeScalars.contains(where:{ (0x3400...0x9fff).contains($0.value) || (0x20000...0x323af).contains($0.value) }) else { return nil }
        let key = title as NSString
        if let cached = phonetics.object(forKey:key) { return cached }
        let result = Phonetics(String(title.prefix(1024)))
        phonetics.setObject(result,forKey:key,cost:(title.utf8.count+result.full.utf8.count+result.initials.utf8.count)*2)
        return result
    }
    /// A bounded ordered-character match; short Latin abbreviations must start a word.
    private static func subsequenceCost(_ query:String,in source:String,wordStart:Bool = true) -> Int? {
        let needle = Array(query),text = Array(source.prefix(1024))
        guard needle.count >= 2,needle.count <= 48,needle.allSatisfy({ $0.isLetter || $0.isNumber }),needle.contains(where:{$0.isLetter}),text.count >= needle.count else { return nil }
        let latin = query.utf8.allSatisfy { $0 < 128 }
        let span = latin ? (needle.count == 2 ? 4 : needle.count == 3 ? 8 : needle.count*3) : needle.count*2+2
        var best:Int?
        for start in text.indices where text[start] == needle[0] {
            if wordStart && latin && needle.count <= 3 && start > 0 && (text[start-1].isLetter || text[start-1].isNumber) { continue }
            var matched = 1,end = start
            while matched < needle.count && end+1 < text.count && end+1 < start+span {
                end += 1
                if text[end] == needle[matched] { matched += 1 }
            }
            if matched == needle.count {
                let cost = (end-start+1-needle.count)*2+min(start,24)
                if best == nil || cost < best! { best = cost }
            }
        }
        return best
    }
    /// Banded optimal-string-alignment distance, including adjacent transpositions.
    private static func typoCost(_ query:String,_ candidate:String,limit:Int) -> Int? {
        let a = Array(query.utf8),b = Array(candidate.utf8),infinity = limit+1
        guard abs(a.count-b.count) <= limit,!a.isEmpty,!b.isEmpty,b.count <= 64 else { return nil }
        var previous = Array(0...b.count),beforePrevious = previous
        for i in 1...a.count {
            var current = [Int](repeating:infinity,count:b.count+1);current[0] = i
            let lower = max(1,i-limit),upper = min(b.count,i+limit)
            guard lower <= upper else { return nil }
            for j in lower...upper {
                current[j] = min(previous[j]+1,current[j-1]+1,previous[j-1]+(a[i-1] == b[j-1] ? 0 : 1))
                if i > 1,j > 1,a[i-1] == b[j-2],a[i-2] == b[j-1] { current[j] = min(current[j],beforePrevious[j-2]+1) }
            }
            if current.min()! > limit { return nil }
            beforePrevious = previous;previous = current
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }
    private static func fuzzy(_ word:String,title:String,url:String,browser:String) -> MatchRank? {
        var best:MatchRank?
        func consider(_ rank:MatchRank) { if best == nil || rank < best! { best = rank } }
        if let cost = subsequenceCost(word,in:title) { consider(.init(tier:4,cost:cost+12)) }
        let titleWords = title.split { !$0.isLetter && !$0.isNumber }.prefix(100).map(String.init)
        let initials = String(titleWords.compactMap(\.first))
        if word.count >= 2,word.count <= 48,initials.contains(word) { consider(.init(tier:4,cost:10)) }
        let ascii = word.utf8.allSatisfy { $0 < 128 }
        if ascii,word.count >= 2,word.count <= 48,word.contains(where:{$0.isLetter}),let pinyin = phonetic(title) {
            if pinyin.full.contains(word) { consider(.init(tier:4,cost:6)) }
            if pinyin.initials.contains(word) { consider(.init(tier:4,cost:8)) }
            if let cost = subsequenceCost(word,in:pinyin.initials,wordStart:false) { consider(.init(tier:4,cost:cost+16)) }
        }
        if best != nil { return best }
        // Do not fuzz numeric IDs, one-character input or arbitrary URL query strings.
        guard ascii,word.utf8.count >= 4,word.utf8.count <= 48,word.contains(where:{$0.isLetter}),
              word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        let limit = word.count >= 8 ? 2 : 1
        let host = URLComponents(string:url)?.host ?? ""
        let candidates = titleWords+host.split(separator:".").map(String.init)+[host,browser]
        for candidate in candidates where candidate.utf8.allSatisfy({$0 < 128}) {
            if let cost = typoCost(word,candidate,limit:limit) { consider(.init(tier:5,cost:cost*10)) }
        }
        return best
    }
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
        func rank(_ tab: BrowserTab) -> MatchRank? {
            guard !words.isEmpty else { return .init(tier:0) }
            let title = normalized(tab.displayTitle), url = normalized(tab.url)
            let browser = normalized(tab.browserName)
            if words.allSatisfy({ title.contains($0) || url.contains($0) || browser.contains($0) }) {
                if title == words.joined(separator: " ") || title == words.joined() { return .init(tier:0) }
                if words.allSatisfy({ title.contains($0) }) { return .init(tier:1) }
                if words.allSatisfy({ url.contains($0) }) { return .init(tier:2) }
                return .init(tier:3)
            }
            var result = MatchRank(tier:4)
            for word in words where !title.contains(word) && !url.contains(word) && !browser.contains(word) {
                guard let match = fuzzy(word,title:title,url:url,browser:browser) else { return nil }
                result.tier = max(result.tier,match.tier);result.cost += match.cost
            }
            return result
        }
        let ranked = tabs.compactMap { tab -> (BrowserTab, MatchRank)? in
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
        func precedes(_ a: (BrowserTab, MatchRank), _ b: (BrowserTab, MatchRank)) -> Bool {
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
