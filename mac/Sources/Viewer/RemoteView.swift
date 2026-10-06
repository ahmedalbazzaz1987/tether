import AppKit

/// Draws the remote screen and turns local mouse/keyboard into protocol events.
final class RemoteView: NSView {
    weak var session: ViewerSession?
    var swapCmdCtrl: () -> Bool = { true }
    var onFirstFrame: () -> Void = {}

    private var ctx: CGContext?
    private var remoteW = 0, remoteH = 0
    private var gotFrame = false
    private var pressed = Set<UInt16>()
    private var buttons = Set<UInt8>()
    private var scrollAccX: CGFloat = 0, scrollAccY: CGFloat = 0
    private var lastMove: TimeInterval = 0
    private var lastPos: (UInt16, UInt16) = (32768, 32768)
    private var tracking: NSTrackingArea?
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: drawing

    func apply(_ f: DecodedFrame) {
        if f.width != remoteW || f.height != remoteH || ctx == nil {
            remoteW = f.width; remoteH = f.height
            ctx = CGContext(data: nil, width: max(f.width, 1), height: max(f.height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.setFillColor(NSColor.black.cgColor)
            ctx?.fill(CGRect(x: 0, y: 0, width: f.width, height: f.height))
            ctx?.interpolationQuality = .none
        }
        guard let c = ctx else { return }
        for r in f.rects {
            let ih = r.image.height
            c.draw(r.image, in: CGRect(x: r.x, y: remoteH - r.y - ih, width: r.image.width, height: ih))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = c.makeImage()
        CATransaction.commit()
        session?.ack(f.seq)
        if !gotFrame { gotFrame = true; onFirstFrame() }
    }

    func reset() {
        gotFrame = false
        ctx = nil
        layer?.contents = nil
    }

    /// The rectangle (in view coordinates) the remote image occupies (aspect fit).
    private var imageRect: CGRect {
        guard remoteW > 0, remoteH > 0 else { return bounds }
        let s = min(bounds.width / CGFloat(remoteW), bounds.height / CGFloat(remoteH))
        let w = CGFloat(remoteW) * s, h = CGFloat(remoteH) * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func norm(_ e: NSEvent) -> (UInt16, UInt16) {
        let p = convert(e.locationInWindow, from: nil)
        let r = imageRect
        let nx = min(max((p.x - r.minX) / max(r.width, 1), 0), 1)
        let ny = min(max((p.y - r.minY) / max(r.height, 1), 0), 1)
        return (UInt16(nx * 65535), UInt16(ny * 65535))
    }

    // MARK: mouse

    private func sendMouse(_ kind: MouseKind, _ e: NSEvent, button: UInt8 = 0, dx: Int16 = 0, dy: Int16 = 0) {
        let (x, y) = norm(e)
        lastPos = (x, y)
        session?.mouse(MouseEvent(kind: kind, button: button, x: x, y: y, dx: dx, dy: dy))
    }

    private func move(_ e: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMove < 0.010 { return }
        lastMove = now
        sendMouse(.move, e)
    }

    override func mouseMoved(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
    override func rightMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseDragged(with e: NSEvent) { move(e) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        buttons.insert(0)
        sendMouse(.down, e, button: 0)
    }
    override func mouseUp(with e: NSEvent) { buttons.remove(0); sendMouse(.up, e, button: 0) }
    override func rightMouseDown(with e: NSEvent) { buttons.insert(1); sendMouse(.down, e, button: 1) }
    override func rightMouseUp(with e: NSEvent) { buttons.remove(1); sendMouse(.up, e, button: 1) }
    override func otherMouseDown(with e: NSEvent) { buttons.insert(2); sendMouse(.down, e, button: 2) }
    override func otherMouseUp(with e: NSEvent) { buttons.remove(2); sendMouse(.up, e, button: 2) }

    override func scrollWheel(with e: NSEvent) {
        let f: CGFloat = e.hasPreciseScrollingDeltas ? 3 : 120
        scrollAccY += e.scrollingDeltaY * f
        scrollAccX += -e.scrollingDeltaX * f
        let dy = Int16(max(min(scrollAccY.rounded(.towardZero), 32000), -32000))
        let dx = Int16(max(min(scrollAccX.rounded(.towardZero), 32000), -32000))
        if dx == 0 && dy == 0 { return }
        scrollAccY -= CGFloat(dy); scrollAccX -= CGFloat(dx)
        sendMouse(.wheel, e, dx: dx, dy: dy)
    }

    // MARK: keyboard

    private func mapHID(_ keyCode: UInt16) -> UInt16? {
        guard var h = Keys.macToHID[keyCode] else { return nil }
        if swapCmdCtrl() {
            switch h {
            case 0xE3: h = 0xE0
            case 0xE7: h = 0xE4
            case 0xE0: h = 0xE3
            case 0xE4: h = 0xE7
            default: break
            }
        }
        return h
    }

    private func sendKey(_ hid: UInt16, _ down: Bool) {
        if down { pressed.insert(hid) } else { pressed.remove(hid) }
        session?.key(KeyEvent(down: down, hid: hid))
    }

    override func keyDown(with e: NSEvent) {
        guard let h = mapHID(e.keyCode) else { return }
        sendKey(h, true)
    }

    override func keyUp(with e: NSEvent) {
        guard let h = mapHID(e.keyCode) else { return }
        if pressed.contains(h) { sendKey(h, false) }
    }

    // Cmd-shortcuts would otherwise reach the app's menu (e.g. ⌘Q). Send them to the remote instead.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown else { return super.performKeyEquivalent(with: e) }
        keyDown(with: e)
        return true
    }

    override func flagsChanged(with e: NSEvent) {
        let code = e.keyCode
        guard let h = mapHID(code) else { return }
        let flag: NSEvent.ModifierFlags
        switch code {
        case 0x37, 0x36: flag = .command
        case 0x38, 0x3C: flag = .shift
        case 0x3A, 0x3D: flag = .option
        case 0x3B, 0x3E: flag = .control
        case 0x39:
            sendKey(h, true); sendKey(h, false) // caps lock: one tap per change
            return
        default: return
        }
        let down = e.modifierFlags.contains(flag) && !pressed.contains(h)
        sendKey(h, down)
        // macOS sends no keyUp for keys released while ⌘ is held: release them with ⌘.
        if !down && flag == .command {
            for k in pressed where !Keys.modifierHIDs.contains(k) { sendKey(k, false) }
        }
    }

    func releaseAll() {
        for k in pressed { session?.key(KeyEvent(down: false, hid: k)) }
        pressed.removeAll()
        for b in buttons { session?.mouse(MouseEvent(kind: .up, button: b, x: lastPos.0, y: lastPos.1)) }
        buttons.removeAll()
    }

    /// Sends a key combination (e.g. Ctrl+Alt+Del is impossible, but Alt+Tab etc. are fine).
    func sendCombo(_ keys: [UInt16]) {
        for k in keys { session?.key(KeyEvent(down: true, hid: k)) }
        for k in keys.reversed() { session?.key(KeyEvent(down: false, hid: k)) }
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }
}
