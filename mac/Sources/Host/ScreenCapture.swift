import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Streams one display with ScreenCaptureKit and keeps the newest frame.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var frameCounter: UInt64 = 0
    private let queue = DispatchQueue(label: "tether.capture", qos: .userInteractive)
    private(set) var displayID: CGDirectDisplayID = CGMainDisplayID()

    static func displays() async -> [(SCDisplay, DisplayInfo)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let names: [CGDirectDisplayID: String] = {
            var m: [CGDirectDisplayID: String] = [:]
            for s in NSScreen.screens {
                if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    m[CGDirectDisplayID(n.uint32Value)] = s.localizedName
                }
            }
            return m
        }()
        let main = CGMainDisplayID()
        var sorted = content.displays
        sorted.sort { a, b in
            if a.displayID == main { return true }
            if b.displayID == main { return false }
            return a.frame.minX < b.frame.minX
        }
        return sorted.enumerated().map { i, d in
            (d, DisplayInfo(id: i, name: names[d.displayID] ?? "Display \(i + 1)", w: d.width, h: d.height, primary: d.displayID == main))
        }
    }

    func start(display: SCDisplay, quality: String) async throws {
        await stopAsync()
        displayID = display.displayID
        let scale: CGFloat = {
            for s in NSScreen.screens {
                if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                   CGDirectDisplayID(n.uint32Value) == display.displayID { return s.backingScaleFactor }
            }
            return 1
        }()
        var w = display.width, h = display.height
        if quality == "best" && scale > 1 {
            let f = min(scale, 2880 / CGFloat(max(w, 1)))
            if f > 1 { w = Int(CGFloat(w) * f); h = Int(CGFloat(h) * f) }
        }
        let cfg = SCStreamConfiguration()
        cfg.width = w & ~1
        cfg.height = h & ~1
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = true
        cfg.queueDepth = 4
        cfg.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        lock.lock(); stream = s; latest = nil; lock.unlock()
    }

    func stopAsync() async {
        lock.lock(); let s = stream; stream = nil; latest = nil; lock.unlock()
        if let s = s { try? await s.stopCapture() }
    }

    func stop() {
        Task { await stopAsync() }
    }

    /// Newest complete frame and a counter that increases with every new frame.
    func latestFrame() -> (CVPixelBuffer, UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let l = latest else { return nil }
        return (l, frameCounter)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb) else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = arr.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete {
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lock.lock()
        latest = pb
        frameCounter &+= 1
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); if self.stream === stream { self.stream = nil }; lock.unlock()
    }
}

/// Screen Recording permission helpers.
enum ScreenPermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }
    static func request() { _ = CGRequestScreenCaptureAccess() }
}
