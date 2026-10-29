import AppKit

/// A single-line title that reveals its clipped end only while the pointer rests over it.
final class HoverTitleView: NSView {
    private var title = ""
    private var tracking: NSTrackingArea?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var hovered = false
    private var startedAt: TimeInterval = 0
    private var offset: CGFloat = 0
    private let font = NSFont.systemFont(ofSize:12.5,weight:.medium)
    private var fullText: NSAttributedString {
        NSAttributedString(string:title,attributes:[.font:font,.foregroundColor:NSColor.labelColor])
    }
    private var overflow: CGFloat { max(0,ceil(fullText.size().width)-bounds.width) }

    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate(); pending?.cancel() }

    func show(_ value:String) {
        let text = value.components(separatedBy:.newlines).joined(separator:" ")
        guard text != title else { return }
        stop(); title = text; setAccessibilityLabel(value); needsDisplay = true
        toolTip = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? value : nil
        if hovered { begin() }
    }
    // Keep native hit testing for tracking; forward presses to the owning table cell.
    override func mouseDown(with event:NSEvent) { superview?.mouseDown(with:event) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect,.enabledDuringMouseDrag],owner:self,userInfo:nil)
        addTrackingArea(area); tracking = area
    }
    func setHovered(_ value:Bool) {
        guard hovered != value else { return }
        hovered = value
        if value { begin() } else { stop() }
    }
    override func mouseEntered(with event:NSEvent) { setHovered(true) }
    override func mouseExited(with event:NSEvent) { setHovered(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false; stop() }
    }
    override func viewWillMove(toSuperview newSuperview:NSView?) {
        if newSuperview == nil { hovered = false; stop() }
        super.viewWillMove(toSuperview:newSuperview)
    }
    private func begin() {
        stop()
        guard overflow > 1,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self,self.hovered,self.window?.isVisible == true else { return }
            self.startedAt = Date.timeIntervalSinceReferenceDate
            let timer = Timer(timeInterval:1.0/30,repeats:true) { [weak self] _ in self?.tick() }
            self.timer = timer; RunLoop.main.add(timer,forMode:.common)
            self.needsDisplay = true
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.55,execute:work)
    }
    private func stop() {
        pending?.cancel(); pending = nil; timer?.invalidate(); timer = nil
        offset = 0; needsDisplay = true
    }
    private func tick() {
        guard hovered,window?.isVisible == true,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { stop(); return }
        let distance = overflow
        guard distance > 1 else { stop(); return }
        let travel = Double(distance)/38
        let phase = (Date.timeIntervalSinceReferenceDate-startedAt).truncatingRemainder(dividingBy:2*travel+1.5)
        if phase < travel { offset = CGFloat(phase/travel)*distance }
        else if phase < travel+0.9 { offset = distance }
        else if phase < 2*travel+0.9 { offset = CGFloat(1-(phase-travel-0.9)/travel)*distance }
        else { offset = 0 }
        needsDisplay = true
    }
    override func draw(_ dirtyRect:NSRect) {
        NSGraphicsContext.saveGraphicsState(); bounds.clip()
        let text = fullText
        let y = floor((bounds.height-text.size().height)/2)
        if timer != nil {
            text.draw(at:NSPoint(x:-offset,y:y))
        } else {
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string:title,attributes:[.font:font,.foregroundColor:NSColor.labelColor,.paragraphStyle:style])
                .draw(in:NSRect(x:0,y:y,width:bounds.width,height:ceil(text.size().height)))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
