import Foundation
import Darwin

/// LAN discovery (PROTOCOL.md §6): "TETHER-FIND <id>" broadcast on UDP 47800,
/// answered by "TETHER-HERE <id> <tcpPort>". Lets IDs work on the same
/// network without a relay.
enum LANDiscovery {
    static let port: UInt16 = 47800

    private static func sockaddrIn(_ ip: in_addr_t, _ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr = in_addr(s_addr: ip)
        return a
    }

    /// 255.255.255.255 plus every interface's directed broadcast address.
    private static func broadcastAddrs() -> [in_addr_t] {
        var out: [in_addr_t] = [in_addr_t(0xFFFF_FFFF)]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
               let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               let b = cur.pointee.ifa_dstaddr, b.pointee.sa_family == UInt8(AF_INET) {
                let addr = b.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                if addr != 0 && !out.contains(addr) { out.append(addr) }
            }
            p = cur.pointee.ifa_next
        }
        return out
    }

    private static func send(_ fd: Int32, _ text: String, to addr: sockaddr_in) {
        var a = addr
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &a) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                sendto(fd, bytes, bytes.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Finds the computer with this ID on the local network ("ip:port"). Blocking — call off the main thread.
    static func find(id: String, timeout: TimeInterval = 0.9) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 150_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let deadline = Date().addingTimeInterval(timeout)
        var lastSend = Date.distantPast
        var buf = [UInt8](repeating: 0, count: 256)
        while Date() < deadline {
            if Date().timeIntervalSince(lastSend) > timeout / 3 {
                for b in broadcastAddrs() { send(fd, "TETHER-FIND \(id)", to: sockaddrIn(b, port)) }
                lastSend = Date()
            }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let parts = String(decoding: buf[0..<n], as: UTF8.self).split(separator: " ")
            if parts.count == 3, parts[0] == "TETHER-HERE", parts[1] == Substring(id), let p = UInt16(parts[2]) {
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = from.sin_addr
                inet_ntop(AF_INET, &addr, &host, socklen_t(INET_ADDRSTRLEN))
                return "\(String(cString: host)):\(p)"
            }
        }
        return nil
    }
}

/// Answers discovery requests for this Mac's ID while incoming LAN connections are allowed.
final class DiscoveryResponder {
    private var fd: Int32 = -1
    private let lock = NSLock()

    func start(id: String, tcpPort: @escaping () -> UInt16?) {
        stop()
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = LANDiscovery.port.bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))
        let ok = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(s); return }
        lock.lock(); fd = s; lock.unlock()
        let thread = Thread {
            var buf = [UInt8](repeating: 0, count: 256)
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &buf, buf.count, 0, $0, &len) }
                }
                if n <= 0 { return } // socket closed
                let parts = String(decoding: buf[0..<n], as: UTF8.self).split(separator: " ")
                guard parts.count == 2, parts[0] == "TETHER-FIND", parts[1] == Substring(id), let port = tcpPort() else { continue }
                let reply = Array("TETHER-HERE \(id) \(port)".utf8)
                _ = withUnsafePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, reply, reply.count, 0, $0, len) }
                }
            }
        }
        thread.name = "tether.discovery"
        thread.start()
    }

    func stop() {
        lock.lock()
        let s = fd
        fd = -1
        lock.unlock()
        if s >= 0 {
            shutdown(s, SHUT_RDWR)
            close(s)
        }
    }
}
