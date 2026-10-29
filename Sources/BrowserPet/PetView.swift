import AppKit

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PetView: NSView {
    private let atlas = PetAtlas(imageURL:AppResources.url("pet-atlas.png"),layoutURL:AppResources.url("pet-atlas-frames.json"))
    private var timer: Timer?
    private var frameIndex = 0
    private var hover = false
    private var hoverUntil:TimeInterval = 0
    private var feedbackUntil:TimeInterval = 0
    private var lastState:PetAnimation = .idle
    private var windowObserver:NSObjectProtocol?
    private var motionObserver:NSObjectProtocol?
    private var dragging = false
    private var dragStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var lastX: CGFloat = 0
    private var tracking: NSTrackingArea?
    var baseState: PetAnimation = .idle {
        didSet {
            guard oldValue != baseState else { return }
            feedbackUntil = Date.timeIntervalSinceReferenceDate+Double(atlas.count(row:baseState.rawValue))*0.12
            updateAnimation();needsDisplay = true
        }
    }
    var interactionActive = false { didSet { if oldValue != interactionActive { updateAnimation() } } }
    private var dragState: PetAnimation = .runningRight
    var gazePoint: NSPoint? { didSet { if oldValue != gazePoint { needsDisplay = true } } }
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    var feedbackText: String? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "BrowserPet · 点击搜索，按住拖动，右键隐藏或设置"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("BrowserPet 桌宠，点击搜索已打开的浏览器页面")
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.updateAnimation() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    deinit {
        timer?.invalidate()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }
    private var effectiveState: PetAnimation { dragging ? dragState : hover && Date.timeIntervalSinceReferenceDate < hoverUntil ? .jumping : baseState }
    private var shouldAnimate:Bool {
        guard window?.isVisible == true,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        if dragging || (hover && Date.timeIntervalSinceReferenceDate < hoverUntil) { return true }
        guard interactionActive else { return false }
        if baseState == .running || baseState == .jumping || baseState == .runningLeft || baseState == .runningRight { return true }
        return baseState != .idle && Date.timeIntervalSinceReferenceDate < feedbackUntil
    }
    /// Idle has no animation timer. Hover and status feedback play once, then rest.
    private func updateAnimation() {
        let state = effectiveState
        if lastState != state { lastState = state;frameIndex = 0;needsDisplay = true }
        guard shouldAnimate else {
            timer?.invalidate();timer = nil
            if frameIndex != 0 { frameIndex = 0;needsDisplay = true }
            return
        }
        guard timer == nil else { return }
        let animationTimer = Timer(timeInterval:0.12,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.updateAnimation()
            guard self.timer != nil else { return }
            self.frameIndex += 1;self.needsDisplay = true
        }
        timer = animationTimer;RunLoop.main.add(animationTimer,forMode:.common)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver);self.windowObserver = nil }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main) { [weak self] _ in self?.updateAnimation() }
        }
        updateAnimation()
    }
    func visibilityChanged() { updateAnimation() }

    override func draw(_ dirtyRect: NSRect) {
        let state = effectiveState
        var row = state.rawValue, frame = frameIndex
        if state == .idle, let gazePoint, let window {
            let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
            let degrees = atan2(gazePoint.x-center.x, gazePoint.y-center.y) * 180 / .pi
            let direction = Int(((degrees + 360).truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
            row = 7 + direction/8; frame = direction % 8
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { frame = 0 }
        if let image = atlas.image(row: row, frame: frame) {
            let available = bounds.insetBy(dx: 4, dy: 5)
            let ratio = min(available.width/image.size.width, available.height/image.size.height)
            let size = NSSize(width: image.size.width*ratio, height: image.size.height*ratio)
            let rect = NSRect(x: bounds.midX-size.width/2, y: 4, width: size.width, height: size.height)
            image.draw(in: rect)
        } else {
            let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: nil) ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)
            image?.draw(in: bounds.insetBy(dx: 12, dy: 12))
        }
        if baseState == .waiting || baseState == .failed {
            let point = NSPoint(x: bounds.maxX-19, y: bounds.maxY-23)
            (baseState == .waiting ? NSColor.systemOrange : .systemRed).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x, y: point.y, width: 11, height: 11)).fill()
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hover = true;hoverUntil = Date.timeIntervalSinceReferenceDate+Double(atlas.count(row:PetAnimation.jumping.rawValue))*0.12
        frameIndex = 0;updateAnimation();needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hover = false;frameIndex = 0;updateAnimation();needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation; lastX = dragStart.x
        windowStart = window?.frame.origin ?? .zero; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation, dx = mouse.x-dragStart.x, dy = mouse.y-dragStart.y
        if !dragging, hypot(dx,dy) >= 4 { dragging = true; onDragStart?() }
        guard dragging, let window else { return }
        if mouse.x > lastX { dragState = .runningRight } else if mouse.x < lastX { dragState = .runningLeft }
        lastX = mouse.x
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? window.screen ?? NSScreen.main
        var origin = NSPoint(x: windowStart.x+dx, y: windowStart.y+dy)
        if let screen {
            let rect = screen.visibleFrame
            origin.x = min(max(origin.x, rect.minX), rect.maxX-window.frame.width)
            origin.y = min(max(origin.y, rect.minY), rect.maxY-window.frame.height)
        }
        window.setFrameOrigin(origin);updateAnimation();needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; onDragEnd?() } else { onClick?() }
        hoverUntil = 0;frameIndex = 0;updateAnimation();needsDisplay = true
    }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
