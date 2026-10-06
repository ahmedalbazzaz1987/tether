import Foundation
import AppKit
import ApplicationServices

/// Posts remote mouse/keyboard input with CGEvent (needs Accessibility permission).
final class Injector {
    private let src = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown = Set<UInt8>()
    private var keysDown = Set<UInt16>()
    private var flags: CGEventFlags = []
    private var lastPoint = CGPoint.zero
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var lastClickButton: UInt8 = 255
    private var clickCount: Int64 = 1
    private let lock = NSLock()

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func buttonEvent(_ b: UInt8, down: Bool) -> (CGEventType, CGMouseButton) {
        switch b {
        case 1: return (down ? .rightMouseDown : .rightMouseUp, .right)
        case 2: return (down ? .otherMouseDown : .otherMouseUp, .center)
        default: return (down ? .leftMouseDown : .leftMouseUp, .left)
        }
    }

    private func point(_ ev: MouseEvent, display: CGDirectDisplayID) -> CGPoint {
        let b = CGDisplayBounds(display)
        return CGPoint(x: b.minX + CGFloat(ev.x) / 65535 * max(b.width - 1, 1),
                       y: b.minY + CGFloat(ev.y) / 65535 * max(b.height - 1, 1))
    }

    func mouse(_ ev: MouseEvent, display: CGDirectDisplayID) {
        lock.lock(); defer { lock.unlock() }
        let p = point(ev, display: display)
        lastPoint = p
        switch ev.kind {
        case .move:
            let type: CGEventType
            let btn: CGMouseButton
            if buttonsDown.contains(0) { type = .leftMouseDragged; btn = .left }
            else if buttonsDown.contains(1) { type = .rightMouseDragged; btn = .right }
            else if buttonsDown.contains(2) { type = .otherMouseDragged; btn = .center }
            else { type = .mouseMoved; btn = .left }
            post(CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: btn))
        case .down, .up:
            let down = ev.kind == .down
            let (type, btn) = Self.buttonEvent(ev.button, down: down)
            if down {
                let now = ProcessInfo.processInfo.systemUptime
                if ev.button == lastClickButton && now - lastClickTime < NSEvent.doubleClickInterval
                    && abs(p.x - lastClickPoint.x) < 5 && abs(p.y - lastClickPoint.y) < 5 {
                    clickCount += 1
                } else {
                    clickCount = 1
                }
                lastClickTime = now; lastClickPoint = p; lastClickButton = ev.button
                buttonsDown.insert(ev.button)
            } else {
                buttonsDown.remove(ev.button)
            }
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: btn)
            e?.setIntegerValueField(.mouseEventClickState, value: clickCount)
            e?.flags = flags
            post(e)
        case .wheel:
            let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                            wheel1: Int32(ev.dy) / 3, wheel2: -Int32(ev.dx) / 3, wheel3: 0)
            e?.location = p
            post(e)
        }
    }

    private static let modifierFlag: [UInt16: CGEventFlags] = [
        0xE0: .maskControl, 0xE4: .maskControl, 0xE1: .maskShift, 0xE5: .maskShift,
        0xE2: .maskAlternate, 0xE6: .maskAlternate, 0xE3: .maskCommand, 0xE7: .maskCommand,
    ]

    func key(_ ev: KeyEvent) {
        lock.lock(); defer { lock.unlock() }
        guard let code = Keys.hidToMac[ev.hid] else { return }
        if let f = Self.modifierFlag[ev.hid] {
            if ev.down { keysDown.insert(ev.hid) } else { keysDown.remove(ev.hid) }
            // a modifier stays set while either the left or the right key is held
            let pair: [UInt16: UInt16] = [0xE0: 0xE4, 0xE4: 0xE0, 0xE1: 0xE5, 0xE5: 0xE1, 0xE2: 0xE6, 0xE6: 0xE2, 0xE3: 0xE7, 0xE7: 0xE3]
            if ev.down || keysDown.contains(pair[ev.hid] ?? 0) { flags.insert(f) } else { flags.remove(f) }
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: ev.down)
            e?.type = .flagsChanged
            e?.flags = flags
            post(e)
            return
        }
        if ev.hid == 0x39 { // caps lock toggles
            if ev.down {
                if flags.contains(.maskAlphaShift) { flags.remove(.maskAlphaShift) } else { flags.insert(.maskAlphaShift) }
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
                e?.type = .flagsChanged
                e?.flags = flags
                post(e)
            }
            return
        }
        if ev.down { keysDown.insert(ev.hid) } else { keysDown.remove(ev.hid) }
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: ev.down)
        var f = flags
        let fnKeys: Set<UInt16> = [0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52]
        if fnKeys.contains(ev.hid) { f.insert(.maskSecondaryFn) }
        if (0x4F...0x52).contains(ev.hid) { f.insert(.maskNumericPad) }
        e?.flags = f
        post(e)
    }

    func releaseAll() {
        lock.lock()
        let ks = keysDown, bs = buttonsDown, p = lastPoint
        lock.unlock()
        for k in ks { key(KeyEvent(down: false, hid: k)) }
        lock.lock(); defer { lock.unlock() }
        for b in bs {
            let (type, btn) = Self.buttonEvent(b, down: false)
            post(CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: btn))
        }
        buttonsDown = []
        flags = []
    }

    private func post(_ e: CGEvent?) {
        e?.post(tap: .cghidEventTap)
    }
}
