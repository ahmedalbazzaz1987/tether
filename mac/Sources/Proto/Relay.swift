import Foundation
import Network

enum RelayURL {
    /// Normalises what the user typed into a ws(s):// base URL.
    static func base(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { throw TetherError.message("no relay configured – add your relay address in Settings") }
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://") { s = "ws://" + s.dropFirst(7) }
        else if !s.hasPrefix("wss://") && !s.hasPrefix("ws://") { s = "wss://" + s }
        guard URL(string: s) != nil else { throw TetherError.message("relay address is not valid") }
        return s
    }

    static func make(_ base: String, _ path: String, _ q: [String: String]) -> URL? {
        var c = URLComponents(string: base + path)
        c?.queryItems = q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }
}

private struct Notice: Decodable {
    var t: String
    var sid: String?
    var lan: [String]?
    var reason: String?
}

private func readNotice(_ task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> Notice {
    try await withThrowingTaskGroup(of: Notice.self) { g in
        g.addTask {
            while true {
                let m = try await task.receive()
                if case .string(let s) = m, let n = try? JSONDecoder().decode(Notice.self, from: Data(s.utf8)) {
                    return n
                }
            }
        }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw TetherError.message("timeout")
        }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

// MARK: - Host registration

/// Keeps a control socket open to the relay and accepts incoming viewers.
final class RelayHost {
    let relay: String
    let id: String
    let secret: String
    let lan: () -> [String]
    let onIncoming: (Transport) -> Void
    let onStatus: (Bool, String) -> Void
    private var task: Task<Void, Never>?

    init(relay: String, id: String, secret: String, lan: @escaping () -> [String],
         onIncoming: @escaping (Transport) -> Void, onStatus: @escaping (Bool, String) -> Void) {
        self.relay = relay; self.id = id; self.secret = secret; self.lan = lan
        self.onIncoming = onIncoming; self.onStatus = onStatus
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            let base: String
            do { base = try RelayURL.base(relay) } catch { onStatus(false, error.localizedDescription); return }
            guard let url = RelayURL.make(base, "/host", ["id": id, "secret": secret, "lan": lan().joined(separator: ",")]) else { return }
            let ws = relaySession.webSocketTask(with: url)
            ws.maximumMessageSize = 1 << 20
            ws.resume()
            // A ping confirms the socket really opened (the server auto-answers "pong").
            do {
                try await ws.send(.string("ping"))
                let first = try await ws.receive()
                if case .string(let s) = first, s != "pong", let d = s.data(using: .utf8),
                   let n = try? JSONDecoder().decode(Notice.self, from: d), n.t == "incoming", let sid = n.sid {
                    accept(base, sid)
                }
            } catch {
                ws.cancel()
                let msg = (ws.response as? HTTPURLResponse)?.statusCode == 403
                    ? "Relay refused this ID (it belongs to another computer)" : "Relay unreachable"
                onStatus(false, msg)
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
                continue
            }
            backoff = 1
            onStatus(true, "Ready for connections")
            await serve(ws, base)
            if !Task.isCancelled {
                onStatus(false, "Reconnecting to relay…")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func serve(_ ws: URLSessionWebSocketTask, _ base: String) async {
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { break }
                do { try await ws.send(.string("ping")) } catch { ws.cancel(); break }
            }
        }
        defer { pinger.cancel(); ws.cancel() }
        while !Task.isCancelled {
            guard let m = try? await ws.receive() else { return }
            if case .string(let s) = m, let n = try? JSONDecoder().decode(Notice.self, from: Data(s.utf8)),
               n.t == "incoming", let sid = n.sid {
                accept(base, sid)
            }
        }
    }

    private func accept(_ base: String, _ sid: String) {
        guard let url = RelayURL.make(base, "/accept", ["id": id, "secret": secret, "sid": sid]) else { return }
        let ws = relaySession.webSocketTask(with: url)
        ws.resume()
        onIncoming(WSTransport(ws))
    }
}

// MARK: - Viewer dialing

enum Dialer {
    static func isID(_ s: String) -> String? {
        let c = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        return c.count == 9 && c.allSatisfy({ $0.isASCII && $0.isNumber }) ? c : nil
    }

    /// Opens a transport to a 9-digit ID (via relay, LAN preferred) or host[:port].
    static func dial(_ target: String, relay: String) async throws -> Transport {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let id = isID(t) {
            // Same network? Find it directly first — no relay needed.
            let found = await Task.detached(priority: .userInitiated) { LANDiscovery.find(id: id) }.value
            if let addr = found, let direct = try? await dialDirect(addr) { return direct }
            if relay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TetherError.message("Couldn't find that ID on your local network. To connect over the internet, add your relay address in Settings — or enter the computer's IP address instead.")
            }
            return try await dialID(id, relay: relay)
        }
        return try await dialDirect(t)
    }

    static func splitHostPort(_ s: String) -> (String, UInt16) {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") { // [v6]:port
            let host = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) { return (host, p) }
            return (host, 47800)
        }
        let parts = s.split(separator: ":")
        if parts.count == 2, let p = UInt16(parts[1]) { return (String(parts[0]), p) }
        return (s, 47800)
    }

    static func dialDirect(_ s: String) async throws -> Transport {
        let (h, p) = splitHostPort(s)
        do { return try await TCPTransport.connect(host: h, port: p, timeout: 6) }
        catch { throw TetherError.message("cannot reach \(h):\(p)") }
    }

    static func tryLAN(_ addrs: [String]) async -> Transport? {
        await withTaskGroup(of: Transport?.self) { g in
            for a in addrs {
                g.addTask {
                    let (h, p) = Dialer.splitHostPort(a)
                    return try? await TCPTransport.connect(host: h, port: p, timeout: 0.9)
                }
            }
            var win: Transport?
            for await r in g {
                if let r = r {
                    if win == nil { win = r } else { r.close() }
                }
            }
            return win
        }
    }

    static func dialID(_ id: String, relay: String) async throws -> Transport {
        let base = try RelayURL.base(relay)
        guard let url = RelayURL.make(base, "/connect", ["id": id]) else { throw TetherError.protocolError }
        let ws = relaySession.webSocketTask(with: url)
        ws.maximumMessageSize = 20 << 20
        ws.resume()
        let n: Notice
        do { n = try await readNotice(ws, timeout: 10) } catch {
            ws.cancel()
            throw TetherError.message("cannot reach relay")
        }
        if n.t == "error" {
            ws.cancel()
            throw TetherError.message(n.reason == "offline" ? "that computer is offline or the ID is wrong" : (n.reason ?? "relay error"))
        }
        if let lan = n.lan, !lan.isEmpty, let direct = await tryLAN(lan) {
            ws.cancel(with: .normalClosure, reason: nil)
            return direct
        }
        do {
            try await ws.send(.string("{\"t\":\"relay\"}"))
            let r = try await readNotice(ws, timeout: 15)
            guard r.t == "ready" else { throw TetherError.message("no answer") }
        } catch {
            ws.cancel()
            throw TetherError.message("the remote computer did not respond")
        }
        return WSTransport(ws)
    }
}

/// Private IPv4 addresses of this Mac.
func localIPv4() -> [String] {
    var out: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
    defer { freeifaddrs(ifaddr) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        let flags = Int32(cur.pointee.ifa_flags)
        if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
           flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || isPrivate172(ip) { out.append(ip) }
            }
        }
        p = cur.pointee.ifa_next
    }
    return out
}

private func isPrivate172(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".")
    guard parts.count == 4, parts[0] == "172", let b = Int(parts[1]) else { return false }
    return b >= 16 && b <= 31
}
