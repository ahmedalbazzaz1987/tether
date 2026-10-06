import Foundation
import CoreGraphics
import CoreVideo
import ImageIO

/// Tile-diff JPEG encoder — the same algorithm as the Windows app (core/video).
final class FrameEncoder {
    static let tile = 64
    private static let qualities: [String: (Int, Int)] = ["fast": (45, 80), "balanced": (62, 88), "best": (78, 94)]

    private let lock = NSLock()
    private var w = 0, h = 0, tw = 0, th = 0
    private var prev: [UInt8] = []
    private var sentQ: [Int] = []
    private var changedAt: [Double] = []
    private var seq: UInt32 = 0
    private var low = 62, high = 88
    private var needFull = true
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct Rect { var x, y, w, h, q: Int }

    func setQuality(_ q: String) {
        lock.lock(); defer { lock.unlock() }
        let v = Self.qualities[q] ?? (62, 88)
        low = v.0; high = v.1
        needFull = true
    }

    func invalidate() { lock.lock(); needFull = true; lock.unlock() }

    var hasPendingFull: Bool { lock.lock(); defer { lock.unlock() }; return needFull }

    /// Returns the video payload, or nil when nothing changed.
    func encode(_ pb: CVPixelBuffer) -> Data? {
        lock.lock(); defer { lock.unlock() }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let fw = CVPixelBufferGetWidth(pb), fh = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let now = Date().timeIntervalSinceReferenceDate
        var full = needFull
        if fw != w || fh != h || prev.isEmpty {
            w = fw; h = fh
            tw = (w + Self.tile - 1) / Self.tile
            th = (h + Self.tile - 1) / Self.tile
            prev = [UInt8](repeating: 0, count: w * h * 4)
            sentQ = [Int](repeating: 0, count: tw * th)
            changedAt = [Double](repeating: 0, count: tw * th)
            full = true
        }
        needFull = false
        var dirty = [Bool](repeating: false, count: tw * th)
        var refine = [Bool](repeating: false, count: tw * th)
        var nd = 0, nr = 0
        let rowBytes = w * 4
        prev.withUnsafeMutableBufferPointer { pp in
            let p = pp.baseAddress!
            for ty in 0..<th {
                let y0 = ty * Self.tile, y1 = min(y0 + Self.tile, h)
                for tx in 0..<tw {
                    let x0 = tx * Self.tile * 4
                    let len = min((tx + 1) * Self.tile, w) * 4 - x0
                    let idx = ty * tw + tx
                    var changed = full
                    if !changed {
                        for y in y0..<y1 where memcmp(src + y * stride + x0, p + y * rowBytes + x0, len) != 0 {
                            changed = true
                            break
                        }
                    }
                    if changed {
                        for y in y0..<y1 { memcpy(p + y * rowBytes + x0, src + y * stride + x0, len) }
                        dirty[idx] = true
                        changedAt[idx] = now
                        sentQ[idx] = low
                        nd += 1
                    } else if sentQ[idx] < high && now - changedAt[idx] > 0.35 && nr < 96 {
                        refine[idx] = true
                        sentQ[idx] = high
                        nr += 1
                    }
                }
            }
        }
        if nd == 0 && nr == 0 { return nil }
        let rects = merge(dirty, low) + merge(refine, high)
        var datas = [Data](repeating: Data(), count: rects.count)
        let dlock = NSLock()
        prev.withUnsafeBufferPointer { pp in
            let p = pp.baseAddress!
            DispatchQueue.concurrentPerform(iterations: rects.count) { i in
                let d = self.jpeg(rects[i], p)
                dlock.lock(); datas[i] = d; dlock.unlock()
            }
        }
        seq &+= 1
        var out = Data(capacity: 10 + datas.reduce(0) { $0 + $1.count + 13 })
        out.append(encodeU32(seq))
        out.append(contentsOf: [UInt8(w >> 8), UInt8(w & 0xff), UInt8(h >> 8), UInt8(h & 0xff),
                                UInt8(rects.count >> 8), UInt8(rects.count & 0xff)])
        for (i, r) in rects.enumerated() {
            out.append(contentsOf: [UInt8(r.x >> 8), UInt8(r.x & 0xff), UInt8(r.y >> 8), UInt8(r.y & 0xff),
                                    UInt8(r.w >> 8), UInt8(r.w & 0xff), UInt8(r.h >> 8), UInt8(r.h & 0xff), 1])
            out.append(encodeU32(UInt32(datas[i].count)))
            out.append(datas[i])
        }
        return out
    }

    private func merge(_ mark: [Bool], _ q: Int) -> [Rect] {
        struct Span: Hashable { let a: Int, b: Int }
        var out: [Rect] = []
        var open: [Span: Int] = [:]
        for ty in 0..<th {
            var next: [Span: Int] = [:]
            var tx = 0
            while tx < tw {
                if !mark[ty * tw + tx] { tx += 1; continue }
                let a = tx
                while tx < tw && mark[ty * tw + tx] { tx += 1 }
                let s = Span(a: a, b: tx)
                if let i = open[s] {
                    out[i].h = min((ty + 1) * Self.tile, h) - out[i].y
                    next[s] = i
                } else {
                    let x = a * Self.tile, y = ty * Self.tile
                    out.append(Rect(x: x, y: y, w: min(tx * Self.tile, w) - x, h: min(y + Self.tile, h) - y, q: q))
                    next[s] = out.count - 1
                }
            }
            open = next
        }
        return out
    }

    private func jpeg(_ r: Rect, _ p: UnsafePointer<UInt8>) -> Data {
        let rowBytes = w * 4
        var buf = Data(count: r.w * r.h * 4)
        buf.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let d = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<r.h {
                memcpy(d + y * r.w * 4, p + (r.y + y) * rowBytes + r.x * 4, r.w * 4)
            }
        }
        guard let provider = CGDataProvider(data: buf as CFData),
              let img = CGImage(width: r.w, height: r.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.w * 4,
                                space: colorSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: Double(r.q) / 100.0] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
