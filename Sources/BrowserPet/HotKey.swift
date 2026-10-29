import AppKit
import Carbon

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let initial = Shortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey))
    static let keys: [(String, UInt32)] = [("Space",49),("A",0),("B",11),("C",8),("D",2),("E",14),("F",3),("G",5),("H",4),("I",34),("J",38),("K",40),("L",37),("M",46),("N",45),("O",31),("P",35),("Q",12),("R",15),("S",1),("T",17),("U",32),("V",9),("W",13),("X",7),("Y",16),("Z",6)]
    var label: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + " " + (Self.keys.first { $0.1 == keyCode }?.0 ?? "Space")
    }
    static func saved() -> Shortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "shortcut.key") != nil else { return .initial }
        return .init(keyCode: UInt32(defaults.integer(forKey: "shortcut.key")), modifiers: UInt32(defaults.integer(forKey: "shortcut.modifiers")))
    }
    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: "shortcut.key")
        UserDefaults.standard.set(Int(modifiers), forKey: "shortcut.modifiers")
    }
}

final class HotKeyManager {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var serial: UInt32 = 1
    private(set) var current: Shortcut?
    private(set) var triggerCount = 0
    private(set) var handlerInstallStatus: OSStatus = noErr
    var onPressed: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        handlerInstallStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr, key.signature == 0x42504554 else { return OSStatus(eventNotHandledErr) }
            owner.triggerCount += 1
            owner.onPressed?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult func register(_ shortcut: Shortcut) -> OSStatus {
        guard handlerInstallStatus == noErr, handler != nil else { return handlerInstallStatus == noErr ? OSStatus(eventNotHandledErr) : handlerInstallStatus }
        if shortcut == current, reference != nil { return noErr }
        var next: EventHotKeyRef?
        serial += 1
        let id = EventHotKeyID(signature: 0x42504554, id: serial)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &next)
        guard result == noErr else { return result }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next; current = shortcut
        return result
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
