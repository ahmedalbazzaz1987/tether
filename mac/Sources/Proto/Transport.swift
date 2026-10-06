import Foundation
import Network

/// Carries opaque packets (PROTOCOL.md §1). `send` only queues (in call order);
/// failures close the transport and surface on the next `recv`.
protocol Transport: AnyObject {
    var kind: String { get }
    func send(_ data: Data)
    func recv() async throws -> Data
    func close()
}

private final class Once {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { f() }
    }
}

// MARK: - TCP (direct LAN)

final class TCPTransport: Transport {
    let conn: NWConnection
    private let queue = DispatchQueue(label: "tether.tcp")
    private var buffer = Data()
    private var closed = false
    var kind: String { "direct" }

    init(_ conn: NWConnection) { self.conn = conn }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.connectionTimeout = 6
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Connects to host:port and waits until the connection is ready.
    static func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> TCPTransport {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw TetherError.message("bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters())
        let t = TCPTransport(conn)
        try await t.start(timeout: timeout)
        return t
    }

    /// Starts an accepted or outgoing connection and waits for `.ready`.
    func start(timeout: TimeInterval) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.run { cont.resume() }
                case .failed(let e):
                    once.run { cont.resume(throwing: e) }
                    self?.close()
                case .waiting(let e):
                    once.run { cont.resume(throwing: e) }
                    self?.close()
                case .cancelled:
                    once.run { cont.resume(throwing: TetherError.message("connection cancelled")) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                once.run {
                    cont.resume(throwing: TetherError.message("connection timed out"))
                    self?.close()
                }
            }
        }
    }

    func send(_ data: Data) {
        var h = Data(count: 4)
        let n = UInt32(data.count)
        h[0] = UInt8(n >> 24 & 0xff); h[1] = UInt8(n >> 16 & 0xff); h[2] = UInt8(n >> 8 & 0xff); h[3] = UInt8(n & 0xff)
        conn.send(content: h + data, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.close() }
        })
    }

    private func readSome(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, complete, error in
                if let d = data, !d.isEmpty {
                    cont.resume(returning: d)
                } else if let e = error {
                    cont.resume(throwing: e)
                } else if complete {
                    cont.resume(throwing: TetherError.message("connection closed"))
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private func readExactly(_ n: Int) async throws -> Data {
        while buffer.count < n {
            let d = try await readSome(max: max(65536, n - buffer.count))
            buffer.append(d)
        }
        let out = buffer.prefix(n)
        buffer = Data(buffer.dropFirst(n))
        return Data(out)
    }

    func recv() async throws -> Data {
        let h = [UInt8](try await readExactly(4))
        let n = Int(UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3]))
        guard n <= 16 << 20 else { throw TetherError.message("packet too large") }
        return try await readExactly(n)
    }

    func close() {
        conn.cancel()
    }
}

// MARK: - WebSocket (relay)

final class WSTransport: Transport {
    let task: URLSessionWebSocketTask
    var kind: String { "relay" }

    init(_ task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 20 << 20
    }

    func send(_ data: Data) {
        task.send(.data(data)) { [weak self] err in
            if err != nil { self?.close() }
        }
    }

    func recv() async throws -> Data {
        while true {
            switch try await task.receive() {
            case .data(let d): return d
            case .string: continue // relay notices after pairing are ignored
            @unknown default: continue
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// A URLSession for relay sockets (no caching, no cookies — nothing written to disk).
let relaySession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 90
    c.waitsForConnectivity = false
    return URLSession(configuration: c)
}()
