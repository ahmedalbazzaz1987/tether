import Foundation
import CryptoKit
import Security

struct RecentEntry: Codable, Hashable {
    var target: String
    var name: String
    var os: String
    var when: Date
}

/// Persisted to ~/Library/Application Support/Tether/config.json (mode 0600).
struct Config: Codable {
    var id: String
    var secret: String      // relay ownership secret (hex)
    var hostSeed: String    // Ed25519 seed (base64)
    var salt: String        // hex, 16 bytes
    var permKpw: String?    // base64 of PBKDF2(permanent password)
    var relayUrl: String = ""
    var allowLan: Bool = true
    var lanPort: Int = 47800
    var quality: String = "balanced"
    var launchAtLogin: Bool = false
    var clipboardSync: Bool = true
    var acceptIncoming: Bool = true
    var autoUpdate: Bool = true
    var swapCmdCtrl: Bool = true
    var knownHosts: [String: String] = [:]
    var recent: [RecentEntry] = []

    init(id: String, secret: String, hostSeed: String, salt: String, permKpw: String?) {
        self.id = id; self.secret = secret; self.hostSeed = hostSeed; self.salt = salt; self.permKpw = permKpw
    }

    // Tolerant decoding: settings added in later versions fall back to defaults.
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        id = try k.decode(String.self, forKey: .id)
        secret = try k.decode(String.self, forKey: .secret)
        hostSeed = try k.decode(String.self, forKey: .hostSeed)
        salt = try k.decode(String.self, forKey: .salt)
        permKpw = try k.decodeIfPresent(String.self, forKey: .permKpw)
        relayUrl = try k.decodeIfPresent(String.self, forKey: .relayUrl) ?? ""
        allowLan = try k.decodeIfPresent(Bool.self, forKey: .allowLan) ?? true
        lanPort = try k.decodeIfPresent(Int.self, forKey: .lanPort) ?? 47800
        quality = try k.decodeIfPresent(String.self, forKey: .quality) ?? "balanced"
        launchAtLogin = try k.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        clipboardSync = try k.decodeIfPresent(Bool.self, forKey: .clipboardSync) ?? true
        acceptIncoming = try k.decodeIfPresent(Bool.self, forKey: .acceptIncoming) ?? true
        autoUpdate = try k.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        swapCmdCtrl = try k.decodeIfPresent(Bool.self, forKey: .swapCmdCtrl) ?? true
        knownHosts = try k.decodeIfPresent([String: String].self, forKey: .knownHosts) ?? [:]
        recent = try k.decodeIfPresent([RecentEntry].self, forKey: .recent) ?? []
    }

    static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    static func fresh() -> Config {
        let n = Int(UInt32.random(in: 0..<900_000_000)) + 100_000_000
        return Config(id: String(n), secret: randomBytes(32).hex, hostSeed: randomBytes(32).base64EncodedString(),
                      salt: randomBytes(16).hex, permKpw: nil)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        var d = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            guard let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }
}

final class ConfigStore {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tether", isDirectory: true)
    }()
    private let url = ConfigStore.dir.appendingPathComponent("config.json")
    private let lock = NSLock()
    private(set) var c: Config

    init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let d = try? Data(contentsOf: url), let cfg = try? JSONDecoder.tether.decode(Config.self, from: d), cfg.id.count == 9 {
            c = cfg
        } else {
            c = Config.fresh()
            save()
        }
    }

    func current() -> Config { lock.lock(); defer { lock.unlock() }; return c }

    func update(_ f: (inout Config) -> Void) {
        lock.lock()
        f(&c)
        lock.unlock()
        save()
    }

    func save() {
        lock.lock()
        let data = try? JSONEncoder.tether.encode(c)
        lock.unlock()
        guard let d = data else { return }
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600])
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: tmp, to: url) }
    }

    var hostKey: Curve25519.Signing.PrivateKey {
        if let d = Data(base64Encoded: current().hostSeed), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.Signing.PrivateKey()
        update { $0.hostSeed = k.rawRepresentation.base64EncodedString() }
        return k
    }

    var saltData: Data { Data(hex: current().salt) ?? Data(repeating: 0, count: 16) }
    var permKPW: Data? { current().permKpw.flatMap { Data(base64Encoded: $0) } }
}

extension JSONEncoder {
    static let tether: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let tether: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

func fingerprint(_ pub: Data) -> String {
    let h = SHA256.hash(data: pub)
    let x = Data(h).prefix(8).hex.uppercased()
    let a = Array(x)
    return [0, 4, 8, 12].map { String(a[$0..<$0 + 4]) }.joined(separator: " ")
}

func oneTimePassword() -> String {
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    return String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
}

func formatID(_ id: String) -> String {
    guard id.count == 9 else { return id }
    let a = Array(id)
    return "\(String(a[0..<3])) \(String(a[3..<6])) \(String(a[6..<9]))"
}
