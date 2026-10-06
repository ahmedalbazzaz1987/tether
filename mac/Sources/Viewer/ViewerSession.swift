import Foundation
import CoreGraphics
import ImageIO

struct DecodedFrame {
    var seq: UInt32
    var width: Int
    var height: Int
    var rects: [(x: Int, y: Int, image: CGImage)]
}

/// The side of a session where this Mac controls another computer.
final class ViewerSession: SessionCore {
    let remote: ServerInfo
    var onHello: (Control) -> Void = { _ in }
    var onFrame: (DecodedFrame) -> Void = { _ in }
    private let decodeQueue = DispatchQueue(label: "tether.decode", qos: .userInteractive)
    private(set) var remoteOS = ""

    init(ch: SecureChannel, remote: ServerInfo, events: SessionEvents, downloads: URL) {
        self.remote = remote
        super.init(ch: ch, events: events, downloads: downloads, idBase: 1_000_000)
    }

    var kind: String { ch.kind }

    func run() async {
        var hello = Control("hello")
        hello.os = "mac"
        hello.name = Host.current().localizedName ?? "Mac"
        hello.version = appVersion
        sendJSON(hello)
        startBackground()
        while !isEnded {
            do {
                let (type, d) = try await ch.recv()
                switch type {
                case Msg.video:
                    decodeQueue.async { [weak self] in
                        guard let self = self, let f = ViewerSession.decode(d) else { return }
                        self.onFrame(f)
                    }
                case Msg.json:
                    let m = parseControl(d)
                    if handleCommon(type, d, m) { continue }
                    if let m = m, m.t == "hello" {
                        remoteOS = m.os ?? ""
                        onHello(m)
                    }
                default:
                    _ = handleCommon(type, d, nil)
                }
            } catch {
                end("Connection lost")
            }
        }
    }

    static func decode(_ d: Data) -> DecodedFrame? {
        let b = [UInt8](d)
        guard b.count >= 10 else { return nil }
        let seq = readU32(b, 0)
        let w = readU16(b, 4), h = readU16(b, 6), n = readU16(b, 8)
        var jobs: [(Int, Int, Range<Int>)] = []
        var o = 10
        for _ in 0..<n {
            guard o + 13 <= b.count else { return nil }
            let x = readU16(b, o), y = readU16(b, o + 2)
            let len = Int(readU32(b, o + 9))
            guard o + 13 + len <= b.count else { return nil }
            jobs.append((x, y, (o + 13)..<(o + 13 + len)))
            o += 13 + len
        }
        var images = [CGImage?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let slice = d.subdata(in: d.startIndex + jobs[i].2.lowerBound ..< d.startIndex + jobs[i].2.upperBound)
            let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            var img: CGImage?
            if let src = CGImageSourceCreateWithData(slice as CFData, nil) {
                img = CGImageSourceCreateImageAtIndex(src, 0, opts)
            }
            lock.lock(); images[i] = img; lock.unlock()
        }
        var rects: [(x: Int, y: Int, image: CGImage)] = []
        for (i, j) in jobs.enumerated() {
            if let img = images[i] { rects.append((x: j.0, y: j.1, image: img)) }
        }
        return DecodedFrame(seq: seq, width: w, height: h, rects: rects)
    }

    func ack(_ seq: UInt32) { send(Msg.ack, encodeU32(seq)) }
    func mouse(_ m: MouseEvent) { send(Msg.mouse, m.encode()) }
    func key(_ k: KeyEvent) { send(Msg.key, k.encode()) }
    func refresh() { sendJSON(Control("refresh")) }
    func setQuality(_ q: String) { var c = Control("quality"); c.q = q; sendJSON(c) }
    func selectDisplay(_ id: Int) { var c = Control("display"); c.id = Int64(id); sendJSON(c) }
}
