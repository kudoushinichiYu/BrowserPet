import Foundation

struct NativeGroupMessage: Codable {
    struct Group: Codable { var id: Int; var windowID: Int; var title: String; var color: String; var collapsed: Bool }
    struct Membership: Codable { var tabID: Int; var windowID: Int; var groupID: Int }
    var version: Int
    var type: String
    var instanceID: String
    var sequence: Int
    var windowIDs: [Int]
    var groups: [Group]
    var tabs: [Membership]
    func validate() throws {
        let colors: Set<String> = ["grey","blue","red","yellow","green","pink","purple","cyan","orange"]
        guard version == 1, ["snapshot","disconnect"].contains(type), UUID(uuidString: instanceID) != nil,
              sequence >= 0, groups.count <= 5000, tabs.count <= 50000,
              windowIDs.count <= 5000, Set(windowIDs).count == windowIDs.count, windowIDs.allSatisfy({ $0 > 0 }),
              Set(groups.map(\.id)).count == groups.count,
              Set(tabs.map(\.tabID)).count == tabs.count,
              groups.allSatisfy({ $0.id >= 0 && windowIDs.contains($0.windowID) && $0.title.utf8.count <= 4096 && colors.contains($0.color) }),
              tabs.allSatisfy({ $0.tabID > 0 && windowIDs.contains($0.windowID) && $0.groupID >= 0 }) else { throw GroupProtocolError.invalid }
    }
}

enum GroupProtocolError: Error { case invalid, disconnected }

struct NativeGroupRepository {
    private struct Owner { var sequence: Int; var receivedAt: Date; var tabs: [String:NativeTabGroup]; var windows: Set<Int> }
    private var owners: [String:Owner] = [:]
    mutating func apply(_ message: NativeGroupMessage, now: Date = Date()) throws {
        try message.validate()
        if let prior = owners[message.instanceID], prior.sequence >= message.sequence { return }
        if message.type == "disconnect" { owners.removeValue(forKey: message.instanceID); return }
        let groups = Dictionary(uniqueKeysWithValues: message.groups.map { ($0.id,$0) })
        var assignments: [String:NativeTabGroup] = [:]
        for member in message.tabs {
            guard let group = groups[member.groupID], group.windowID == member.windowID else { continue }
            let key = "chrome:\(member.windowID):\(member.tabID)"
            assignments[key] = NativeTabGroup(key: "\(message.instanceID):\(group.id)", title: group.title, color: group.color, collapsed: group.collapsed)
        }
        let windows = Set(message.windowIDs)
        // A restarted service worker gets a new token; overlapping windows supersede its old snapshot.
        let replaced = owners.filter { $0.key != message.instanceID && !$0.value.windows.isDisjoint(with: windows) }.map(\.key)
        for key in replaced { owners.removeValue(forKey: key) }
        owners[message.instanceID] = Owner(sequence: message.sequence, receivedAt: now, tabs: assignments, windows: windows)
    }
    mutating func snapshot(now: Date = Date()) -> (tabs: [String:NativeTabGroup], connected: Bool) {
        owners = owners.filter { now.timeIntervalSince($0.value.receivedAt) < 45 }
        return (owners.values.reduce(into: [:]) { $0.merge($1.tabs,uniquingKeysWith: { _,new in new }) }, !owners.isEmpty)
    }
    mutating func clear() { owners.removeAll() }
}
