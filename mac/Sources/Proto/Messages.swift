import Foundation

struct DisplayInfo: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var w: Int
    var h: Int
    var primary: Bool?
}

/// Union of all JSON control messages (PROTOCOL.md §4).
struct Control: Codable {
    var t: String
    var os: String?
    var name: String?
    var version: String?
    var displays: [DisplayInfo]?
    var display: Int?
    var id: Int64?
    var q: String?
    var text: String?
    var size: Int64?
    var bytes: Int64?
    var ts: Int64?

    init(_ t: String) { self.t = t }
}

extension SecureChannel {
    func sendJSON(_ m: Control) throws {
        let enc = JSONEncoder()
        try send(Msg.json, try enc.encode(m))
    }
}

func parseControl(_ d: Data) -> Control? {
    try? JSONDecoder().decode(Control.self, from: d)
}

enum MouseKind: UInt8 { case move = 0, down = 1, up = 2, wheel = 3 }

struct MouseEvent {
    var kind: MouseKind
    var button: UInt8
    var x: UInt16
    var y: UInt16
    var dx: Int16 = 0
    var dy: Int16 = 0

    func encode() -> Data {
        var b = [UInt8](repeating: 0, count: 10)
        b[0] = kind.rawValue; b[1] = button
        b[2] = UInt8(x >> 8); b[3] = UInt8(x & 0xff)
        b[4] = UInt8(y >> 8); b[5] = UInt8(y & 0xff)
        let ux = UInt16(bitPattern: dx), uy = UInt16(bitPattern: dy)
        b[6] = UInt8(ux >> 8); b[7] = UInt8(ux & 0xff)
        b[8] = UInt8(uy >> 8); b[9] = UInt8(uy & 0xff)
        return Data(b)
    }

    static func decode(_ d: Data) -> MouseEvent? {
        guard d.count >= 10 else { return nil }
        let b = [UInt8](d.prefix(10))
        guard let k = MouseKind(rawValue: b[0]) else { return nil }
        return MouseEvent(kind: k, button: b[1],
                          x: UInt16(b[2]) << 8 | UInt16(b[3]), y: UInt16(b[4]) << 8 | UInt16(b[5]),
                          dx: Int16(bitPattern: UInt16(b[6]) << 8 | UInt16(b[7])),
                          dy: Int16(bitPattern: UInt16(b[8]) << 8 | UInt16(b[9])))
    }
}

struct KeyEvent {
    var down: Bool
    var hid: UInt16

    func encode() -> Data { Data([down ? 1 : 0, UInt8(hid >> 8), UInt8(hid & 0xff)]) }

    static func decode(_ d: Data) -> KeyEvent? {
        guard d.count >= 3 else { return nil }
        let b = [UInt8](d.prefix(3))
        return KeyEvent(down: b[0] == 1, hid: UInt16(b[1]) << 8 | UInt16(b[2]))
    }
}

func encodeU32(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
}

func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
}

func readU16(_ b: [UInt8], _ o: Int) -> Int {
    Int(b[o]) << 8 | Int(b[o + 1])
}
