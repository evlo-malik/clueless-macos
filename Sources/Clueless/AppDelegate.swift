import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let auditor = CaptureAuditor()
    private let overlayState = OverlayState()
    private let settings = SettingsStore()
    private let openRouter = OpenRouterClient()

    private var conversation: ConversationController?
    private var listen: ListenController?
    private var overlayController: OverlayWindowController?
    private var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let conversation = ConversationController(settings: settings, client: openRouter)
        let listen = ListenController(settings: settings, client: openRouter, conversation: conversation)
        self.conversation = conversation
        self.listen = listen

        let overlay = OverlayWindowController(
            auditor: auditor,
            state: overlayState,
            settings: settings,
            conversation: conversation,
            listen: listen,
            onRequestQuit: { [weak self] in self?.requestQuit() }
        )
        overlayController = overlay

        let hotkeys = HotKeyManager()
        hotkeys.register(
            toggleOverlay: { [weak overlay] in overlay?.toggleVisibility() },
            sendScreenRequest: { [weak overlay, weak conversation] in
                overlay?.show()
                conversation?.sendScreenRequest()
            }
        )
        hotKeyManager = hotkeys

        overlay.show()

        // Give WindowServer a moment to register the panel before the first check.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            overlay.runAudit()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        listen?.stopAll()
    }

    private func requestQuit() {
        listen?.stopAll()
        NSApp.terminate(nil)
    }
}
