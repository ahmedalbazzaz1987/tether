import Foundation
import ScreenCaptureKit

/// The side of a session where this Mac is being controlled.
final class HostSession: SessionCore {
    let viewerName: String
    private let injector = Injector()
    private let capturer = ScreenCapturer()
    private let encoder = FrameEncoder()
    private var displays: [(SCDisplay, DisplayInfo)] = []
    private var displayIndex = 0
    private var quality = "balanced"
    private let vlock = NSLock()
    private var inflight = 0
    private var lastAck = Date()
    private var viewerReady = false
    private var videoTask: Task<Void, Never>?

    init(ch: SecureChannel, viewerName: String, events: SessionEvents, downloads: URL) {
        self.viewerName = viewerName
        super.init(ch: ch, events: events, downloads: downloads, idBase: 0)
    }

    var kind: String { ch.kind }

    func run() async {
        displays = await ScreenCapturer.displays()
        displayIndex = displays.firstIndex(where: { $0.1.primary == true }) ?? 0
        var hello = Control("hello")
        hello.os = "mac"
        hello.name = Host.current().localizedName ?? "Mac"
        hello.version = appVersion
        hello.displays = displays.map { $0.1 }
        hello.display = displayIndex
        sendJSON(hello)
        var notes: [String] = []
        if displays.isEmpty || !ScreenPermission.granted {
            notes.append("Screen Recording is not allowed on this Mac yet (System Settings → Privacy & Security → Screen Recording → Tether).")
        }
        if !Injector.trusted {
            notes.append("Mouse and keyboard control is not allowed on this Mac yet (System Settings → Privacy & Security → Accessibility → Tether).")
        }
        for n in notes {
            var c = Control("chat"); c.text = "⚠️ " + n
            sendJSON(c)
        }
        if !notes.isEmpty { DispatchQueue.main.async { ScreenPermission.request(); Injector.requestTrust() } }
        await startCapture()
        startBackground()
        videoTask = Task.detached(priority: .userInitiated) { [weak self] in await self?.videoLoop() }
        while !isEnded {
            do {
                let (type, d) = try await ch.recv()
                handle(type, d)
            } catch {
                end("Connection lost")
            }
        }
    }

    private func startCapture() async {
        guard !displays.isEmpty else { return }
        let d = displays[min(displayIndex, displays.count - 1)].0
        do { try await capturer.start(display: d, quality: quality) } catch {
            NSLog("Tether: capture failed: \(error)")
        }
        encoder.invalidate()
    }

    private func handle(_ type: UInt8, _ d: Data) {
        switch type {
        case Msg.mouse:
            if let m = MouseEvent.decode(d) { injector.mouse(m, display: capturer.displayID) }
        case Msg.key:
            if let k = KeyEvent.decode(d) { injector.key(k) }
        case Msg.ack:
            vlock.lock()
            if inflight > 0 { inflight -= 1 }
            lastAck = Date()
            vlock.unlock()
        case Msg.json:
            let m = parseControl(d)
            if handleCommon(type, d, m) { return }
            guard let m = m else { return }
            switch m.t {
            case "hello":
                vlock.lock(); viewerReady = true; vlock.unlock()
            case "refresh":
                encoder.invalidate()
            case "quality":
                let q = m.q ?? "balanced"
                encoder.setQuality(q)
                if q != quality && (q == "best" || quality == "best") {
                    quality = q
                    Task { await startCapture() }
                } else {
                    quality = q
                }
            case "display":
                if let id = m.id, id >= 0, Int(id) < displays.count {
                    displayIndex = Int(id)
                    Task { await startCapture() }
                }
            default: break
            }
        default:
            _ = handleCommon(type, d, nil)
        }
    }

    private func videoLoop() async {
        var lastCounter: UInt64 = 0
        var lastChange = Date.distantPast
        while !isEnded {
            try? await Task.sleep(nanoseconds: 33_000_000)
            vlock.lock()
            if inflight >= 2 && Date().timeIntervalSince(lastAck) > 4 {
                inflight = 0
                encoder.invalidate()
            }
            let ok = viewerReady && inflight < 2
            vlock.unlock()
            guard ok, let frame = capturer.latestFrame() else { continue }
            let (pb, counter) = frame
            if counter != lastCounter { lastCounter = counter; lastChange = Date() }
            // After the picture settles, keep encoding ~1 s so blurry tiles get sharpened.
            else if Date().timeIntervalSince(lastChange) > 1.2 && !encoder.hasPendingFull { continue }
            guard let payload = encoder.encode(pb) else { continue }
            vlock.lock()
            if inflight == 0 { lastAck = Date() }
            inflight += 1
            vlock.unlock()
            do { try ch.send(Msg.video, payload) } catch { end("Connection lost"); return }
        }
    }

    override func didEnd() {
        videoTask?.cancel()
        capturer.stop()
        injector.releaseAll()
    }
}
