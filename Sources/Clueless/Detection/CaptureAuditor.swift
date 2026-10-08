import AppKit
import ScreenCaptureKit

/// Checks that the overlay's capture visibility matches the toggle.
@MainActor
@Observable
final class CaptureAuditor {
    enum Status: String {
        case pass = "PASS"
        case warn = "WARN"
        case fail = "FAIL"
        case unknown = "UNKNOWN"
    }

    struct Check: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let status: Status
    }

    private(set) var checks: [Check] = []
    private(set) var lastRun: Date?
    var isRunning = false

    func run(overlay: OverlayPanel, includedInCaptures: Bool) async {
        isRunning = true
        defer {
            isRunning = false
            lastRun = Date()
        }

        var results: [Check] = []
        results.append(sharingTypeCheck(overlay, includedInCaptures: includedInCaptures))
        results.append(windowLevelCheck(overlay))
        results.append(contentsOf: windowServerChecks(overlay, includedInCaptures: includedInCaptures))
        results.append(await screenCaptureKitCheck(overlay, includedInCaptures: includedInCaptures))
        checks = results
    }

    func reportText() -> String {
        var lines = ["clueless capture check — \(lastRun?.formatted() ?? "never run")", ""]
        for check in checks {
            lines.append("[\(check.status.rawValue)] \(check.name) — \(check.detail)")
        }
        return lines.joined(separator: "\n")
    }

    private func sharingTypeCheck(_ overlay: NSWindow, includedInCaptures: Bool) -> Check {
        let expected: NSWindow.SharingType = includedInCaptures ? .readOnly : .none
        let ok = overlay.sharingType == expected
        return Check(
            name: "Capture visibility matches toggle",
            detail: ok
                ? (includedInCaptures ? "Overlay is included in captures." : "Overlay is excluded from captures.")
                : "Window sharing state \(overlay.sharingType.rawValue); expected \(expected.rawValue).",
            status: ok ? .pass : .fail
        )
    }

    private func windowLevelCheck(_ overlay: NSWindow) -> Check {
        let level = overlay.level.rawValue
        let ok = level >= NSWindow.Level.screenSaver.rawValue
        return Check(
            name: "Window level",
            detail: ok
                ? "Floating above fullscreen spaces (level \(level))."
                : "Window level \(level) is below the screensaver level, so a fullscreen app can cover it.",
            status: ok ? .pass : .fail
        )
    }

    private func windowServerChecks(_ overlay: NSWindow, includedInCaptures: Bool) -> [Check] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let windowID = CGWindowID(overlay.windowNumber)

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return [Check(name: "WindowServer query", detail: "CGWindowListCopyWindowInfo returned nothing.", status: .unknown)]
        }

        let entry = list.first { ($0["kCGWindowNumber"] as? Int).map { CGWindowID($0) == windowID } ?? false }
            ?? list.first {
                ($0["kCGWindowOwnerPID"] as? Int) == Int(pid)
                    && ($0["kCGWindowLayer"] as? Int ?? 0) >= NSWindow.Level.screenSaver.rawValue
            }

        guard let entry else {
            return [Check(
                name: "WindowServer metadata",
                detail: "Panel not found in the on-screen window list. Is it visible?",
                status: .warn
            )]
        }

        var out: [Check] = []

        if let sharing = entry["kCGWindowSharingState"] as? Int {
            let expected = includedInCaptures ? NSWindow.SharingType.readOnly.rawValue : NSWindow.SharingType.none.rawValue
            out.append(Check(
                name: "WindowServer sharing state",
                detail: "WindowServer reports sharing state \(sharing); expected \(expected).",
                status: sharing == expected ? .pass : .fail
            ))
        }

        out.append(Check(
            name: "Window metadata visible",
            detail: includedInCaptures
                ? "The panel is in the window list and its pixels are shareable."
                : "The panel is in the window list. Capture APIs still don't get its pixels.",
            status: .pass
        ))

        return out
    }

    private func screenCaptureKitCheck(_ overlay: NSWindow, includedInCaptures: Bool) async -> Check {
        guard CGPreflightScreenCaptureAccess() else {
            return Check(
                name: "ScreenCaptureKit enumeration",
                detail: "Needs Screen Recording permission to see what a capturing app would get. Grant it in System Settings, then run this again.",
                status: .unknown
            )
        }

        let windowID = CGWindowID(overlay.windowNumber)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let listed = content.windows.contains { $0.windowID == windowID }
            if includedInCaptures {
                return Check(
                    name: "ScreenCaptureKit visibility",
                    detail: listed
                        ? "The panel is available to screen capture."
                        : "Expected the panel in the shareable window list, but it isn't there.",
                    status: listed ? .pass : .fail
                )
            }
            // Recent macOS builds still list excluded windows here. Listing is metadata;
            // sharing state 0 is what withholds the pixels.
            return Check(
                name: "ScreenCaptureKit visibility",
                detail: listed
                    ? "Listed as metadata. Sharing state none still withholds the pixels."
                    : "The panel isn't in the shareable window list.",
                status: .pass
            )
        } catch {
            return Check(
                name: "ScreenCaptureKit visibility",
                detail: "Enumeration failed: \(error.localizedDescription)",
                status: .unknown
            )
        }
    }
}
