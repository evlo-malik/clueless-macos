import SwiftUI

struct OverlayView: View {
    enum Pane: Equatable {
        case chat
        case settings
    }

    let auditor: CaptureAuditor
    let state: OverlayState
    let settings: SettingsStore
    let conversation: ConversationController
    let listen: ListenController

    var onRunAudit: () -> Void
    var onHide: () -> Void
    var onToggleCaptureVisibility: () -> Void
    var onRequestQuit: () -> Void

    @State private var pane: Pane = .chat
    @State private var launchAgentInstalled = LaunchAgentManager.isInstalled
    @State private var screenPermissionGranted = ScreenCapture.permissionGranted
    @State private var micPermissionGranted = MicRecorder.permissionGranted
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch pane {
            case .chat: chatPane
            case .settings: settingsPane
            }
        }
        .frame(width: OverlayPanel.preferredSize.width, height: OverlayPanel.preferredSize.height)
        .cluelessCardGlass()
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .preferredColorScheme(.dark)
        .task(id: pane) {
            guard pane == .settings else { return }
            while !Task.isCancelled {
                refreshPermissions()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }
    }

    // MARK: - Chat pane

    private var chatPane: some View {
        VStack(spacing: 0) {
            // HEADER — prominent glass: the chat input with a send button top-right.
            inputHeader
                .prominentGlass(top: true)

            // BODY — clear glass: transcript + chat messages fill the space.
            Group {
                if !settings.hasAPIKey {
                    missingKeyPrompt
                } else {
                    contentArea
                }

                if let error = conversation.errorMessage ?? listen.errorMessage {
                    errorBanner(error)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // FOOTER — prominent glass: the action buttons.
            bottomBar
                .prominentGlass(top: false)
        }
    }

    /// The header IS the chat input: a large field filling the header, with a
    /// send button pinned to the top-right.
    private var inputHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Ask anything…", text: Bindable(conversation).draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(3...8)
                .focused($inputFocused)
                .onSubmit { conversation.send() }

            if conversation.isSending || conversation.isCapturingScreen {
                sendButton(systemName: "stop.fill", help: "Stop") {
                    conversation.cancelStream()
                }
            } else {
                sendButton(systemName: "arrow.up", help: "Send") {
                    conversation.send()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func sendButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cluelessGlass(in: .circle, tint: .accentColor)
        .help(help)
    }

    @ViewBuilder
    private var contentArea: some View {
        if listen.isSessionActive || !listen.transcripts.isEmpty {
            transcriptSection
        }
        messageList
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(listen.isSessionActive ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: listen.isSessionActive)
                Text(listen.isSessionActive ? "Listening" : "Transcript")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if listen.isTranscribing {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if !listen.transcripts.isEmpty {
                    Button("Clear") { listen.clearTranscript() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(listen.transcripts.suffix(8)) { item in
                        Text("\(item.source.label): \(item.text)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 90)

            if !listen.transcripts.isEmpty {
                HStack(spacing: 6) {
                    quickAction("Recap", instruction: "Give me a concise recap of this conversation so far.")
                    quickAction("What should I say?", instruction: "Based on this conversation, suggest what I should say next.")
                    quickAction("Fact-check", instruction: "Fact-check the key claims in this conversation.")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func quickAction(_ title: String, instruction: String) -> some View {
        Button {
            listen.askAI(instruction)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .cluelessGlass(in: .capsule)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(conversation.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: conversation.messages.last?.text) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = conversation.messages.last {
            withAnimation(.smooth(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func messageBubble(_ message: ConversationController.Message) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let attachment = message.attachment {
                    Image(nsImage: attachment)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 280, height: 140)
                        .clipShape(.rect(cornerRadius: 8))
                }
                if message.isStreaming && message.text.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if !message.text.isEmpty {
                    Text(markdown(message.text))
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .cluelessGlass(in: .rect(cornerRadius: 12), tint: message.role == .user ? .accentColor : nil)
            .layoutPriority(1)

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom button bar (footer)

    private var bottomBar: some View {
        HStack(spacing: 10) {
            bottomBarButton(
                systemName: "camera.viewfinder",
                active: false,
                activeTint: .accentColor,
                help: "Analyze screen (⌘Return)"
            ) {
                conversation.sendScreenRequest()
            }

            // Screen toggle: on = every message uses the screen.
            bottomBarButton(
                systemName: conversation.alwaysUseScreen ? "photo.fill" : "photo",
                active: conversation.alwaysUseScreen,
                activeTint: .blue,
                help: "Use screen context on every message"
            ) {
                withAnimation(.smooth(duration: 0.2)) {
                    conversation.alwaysUseScreen.toggle()
                }
            }

            // Audio session: records mic + system audio until ended.
            bottomBarButton(
                systemName: "waveform",
                active: listen.isSessionActive,
                activeTint: .red,
                help: listen.isSessionActive ? "End audio session" : "Start audio session"
            ) {
                listen.toggleSession()
            }

            // New chat.
            if !conversation.messages.isEmpty {
                bottomBarButton(
                    systemName: "square.and.pencil",
                    active: false,
                    activeTint: .accentColor,
                    help: "Clear chat (⌘R)"
                ) {
                    conversation.clear()
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            Spacer()

            bottomBarButton(
                systemName: state.isIncludedInCaptures ? "eye" : "eye.slash",
                active: state.isIncludedInCaptures,
                activeTint: .green,
                help: state.isIncludedInCaptures
                    ? "Overlay appears in screenshots and screen sharing"
                    : "Overlay hidden from screenshots and screen sharing",
                action: onToggleCaptureVisibility
            )

            bottomBarButton(
                systemName: "gearshape",
                active: false,
                activeTint: .accentColor,
                help: "Settings"
            ) {
                withAnimation(.smooth(duration: 0.2)) { pane = .settings }
            }

            bottomBarButton(
                systemName: "minus",
                active: false,
                activeTint: .accentColor,
                help: "Hide overlay (⌘\\)",
                action: onHide
            )

            bottomBarButton(
                systemName: "power",
                active: false,
                activeTint: .accentColor,
                help: "Quit Clueless",
                action: onRequestQuit
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func bottomBarButton(
        systemName: String,
        active: Bool,
        activeTint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? activeTint : .secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cluelessGlass(in: .circle, tint: active ? activeTint : nil)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Settings pane

    private var settingsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { pane = .chat }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .adaptiveGlassButton()
                .help("Back")

                Text("Settings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().overlay(.white.opacity(0.12))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    settingsSection("OpenRouter") {
                        SecureField("API key (sk-or-…)", text: Bindable(settings).apiKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .cluelessGlass(in: .rect(cornerRadius: 10))
                        HStack {
                            Text("Stored in your Keychain.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("Get a key") {
                                NSWorkspace.shared.open(URL(string: "https://openrouter.ai/keys")!)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                        modelField("API base URL", text: Bindable(settings).apiBaseURL)
                        Text("Leave this on the default unless you're pointing at another OpenAI-compatible endpoint.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection("Models") {
                        modelField("Chat / vision model", text: Bindable(settings).chatModelID)
                        modelField("Transcription model", text: Bindable(settings).transcriptionModelID)
                        Text("Any OpenRouter model ID. Screenshots go to the chat model, so pick one with vision.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection("System prompt") {
                        TextEditor(text: Bindable(settings).systemPrompt)
                            .font(.system(size: 11))
                            .scrollContentBackground(.hidden)
                            .frame(height: 64)
                            .padding(6)
                            .cluelessGlass(in: .rect(cornerRadius: 10))
                    }

                    settingsSection("Permissions") {
                        permissionRow(
                            name: "Screen Recording",
                            granted: screenPermissionGranted,
                            action: {
                                ScreenCapture.requestPermission()
                                refreshPermissions()
                            }
                        )
                        permissionRow(
                            name: "Microphone",
                            granted: micPermissionGranted,
                            action: {
                                Task {
                                    _ = await MicRecorder.requestPermission()
                                    refreshPermissions()
                                }
                            }
                        )
                        Text("After changing Screen Recording access, quit Clueless completely and reopen it. If a permission stays off, check that you enabled this build of Clueless in System Settings.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection("Startup") {
                        Toggle("Launch at login", isOn: Binding(
                            get: { launchAgentInstalled },
                            set: { _ in
                                do {
                                    if LaunchAgentManager.isInstalled {
                                        try LaunchAgentManager.uninstall()
                                    } else {
                                        try LaunchAgentManager.install()
                                    }
                                } catch {
                                    conversation.errorMessage = "Launch agent: \(error.localizedDescription)"
                                }
                                launchAgentInstalled = LaunchAgentManager.isInstalled
                            }
                        ))
                        .font(.system(size: 12))
                    }

                    settingsSection("Capture check") {
                        auditContent
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }

    private func modelField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("provider/model-id", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .cluelessGlass(in: .rect(cornerRadius: 10))
        }
    }

    private func permissionRow(name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.system(size: 12))
            Text(name)
                .font(.system(size: 12))
            Spacer()
            if !granted {
                Button("Request", action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func refreshPermissions() {
        screenPermissionGranted = ScreenCapture.permissionGranted
        micPermissionGranted = MicRecorder.permissionGranted
    }

    private var auditContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                if auditor.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run audit", action: onRunAudit)
                        .adaptiveGlassButton()
                        .controlSize(.small)
                }
                if !auditor.checks.isEmpty {
                    Button("Copy report", action: copyAuditReport)
                        .adaptiveGlassButton()
                        .controlSize(.small)
                }
            }
            ForEach(auditor.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: check.status.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(check.status.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.name).font(.system(size: 12, weight: .medium))
                        Text(check.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func copyAuditReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(auditor.reportText(), forType: .string)
    }

    // MARK: - Shared

    private var missingKeyPrompt: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "key")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Add your OpenRouter API key to start chatting.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Open Settings") { pane = .settings }
                .adaptiveGlassButton()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                conversation.errorMessage = nil
                listen.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .cluelessGlass(in: .capsule, tint: tint)
    }

    private func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }
}

// MARK: - Liquid Glass helpers

private extension View {
    /// Whole-card Liquid Glass on macOS 26. Uses `.clear` — the same native
    /// Liquid Glass material with the blur/tint largely removed, so the
    /// desktop shows through much more while keeping the glass edge highlight
    /// and refraction. Falls back to a thin material on older systems.
    @ViewBuilder
    func cluelessCardGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: .rect(cornerRadius: 22))
        } else {
            self.background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    /// Prominent (regular) Liquid Glass slab used for the header and footer so
    /// they read clearly over the see-through body. Rounded on the outer edge
    /// to match the card.
    @ViewBuilder
    func prominentGlass(top: Bool) -> some View {
        let radii = RectangleCornerRadii(
            topLeading: top ? 22 : 0,
            bottomLeading: top ? 0 : 22,
            bottomTrailing: top ? 0 : 22,
            topTrailing: top ? 22 : 0
        )
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: UnevenRoundedRectangle(cornerRadii: radii, style: .continuous))
        } else {
            self.background(.regularMaterial, in: UnevenRoundedRectangle(cornerRadii: radii, style: .continuous))
        }
    }

    /// Inline glass for badges, bubbles, and inputs.
    @ViewBuilder
    func cluelessGlass<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            self.background(.white.opacity(0.10), in: shape)
        }
    }

    /// Glass button style on macOS 26; plain secondary label below.
    @ViewBuilder
    func adaptiveGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}

private extension CaptureAuditor.Status {
    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .unknown: return .secondary
        }
    }
}
