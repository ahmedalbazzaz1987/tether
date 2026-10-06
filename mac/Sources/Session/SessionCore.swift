import Foundation
import AppKit

let appVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"

struct FileProgress: Identifiable, Equatable {
    var id: String { (incoming ? "i" : "o") + String(fileID) }
    var fileID: Int64
    var name: String
    var size: Int64
    var done: Int64
    var incoming: Bool
    var state: String // active, done, failed
    var path: URL?
}

struct SessionEvents {
    var onChat: (Bool, String) -> Void = { _, _ in }
    var onFile: (FileProgress) -> Void = { _ in }
    var onEnded: (String) -> Void = { _ in }
    var onPing: (Int) -> Void = { _ in }
}

/// Shared by host and viewer sessions: chat, clipboard sync, file transfer, ping.
class SessionCore {
    let ch: SecureChannel
    var events: SessionEvents
    let downloads: URL
    private let lock = NSLock()
    private var ended = false
    private(set) var endReason = ""
    private var nextID: Int64
    private var incoming: [Int64: InFile] = [:]
    private var outgoing: [Int64: OutFile] = [:]
    private var clipTimer: Timer?
    private var pingTask: Task<Void, Never>?
    var clipboardOn = true
    private var lastRemoteClip = ""
    private var lastChangeCount = NSPasteboard.general.changeCount

    final class InFile {
        var handle: FileHandle
        var tmp: URL
        var p: FileProgress
        var lastAck: Int64 = 0
        init(handle: FileHandle, tmp: URL, p: FileProgress) { self.handle = handle; self.tmp = tmp; self.p = p }
    }

    final class OutFile {
        var p: FileProgress
        var acked: Int64 = 0
        var cancelled = false
        init(p: FileProgress) { self.p = p }
    }

    init(ch: SecureChannel, events: SessionEvents, downloads: URL, idBase: Int64) {
        self.ch = ch
        self.events = events
        self.downloads = downloads
        self.nextID = idBase
    }

    var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    func send(_ type: UInt8, _ d: Data) {
        try? ch.send(type, d)
    }

    func sendJSON(_ c: Control) {
        try? ch.sendJSON(c)
    }

    func end(_ reason: String) {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        endReason = reason
        let ins = incoming.values
        let outs = outgoing.values
        incoming = [:]
        lock.unlock()
        ch.close()
        pingTask?.cancel()
        DispatchQueue.main.async { self.clipTimer?.invalidate() }
        for f in ins {
            try? f.handle.close()
            try? FileManager.default.removeItem(at: f.tmp)
            var p = f.p; p.state = "failed"
            events.onFile(p)
        }
        for o in outs { o.cancelled = true }
        didEnd()
        events.onEnded(reason)
    }

    /// Subclasses release keys etc.
    func didEnd() {}

    func disconnect() {
        let ch = self.ch
        Task {
            try? ch.sendJSON(Control("bye"))
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.end("Disconnected")
        }
    }

    func chat(_ text: String) {
        var c = Control("chat"); c.text = text
        sendJSON(c)
        events.onChat(false, text)
    }

    // MARK: clipboard & ping

    func startBackground() {
        DispatchQueue.main.async {
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.clipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollClipboard() }
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self = self, !self.isEnded else { return }
                var c = Control("ping"); c.ts = Int64(Date().timeIntervalSince1970 * 1000)
                self.sendJSON(c)
            }
        }
    }

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard clipboardOn, let text = pb.string(forType: .string), !text.isEmpty, text.utf8.count < 4 << 20 else { return }
        lock.lock()
        let dup = text == lastRemoteClip
        if !dup { lastRemoteClip = text }
        lock.unlock()
        if dup { return }
        var c = Control("clip"); c.text = text
        sendJSON(c)
    }

    private func applyRemoteClip(_ text: String) {
        guard clipboardOn else { return }
        lock.lock(); lastRemoteClip = text; lock.unlock()
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastChangeCount = pb.changeCount
        }
    }

    // MARK: message handling

    /// Returns true if the message was a shared one.
    func handleCommon(_ type: UInt8, _ d: Data, _ m: Control?) -> Bool {
        if type == Msg.file { fileData(d); return true }
        guard let m = m else { return false }
        switch m.t {
        case "bye": end("The other side ended the session")
        case "chat": events.onChat(true, m.text ?? "")
        case "clip": applyRemoteClip(m.text ?? "")
        case "ping":
            var c = Control("pong"); c.ts = m.ts
            sendJSON(c)
        case "pong":
            if let ts = m.ts { events.onPing(Int(Int64(Date().timeIntervalSince1970 * 1000) - ts)) }
        case "file.offer": fileOffer(m)
        case "file.end": fileEnd(m.id, cancelled: false)
        case "file.cancel":
            fileEnd(m.id, cancelled: true)
            lock.lock(); if let id = m.id { outgoing[id]?.cancelled = true }; lock.unlock()
        case "file.ack":
            lock.lock(); if let id = m.id { outgoing[id]?.acked = m.bytes ?? 0 }; lock.unlock()
        default: return false
        }
        return true
    }

    // MARK: files (receive)

    static func safeName(_ n: String) -> String {
        var s = (n.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        s = String(s.map { c -> Character in
            if c.unicodeScalars.contains(where: { $0.value < 32 }) || "<>:\"/\\|?*".contains(c) { return "_" }
            return c
        })
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return s.isEmpty ? "file" : s
    }

    private func uniqueURL(_ name: String) -> URL {
        let fm = FileManager.default
        var u = downloads.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 2
        while fm.fileExists(atPath: u.path) || fm.fileExists(atPath: u.path + ".part") {
            u = downloads.appendingPathComponent(ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            i += 1
        }
        return u
    }

    private func fileOffer(_ m: Control) {
        guard let id = m.id else { return }
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let final = uniqueURL(Self.safeName(m.name ?? "file"))
        let tmp = URL(fileURLWithPath: final.path + ".part")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let h = try? FileHandle(forWritingTo: tmp) else {
            var c = Control("file.cancel"); c.id = id
            sendJSON(c)
            return
        }
        let f = InFile(handle: h, tmp: tmp, p: FileProgress(fileID: id, name: final.lastPathComponent, size: m.size ?? 0,
                                                            done: 0, incoming: true, state: "active", path: final))
        lock.lock(); incoming[id] = f; lock.unlock()
        events.onFile(f.p)
    }

    private func fileData(_ d: Data) {
        guard d.count >= 4 else { return }
        let id = Int64(readU32([UInt8](d.prefix(4)), 0))
        lock.lock(); let f = incoming[id]; lock.unlock()
        guard let f = f else { return }
        let chunk = d.dropFirst(4)
        do { try f.handle.write(contentsOf: chunk) } catch {
            var c = Control("file.cancel"); c.id = id
            sendJSON(c)
            fileEnd(id, cancelled: true)
            return
        }
        f.p.done += Int64(chunk.count)
        if f.p.done - f.lastAck >= 1 << 20 || f.p.done == f.p.size {
            f.lastAck = f.p.done
            var c = Control("file.ack"); c.id = id; c.bytes = f.p.done
            sendJSON(c)
            events.onFile(f.p)
        }
    }

    private func fileEnd(_ id: Int64?, cancelled: Bool) {
        guard let id = id else { return }
        lock.lock(); let f = incoming.removeValue(forKey: id); lock.unlock()
        guard let f = f else { return }
        try? f.handle.close()
        var p = f.p
        if cancelled || p.done != p.size {
            try? FileManager.default.removeItem(at: f.tmp)
            p.state = "failed"
        } else if let dest = p.path {
            try? FileManager.default.moveItem(at: f.tmp, to: dest)
            p.state = "done"
        }
        events.onFile(p)
    }

    // MARK: files (send)

    func sendFile(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let h = try? FileHandle(forReadingFrom: url) else { return }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        lock.lock()
        nextID += 1
        let id = nextID
        let o = OutFile(p: FileProgress(fileID: id, name: url.lastPathComponent, size: size, done: 0, incoming: false, state: "active"))
        outgoing[id] = o
        lock.unlock()
        var offer = Control("file.offer"); offer.id = id; offer.name = o.p.name; offer.size = size
        let ch = self.ch
        events.onFile(o.p)
        Task.detached { [weak self] in
            guard let self = self else { return }
            defer { try? h.close() }
            do {
                try ch.sendJSON(offer)
                var sent: Int64 = 0
                var lastEmit = Date()
                let prefix = encodeU32(UInt32(truncatingIfNeeded: id))
                while true {
                    // flow control: at most 4 MiB un-acknowledged
                    while true {
                        self.lock.lock()
                        let cancelled = o.cancelled, acked = o.acked
                        self.lock.unlock()
                        if cancelled { throw TetherError.message("cancelled") }
                        if sent - acked <= 4 << 20 { break }
                        try await Task.sleep(nanoseconds: 15_000_000)
                    }
                    guard let chunk = try h.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                    try ch.send(Msg.file, prefix + chunk)
                    sent += Int64(chunk.count)
                    o.p.done = sent
                    if Date().timeIntervalSince(lastEmit) > 0.2 {
                        lastEmit = Date()
                        self.events.onFile(o.p)
                    }
                }
                var end = Control("file.end"); end.id = id
                try ch.sendJSON(end)
                o.p.state = "done"
            } catch {
                o.p.state = "failed"
                var c = Control("file.cancel"); c.id = id
                try? ch.sendJSON(c)
            }
            self.events.onFile(o.p)
            self.lock.lock(); self.outgoing[id] = nil; self.lock.unlock()
        }
    }
}
