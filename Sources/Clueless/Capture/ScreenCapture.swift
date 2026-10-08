import AppKit
import ScreenCaptureKit

/// On-demand screenshot of the display under the overlay.
///
/// Because the overlay panel has `sharingType = .none`, it is automatically
/// absent from the captured image — the AI sees exactly what a human looking
/// over your shoulder would see, minus Clueless itself.
enum ScreenCapture {
    struct CapturedScreen {
        let image: CGImage
        let pointSize: NSSize

        var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

        /// JPEG for the vision API, downscaled to stay well under size limits.
        func jpegData(maxDimension: Int = 1568, quality: Double = 0.8) -> Data? {
            let scale = min(1.0, Double(maxDimension) / Double(max(image.width, image.height)))
            let width = Int(Double(image.width) * scale)
            let height = Int(Double(image.height) * scale)
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: scaled)
                .representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
    }

    enum CaptureError: LocalizedError {
        case screenRecordingPermissionMissing
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .screenRecordingPermissionMissing:
                return "Screen Recording permission is required. Allow Clueless in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Clueless."
            case .noDisplay:
                return "No display found to capture."
            }
        }
    }

    static var permissionGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func captureDisplay(containing point: NSPoint?) async throws -> CapturedScreen {
        guard permissionGranted else {
            requestPermission()
            throw CaptureError.screenRecordingPermissionMissing
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let display = content.displays.first { display in
            guard let point else { return false }
            return display.frame.contains(CGPoint(x: point.x, y: point.y))
        } ?? content.displays.first
        guard let display else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let pointSize = filter.contentRect.size
        configuration.width = Int(pointSize.width * scale)
        configuration.height = Int(pointSize.height * scale)

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedScreen(image: image, pointSize: pointSize)
    }
}
