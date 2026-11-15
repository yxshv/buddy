import AppKit
import ScreenCaptureKit

/// A screenshot plus the mapping between its pixels and global screen points.
struct Shot {
    let jpeg: Data
    let width: Int
    let height: Int
    let frame: CGRect // screen frame in global AppKit coordinates (origin bottom-left)

    /// Stands in for a screenshot when screen access is off.
    static let blank = Shot(jpeg: Data(), width: 0, height: 0, frame: .zero)

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - frame.minX) * CGFloat(width) / frame.width,
                y: (frame.maxY - p.y) * CGFloat(height) / frame.height)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        let x = min(max(p.x, 0), CGFloat(width)), y = min(max(p.y, 0), CGFloat(height))
        return CGPoint(x: frame.minX + x * frame.width / CGFloat(width),
                       y: frame.maxY - y * frame.height / CGFloat(height))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    static var underMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main ?? screens[0]
    }
}

enum ScreenGrabber {
    static let maxWidth: CGFloat = 1280

    /// Captures one display, hiding Buddy's own overlay windows unless `includingBuddy` (for design checks).
    static func capture(frame: CGRect, displayID: CGDirectDisplayID, includingBuddy: Bool = false) async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NSError(domain: "Buddy", code: 3, userInfo: [NSLocalizedDescriptionKey: "No display found."])
        }
        let me = includingBuddy ? [] : content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let scale = min(1, maxWidth / frame.width)
        let config = SCStreamConfiguration()
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw NSError(domain: "Buddy", code: 4, userInfo: [NSLocalizedDescriptionKey: "Couldn't encode screenshot."])
        }
        return Shot(jpeg: jpeg, width: image.width, height: image.height, frame: frame)
    }
}

/// Waits for the screen to stop changing (a page finishing loading, an app opening) instead of
/// sleeping a fixed time: tiny screenshots a quarter-second apart, done when two in a row match.
enum ScreenSettle {
    private static let width = 192

    /// Waits at least `minWait`, then until the screen under the mouse is still, giving up after `maxWait`.
    static func wait(min minWait: Double, max maxWait: Double, done: @escaping () -> Void) {
        let screen = NSScreen.underMouse
        let displayID = screen.displayID
        let height = Int(Double(width) * screen.frame.height / screen.frame.width)
        let start = CACurrentMediaTime()
        Task {
            try? await Task.sleep(nanoseconds: UInt64(minWait * 1_000_000_000))
            var previous: [UInt8]?
            while CACurrentMediaTime() - start < maxWait {
                guard let frame = try? await thumbnail(displayID: displayID, height: height) else {
                    // Can't look (no Screen Recording access): fall back to a plain one-second wait.
                    let waited = CACurrentMediaTime() - start
                    if waited < 1 { try? await Task.sleep(nanoseconds: UInt64((1 - waited) * 1_000_000_000)) }
                    break
                }
                if let previous, nearlyEqual(previous, frame) { break }
                previous = frame
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await MainActor.run { done() }
        }
    }

    private static func thumbnail(displayID: CGDirectDisplayID, height: Int) async throws -> [UInt8] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return [] }
        let me = content.applications.filter { $0.processID == getpid() } // ignore Buddy's own animated panel
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
            configuration: config)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Fewer than 0.5% of pixels changed noticeably (ignores tiny things like a blinking text cursor).
    private static func nearlyEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var changed = 0
        var i = 0
        while i < a.count {
            if abs(Int(a[i]) - Int(b[i])) > 24 || abs(Int(a[i + 1]) - Int(b[i + 1])) > 24 || abs(Int(a[i + 2]) - Int(b[i + 2])) > 24 {
                changed += 1
            }
            i += 4
        }
        return Double(changed) / Double(a.count / 4) < 0.005
    }
}
