import Foundation
import CryptoKit
import CommonCrypto

// Implements PROTOCOL.md §2–3 byte-for-byte (shared with the Windows app).

enum TetherError: LocalizedError {
    case protocolError
    case badPassword
    case locked
    case busy
    case badSignature
    case hostProof
    case identityChanged
    case message(String)

    var errorDescription: String? {
        switch self {
        case .protocolError: return "Protocol error"
        case .badPassword: return "wrong password"
        case .locked: return "too many attempts – the remote computer is temporarily locked"
        case .busy: return "the remote computer is busy"
        case .badSignature: return "host signature invalid"
        case .hostProof: return "host could not prove the password"
        case .identityChanged: return "identity changed"
        case .message(let m): return m
        }
    }
}

enum Proto {
    static let version: UInt8 = 1
    static let osMac: UInt8 = 1
    static let osWindows: UInt8 = 2
    static let kdfIters = 150_000

    static func normalizePassword(_ p: String) -> String {
        String(p.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    static func deriveKPW(_ password: String, salt: Data, iters: Int) -> Data {
        let pw = Array(normalizePassword(password).utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        _ = pw.withUnsafeBufferPointer { pwp in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pwp.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                                 pw.count, saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iters), &out, 32)
        }
        return Data(out)
    }

    static func hk(_ ikm: Data, _ th: Data, _ info: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: th,
                                         info: Data(info.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    static func mac(_ key: Data, _ msg: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }

    static func transcript(_ p1: Data, _ p2body: Data) -> Data {
        var h = SHA256()
        h.update(data: Data("tether-v1".utf8))
        h.update(data: p1)
        h.update(data: p2body)
        return Data(h.finalize())
    }

    static func putName(_ d: inout Data, _ name: String) {
        var n = Data(name.utf8)
        if n.count > 64 { n = n.prefix(64) }
        d.append(UInt8(n.count))
        d.append(n)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var r: UInt8 = 0
        for i in 0..<a.count { r |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return r == 0
    }
}

struct ServerInfo {
    var hostPub: Data
    var os: UInt8
    var name: String
}

// MARK: - Viewer side

func clientHandshake(_ t: Transport, viewerName: String, password: String,
                     verify: (ServerInfo) throws -> Void) async throws -> (SecureChannel, ServerInfo) {
    let eph = Curve25519.KeyAgreement.PrivateKey()
    var p1 = Data("TTH1".utf8)
    p1.append(Proto.version)
    p1.append(eph.publicKey.rawRepresentation)
    Proto.putName(&p1, viewerName)
    t.send(p1)

    let p2 = try await t.recv()
    let b = [UInt8](p2)
    guard b.count >= 4 + 1 + 32 + 32 + 16 + 4 + 1 + 1 + 64, String(bytes: b[0..<4], encoding: .ascii) == "TTS1" else {
        throw TetherError.protocolError
    }
    var o = 5
    let hostEph = Data(b[o..<o + 32]); o += 32
    let hostPub = Data(b[o..<o + 32]); o += 32
    let salt = Data(b[o..<o + 16]); o += 16
    let iters = Int(UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])); o += 4
    let osb = b[o]; o += 1
    let nl = Int(b[o]); o += 1
    guard b.count == o + nl + 64 else { throw TetherError.protocolError }
    let name = String(decoding: b[o..<o + nl], as: UTF8.self); o += nl
    let body = Data(b[0..<o])
    let sig = Data(b[o...])
    let th = Proto.transcript(p1, body)
    guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: hostPub), pk.isValidSignature(sig, for: th) else {
        throw TetherError.badSignature
    }
    guard iters >= 10_000, iters <= 5_000_000 else { throw TetherError.protocolError }
    let info = ServerInfo(hostPub: hostPub, os: osb, name: name)
    try verify(info)

    guard let hp = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostEph) else { throw TetherError.protocolError }
    let shared = try eph.sharedSecretFromKeyAgreement(with: hp).withUnsafeBytes { Data($0) }
    let kpw = await Task.detached(priority: .userInitiated) { Proto.deriveKPW(password, salt: salt, iters: iters) }.value
    let ikm = shared + kpw
    var p3 = Data("TTP1".utf8)
    p3.append(Proto.mac(Proto.hk(ikm, th, "tether proof v"), "viewer"))
    t.send(p3)

    let p4 = try await t.recv()
    if p4.count == 5, String(data: p4.prefix(4), encoding: .ascii) == "TTNO" {
        switch p4[p4.startIndex + 4] {
        case 2: throw TetherError.locked
        case 3: throw TetherError.busy
        default: throw TetherError.badPassword
        }
    }
    guard p4.count == 36, String(data: p4.prefix(4), encoding: .ascii) == "TTOK" else { throw TetherError.protocolError }
    guard Proto.constantTimeEqual(Data(p4.suffix(32)), Proto.mac(Proto.hk(ikm, th, "tether proof h"), "host")) else {
        throw TetherError.hostProof
    }
    let ch = SecureChannel(t, sendKey: Proto.hk(ikm, th, "tether key v2h"), recvKey: Proto.hk(ikm, th, "tether key h2v"))
    return (ch, info)
}

// MARK: - Host side

final class Limiter {
    private var fails: [Date] = []
    private var lockTill = Date.distantPast
    private let lock = NSLock()

    var locked: Bool { lock.lock(); defer { lock.unlock() }; return Date() < lockTill }

    func fail() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        fails = fails.filter { now.timeIntervalSince($0) < 300 } + [now]
        if fails.count >= 5 { lockTill = now.addingTimeInterval(300); fails = [] }
    }

    func success() { lock.lock(); fails = []; lock.unlock() }
}

struct HostParams {
    var key: Curve25519.Signing.PrivateKey
    var name: String
    var os: UInt8
    var salt: Data
    var iters: Int
    var candidates: () -> [Data]
    var limiter: Limiter
    var busy: () -> Bool
}

func serverHandshake(_ t: Transport, _ hp: HostParams) async throws -> (SecureChannel, String) {
    let p1 = try await t.recv()
    let b = [UInt8](p1)
    guard b.count >= 38, String(bytes: b[0..<4], encoding: .ascii) == "TTH1" else { throw TetherError.protocolError }
    let vEph = Data(b[5..<37])
    let nl = Int(b[37])
    guard b.count == 38 + nl else { throw TetherError.protocolError }
    let vname = String(decoding: b[38..<38 + nl], as: UTF8.self)

    let eph = Curve25519.KeyAgreement.PrivateKey()
    var body = Data("TTS1".utf8)
    body.append(Proto.version)
    body.append(eph.publicKey.rawRepresentation)
    body.append(hp.key.publicKey.rawRepresentation)
    body.append(hp.salt)
    let it = UInt32(hp.iters)
    body.append(contentsOf: [UInt8(it >> 24 & 0xff), UInt8(it >> 16 & 0xff), UInt8(it >> 8 & 0xff), UInt8(it & 0xff)])
    body.append(hp.os)
    Proto.putName(&body, hp.name)
    let th = Proto.transcript(p1, body)
    let sig = try hp.key.signature(for: th)
    t.send(body + sig)

    let p3 = try await t.recv()
    guard p3.count == 36, String(data: p3.prefix(4), encoding: .ascii) == "TTP1" else { throw TetherError.protocolError }
    let proof = Data(p3.suffix(32))
    func fail(_ reason: UInt8, _ e: TetherError) throws -> Never {
        t.send(Data("TTNO".utf8) + Data([reason]))
        throw e
    }
    if hp.limiter.locked { try fail(2, .locked) }
    if hp.busy() { try fail(3, .busy) }
    guard let vp = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: vEph) else { throw TetherError.protocolError }
    let shared = try eph.sharedSecretFromKeyAgreement(with: vp).withUnsafeBytes { Data($0) }
    var ikm: Data?
    for kpw in hp.candidates() {
        let cand = shared + kpw
        if Proto.constantTimeEqual(proof, Proto.mac(Proto.hk(cand, th, "tether proof v"), "viewer")) { ikm = cand }
    }
    guard let k = ikm else {
        hp.limiter.fail()
        try await Task.sleep(nanoseconds: 700_000_000)
        try fail(1, .badPassword)
    }
    hp.limiter.success()
    t.send(Data("TTOK".utf8) + Proto.mac(Proto.hk(k, th, "tether proof h"), "host"))
    let ch = SecureChannel(t, sendKey: Proto.hk(k, th, "tether key h2v"), recvKey: Proto.hk(k, th, "tether key v2h"))
    return (ch, vname)
}

// MARK: - Encrypted channel

enum Msg {
    static let json: UInt8 = 0x01
    static let video: UInt8 = 0x02
    static let mouse: UInt8 = 0x03
    static let key: UInt8 = 0x04
    static let ack: UInt8 = 0x05
    static let file: UInt8 = 0x06
    static let frag: UInt8 = 0x7F
}

/// Encrypts and queues whole messages atomically (a lock keeps fragments
/// contiguous and counters in order). `recv` is used by a single reader task.
final class SecureChannel {
    let transport: Transport
    private let sendLock = NSLock()
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private var sendCtr: UInt64 = 0
    private var recvCtr: UInt64 = 0
    private var fragType: UInt8 = 0
    private var fragBuf = Data()
    private static let fragSize = 512 * 1024

    init(_ t: Transport, sendKey: Data, recvKey: Data) {
        transport = t
        self.sendKey = SymmetricKey(data: sendKey)
        self.recvKey = SymmetricKey(data: recvKey)
    }

    var kind: String { transport.kind }

    private static func nonce(_ c: UInt64) -> AES.GCM.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { n[4 + i] = UInt8((c >> (56 - 8 * UInt64(i))) & 0xff) }
        return try! AES.GCM.Nonce(data: n)
    }

    // No suspension points inside: a whole (possibly fragmented) message is
    // encrypted and queued atomically, so fragments can never interleave.
    private func sealSend(_ pt: Data) throws {
        let box = try AES.GCM.seal(pt, using: sendKey, nonce: Self.nonce(sendCtr))
        sendCtr += 1
        transport.send(box.ciphertext + box.tag)
    }

    func send(_ type: UInt8, _ payload: Data) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        if payload.count <= Self.fragSize {
            var pt = Data([type])
            pt.append(payload)
            try sealSend(pt)
            return
        }
        var off = 0
        while off < payload.count {
            let end = min(off + Self.fragSize, payload.count)
            var pt = Data([Msg.frag, type, end >= payload.count ? 1 : 0])
            pt.append(payload.subdata(in: payload.startIndex + off ..< payload.startIndex + end))
            try sealSend(pt)
            off = end
        }
    }

    func recv() async throws -> (UInt8, Data) {
        while true {
            let ct = try await transport.recv()
            guard ct.count >= 16 else { throw TetherError.protocolError }
            let box = try AES.GCM.SealedBox(nonce: Self.nonce(recvCtr), ciphertext: ct.prefix(ct.count - 16), tag: ct.suffix(16))
            let pt: Data
            do { pt = try AES.GCM.open(box, using: recvKey) } catch { throw TetherError.message("decryption failed") }
            recvCtr += 1
            guard let first = pt.first else { continue }
            if first != Msg.frag { return (first, Data(pt.dropFirst())) }
            guard pt.count >= 3 else { throw TetherError.protocolError }
            let bytes = [UInt8](pt.prefix(3))
            fragType = bytes[1]
            fragBuf.append(pt.dropFirst(3))
            if fragBuf.count > 64 << 20 { throw TetherError.protocolError }
            if bytes[2] == 1 {
                let out = fragBuf
                fragBuf = Data()
                return (fragType, out)
            }
        }
    }

    func close() { transport.close() }
}
