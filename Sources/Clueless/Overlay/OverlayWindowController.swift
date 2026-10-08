import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    let panel: OverlayPanel

    private let auditor: CaptureAuditor
    private let state: OverlayState

    init(
        auditor: CaptureAuditor,
        state: OverlayState,
        settings: SettingsStore,
        conversation: ConversationController,
        listen: ListenController,
        onRequestQuit: @escaping () -> Void
    ) {
        self.auditor = auditor
        self.state = state
        self.panel = OverlayPanel()

        let rootView = OverlayView(
            auditor: auditor,
            state: state,
            settings: settings,
            conversation: conversation,
            listen: listen,
            onRunAudit: { [weak self] in self?.runAudit() },
            onHide: { [weak self] in self?.hide() },
            onToggleCaptureVisibility: { [weak self] in self?.toggleCaptureVisibility() },
            onRequestQuit: onRequestQuit
        )
        let hosting = NSHostingView(rootView: rootView)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        positionTopRight()
    }

    var window: NSWindow { panel }

    func show() {
        panel.orderFrontRegardless()
        state.isVisible = true
    }

    func hide() {
        panel.orderOut(nil)
        state.isVisible = false
    }

    func toggleVisibility() {
        state.isVisible ? hide() : show()
    }

    func toggleCaptureVisibility() {
        state.isIncludedInCaptures.toggle()
        panel.sharingType = state.isIncludedInCaptures ? .readOnly : .none
        runAudit()
    }

    func runAudit() {
        Task { @MainActor in
            let wasHidden = !state.isVisible
            if wasHidden {
                show()
                try? await Task.sleep(for: .milliseconds(300))
            }
            await auditor.run(overlay: panel, includedInCaptures: state.isIncludedInCaptures)
        }
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - 24,
            y: frame.maxY - size.height - 24
        ))
    }
}
