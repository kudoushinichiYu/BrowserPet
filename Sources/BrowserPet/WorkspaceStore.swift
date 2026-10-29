import Foundation
import CryptoKit
import Darwin

enum WorkspaceError:Error,LocalizedError {
    case invalid,missing,empty,writeFailed
    var errorDescription:String? {
        switch self {
        case .invalid:return "工作集数据格式不正确，已保留原文件，请先检查或备份。"
        case .missing:return "请先选择或新建一个项目。"
        case .empty:return "没有可保存的普通网页；目前支持 HTTP/HTTPS 链接。"
        case .writeFailed:return "未能保存工作集，已停止关闭页面。请检查本机存储和写入权限。"
        }
    }
}
struct PageUsage:Codable,Equatable {
    var firstSeen:Date
    var lastSeen:Date
    var lastUsed:Date?
    var observedTabs:Set<String>? = nil
    var referenceDate:Date { max(lastUsed ?? firstSeen,firstSeen) }
}
struct SavedPage:Codable,Equatable,Identifiable {
    var id:String = UUID().uuidString
    var tab:BrowserTab
    var savedAt:Date
    var lastUsed:Date?
}
struct PageProject:Codable,Equatable,Identifiable {
    var id:String = UUID().uuidString
    var name:String
    var keywords:[String]
    var automatic:Bool
    var pages:[SavedPage] = []
    var updatedAt:Date
    func matches(_ tab:BrowserTab) -> Bool {
        if pages.contains(where:{ $0.tab.browser == tab.browser && $0.tab.url == tab.url }) { return true }
        let haystack = SearchEngine.normalized([tab.title,tab.url,tab.nativeGroup?.title ?? ""].joined(separator:" "))
        return keywords.contains { !($0.isEmpty) && haystack.contains(SearchEngine.normalized($0)) }
    }
}
enum CleanupRule:Int { case unused,unrelated,both }

final class WorkspaceStore {
    struct State:Codable {
        var version = 1
        var projects:[PageProject] = []
        var usage:[String:PageUsage] = [:]
    }
    static var defaultRoot:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("BrowserPet/Workspaces",isDirectory:true)
    }
    let root:URL
    private(set) var state:State
    var projects:[PageProject] { state.projects }
    init(root:URL = WorkspaceStore.defaultRoot) throws {
        self.root = root
        let file = root.appendingPathComponent("workspaces.json")
        if FileManager.default.fileExists(atPath:file.path) {
            guard let value = try? JSONDecoder().decode(State.self,from:Data(contentsOf:file)),value.version == 1,
                  value.projects.count <= 1000,Set(value.projects.map(\.id)).count == value.projects.count,
                  value.projects.allSatisfy({ !$0.name.isEmpty && $0.pages.count <= 20000 && $0.pages.allSatisfy { Self.canSave($0.tab) } })
            else { throw WorkspaceError.invalid }
            state = value
        } else { state = State() }
    }
    static func canSave(_ tab:BrowserTab) -> Bool {
        guard BrowserKind(rawValue:tab.browser) != nil,let url = URLComponents(string:tab.url),
              ["https","http"].contains(url.scheme?.lowercased() ?? ""),url.host?.isEmpty == false,
              url.user == nil,url.password == nil,tab.url.utf8.count <= 32768 else { return false }
        return true
    }
    static func usageKey(_ tab:BrowserTab) -> String {
        SHA256.hash(data:Data((tab.browser+"\u{0}"+tab.url).utf8)).map { String(format:"%02x",$0) }.joined()
    }
    func usage(for tab:BrowserTab) -> PageUsage? { state.usage[Self.usageKey(tab)] }
    private func commit(_ next:State) throws {
        guard next.projects.count <= 1000,next.projects.allSatisfy({ $0.pages.count <= 20000 }) else { throw WorkspaceError.invalid }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
            let file = root.appendingPathComponent("workspaces.json")
            let data = try JSONEncoder().encode(next)
            // Atomic replacement inherits the restricted parent directory; file is owner-only.
            let temp = root.appendingPathComponent(".write-"+UUID().uuidString)
            defer { try? fm.removeItem(at:temp) }
            guard fm.createFile(atPath:temp.path,contents:data,attributes:[.posixPermissions:0o600]) else { throw WorkspaceError.writeFailed }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temp.path)
            let handle = try FileHandle(forWritingTo:temp)
            try handle.synchronize();try handle.close()
            // POSIX rename atomically replaces an existing file without a world-readable interval.
            guard rename(temp.path,file.path) == 0 else { throw WorkspaceError.writeFailed }
        } catch { throw WorkspaceError.writeFailed }
        state = next
    }
    @discardableResult func create(name:String,keywords:[String] = [],automatic:Bool = false,now:Date = Date()) throws -> String {
        let title = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty,title.count <= 100 else { throw WorkspaceError.invalid }
        var next = state
        let project = PageProject(name:title,keywords:keywords.filter { !$0.isEmpty },automatic:automatic,updatedAt:now)
        next.projects.append(project);try commit(next);return project.id
    }
    func configure(id:String,keywords:[String],automatic:Bool) throws {
        var next = state
        guard let index = next.projects.firstIndex(where:{ $0.id == id }) else { throw WorkspaceError.missing }
        next.projects[index].keywords = keywords.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        next.projects[index].automatic = automatic;try commit(next)
    }
    func removeProject(id:String) throws {
        var next = state;next.projects.removeAll { $0.id == id }
        if next.projects.isEmpty { next.usage.removeAll() }
        try commit(next)
    }
    func removePages(projectID:String,ids:Set<String>) throws {
        var next = state
        guard let index = next.projects.firstIndex(where:{ $0.id == projectID }) else { throw WorkspaceError.missing }
        next.projects[index].pages.removeAll { ids.contains($0.id) };try commit(next)
    }
    private static func insert(_ tabs:[BrowserTab],into project:inout PageProject,usage:[String:PageUsage],now:Date,reuseURL:Bool = false) {
        var changed = false
        for tab in tabs where canSave(tab) {
            let used = usage[usageKey(tab)]?.lastUsed
            if let index = project.pages.firstIndex(where:{ $0.tab.browser == tab.browser && $0.tab.url == tab.url && (reuseURL || $0.tab.windowID == tab.windowID) }) {
                var current = tab
                current.nativeGroup = tab.nativeGroup ?? project.pages[index].tab.nativeGroup
                if project.pages[index].tab != current || project.pages[index].lastUsed != used { changed = true }
                project.pages[index].tab = current;project.pages[index].lastUsed = used
            } else { project.pages.append(SavedPage(tab:tab,savedAt:now,lastUsed:used));changed = true }
        }
        if changed { project.updatedAt = now }
    }
    func save(_ tabs:[BrowserTab],projectID:String,now:Date = Date()) throws {
        guard tabs.contains(where:Self.canSave) else { throw WorkspaceError.empty }
        var next = state
        guard let index = next.projects.firstIndex(where:{ $0.id == projectID }) else { throw WorkspaceError.missing }
        Self.insert(tabs,into:&next.projects[index],usage:next.usage,now:now);try commit(next)
    }
    func observe(_ tabs:[BrowserTab],foregroundBrowser:String?,now:Date = Date()) throws {
        guard !projects.isEmpty else { return }
        var next = state
        let grouped = Dictionary(grouping:tabs.filter(Self.canSave),by:Self.usageKey)
        for (key,values) in grouped {
            var record = next.usage[key] ?? PageUsage(firstSeen:now,lastSeen:now,lastUsed:nil)
            let identities = Set(values.map { tab in SHA256.hash(data:Data(tab.id.utf8)).map { String(format:"%02x",$0) }.joined() })
            if let observed = record.observedTabs,!identities.isSubset(of:observed) { record.firstSeen = now }
            record.observedTabs = identities
            if now.timeIntervalSince(record.lastSeen) >= 60 { record.lastSeen = now }
            if values.contains(where:{ $0.isActive && $0.browser == foregroundBrowser }) && (record.lastUsed == nil || now.timeIntervalSince(record.lastUsed!) >= 60) { record.lastUsed = now }
            next.usage[key] = record
        }
        // Prune timestamps for URLs absent for 90 days; never prune saved project pages.
        next.usage = next.usage.filter { now.timeIntervalSince($0.value.lastSeen) < 90*86400 }
        for index in next.projects.indices where next.projects[index].automatic {
            let matches = tabs.filter { next.projects[index].matches($0) && Self.canSave($0) }
            if !matches.isEmpty { Self.insert(matches,into:&next.projects[index],usage:next.usage,now:now,reuseURL:true) }
        }
        for index in next.projects.indices {
            for page in next.projects[index].pages.indices {
                let key = Self.usageKey(next.projects[index].pages[page].tab)
                if let used = next.usage[key]?.lastUsed { next.projects[index].pages[page].lastUsed = used }
            }
        }
        // Compare encoded state so idle polling does not rewrite unchanged storage.
        let encoder = JSONEncoder();encoder.outputFormatting = .sortedKeys
        if try encoder.encode(next) != encoder.encode(state) { try commit(next) }
    }
    func candidates(_ tabs:[BrowserTab],days:Int = 3,rule:CleanupRule = .unused,projectID:String?,now:Date = Date()) -> [BrowserTab] {
        let project = projects.first { $0.id == projectID }
        return tabs.filter { tab in
            guard Self.canSave(tab),!tab.isActive,tab.pinned != true else { return false }
            let stale = usage(for:tab).map { now.timeIntervalSince($0.referenceDate) >= Double(days)*86400 } ?? false
            let unrelated = project.map { !$0.matches(tab) } ?? false
            switch rule { case .unused:return stale;case .unrelated:return unrelated;case .both:return stale && unrelated }
        }
    }
}
