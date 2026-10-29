import AppKit
import Carbon
import ServiceManagement

final class SettingsController: NSObject {
    private let window: NSWindow
    private let petToggle = NSButton(checkboxWithTitle: "显示桌宠（空闲时静止）", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "登录时启动 BrowserPet", target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let keyChoice = NSPopUpButton()
    private var modifiers: [NSButton] = []
    private let feedback = NSTextField(wrappingLabelWithString: "")
    var onPetVisibility: ((Bool) -> Void)?
    var onShortcut: ((Shortcut) -> OSStatus)?
    var onHelp: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 510,height: 430),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        super.init()
        window.title = "BrowserPet 设置"; window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: content.topAnchor,constant: 24),stack.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 24),stack.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -24)])
        }
        let heading = NSTextField(labelWithString: "一个随手可用的找页入口")
        heading.font = .systemFont(ofSize: 17,weight: .semibold); stack.addArrangedSubview(heading)
        petToggle.target = self; petToggle.action = #selector(petChanged); stack.addArrangedSubview(petToggle)
        loginToggle.target = self; loginToggle.action = #selector(loginChanged); stack.addArrangedSubview(loginToggle)
        loginStatus.font = .systemFont(ofSize: 11); loginStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(loginStatus)
        let keyLabel = NSTextField(labelWithString: "唤出搜索快捷键")
        keyLabel.font = .systemFont(ofSize: 12,weight: .semibold); stack.addArrangedSubview(keyLabel)
        let keys = NSStackView(); keys.orientation = .horizontal; keys.spacing = 8
        for name in ["Control","Option","Shift","Command"] {
            let button = NSButton(checkboxWithTitle: name,target: nil,action: nil)
            modifiers.append(button); keys.addArrangedSubview(button)
        }
        keyChoice.addItems(withTitles: Shortcut.keys.map(\.0)); keys.addArrangedSubview(keyChoice)
        stack.addArrangedSubview(keys)
        let save = NSButton(title: "应用快捷键",target: self,action: #selector(saveShortcut)); save.bezelStyle = .rounded
        stack.addArrangedSubview(save)
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor
        stack.addArrangedSubview(feedback)
        let privacy = NSTextField(wrappingLabelWithString: "搜索索引在本机内存中处理，无痕默认排除。启用项目工作集后，所选/匹配页面的标题、网址、分组和使用时间保存在本机；不读取正文、不上传数据。空闲小猫静止，交互时短暂反馈。")
        privacy.font = .systemFont(ofSize: 11); privacy.textColor = .secondaryLabelColor
        stack.addArrangedSubview(privacy); privacy.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let help = NSButton(title: "查看 Chrome 授权说明",target: self,action: #selector(helpPressed)); help.bezelStyle = .rounded
        stack.addArrangedSubview(help)
        window.center()
    }
    func show(petVisible: Bool, shortcut: Shortcut) {
        petToggle.state = petVisible ? .on : .off
        for (index,flag) in [controlKey,optionKey,shiftKey,cmdKey].enumerated() {
            modifiers[index].state = shortcut.modifiers & UInt32(flag) != 0 ? .on : .off
        }
        keyChoice.selectItem(at: Shortcut.keys.firstIndex { $0.1 == shortcut.keyCode } ?? 0)
        refreshLoginStatus()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginToggle.state = .on; loginStatus.stringValue = "登录启动已启用。"
        case .requiresApproval: loginToggle.state = .mixed; loginStatus.stringValue = "等待系统批准，请在系统设置 → 通用 → 登录项中确认。"
        case .notRegistered: loginToggle.state = .off; loginStatus.stringValue = "登录启动尚未启用。移动或重新构建本地应用后可能需要重新授权。"
        case .notFound: loginToggle.state = .off; loginStatus.stringValue = "系统尚未找到登录项记录，可开启后重新检查。移动应用后可能需要重新设置。"
        @unknown default: loginToggle.state = .off; loginStatus.stringValue = "暂时无法确定登录项状态。"
        }
    }
    @objc private func petChanged() { onPetVisibility?(petToggle.state == .on) }
    @objc private func loginChanged() {
        do {
            if loginToggle.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus(); loginStatus.stringValue = "系统未完成登录项设置，请检查系统设置 → 通用 → 登录项。"
        }
    }
    @objc private func saveShortcut() {
        var flags: UInt32 = 0
        for (index,flag) in [controlKey,optionKey,shiftKey,cmdKey].enumerated() where modifiers[index].state == .on { flags |= UInt32(flag) }
        guard flags & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            feedback.stringValue = "请至少选择 Control、Option 或 Command。"; return
        }
        let choice = Shortcut(keyCode: Shortcut.keys[max(0,keyChoice.indexOfSelectedItem)].1,modifiers: flags)
        let result = onShortcut?(choice) ?? OSStatus(-1)
        if result == noErr { choice.save(); feedback.stringValue = "已应用：\(choice.label)" }
        else { feedback.stringValue = "快捷键注册失败（\(result)），原快捷键仍保留，请换一个组合。" }
    }
    @objc private func helpPressed() { onHelp?() }
}
