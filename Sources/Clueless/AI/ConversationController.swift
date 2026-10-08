import AppKit

/// Owns the chat conversation: message history, streaming replies, and
/// screen-context attachments (vision).
///
/// `alwaysUseScreen` is the Cluely-style screen toggle: when on, every sent
/// message automatically captures the display under the overlay and attaches
/// it. A separate shortcut can request screen help without typed text.
@MainActor
@Observable
final class ConversationController {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var apiText: String?
        var attachment: NSImage?
        var attachmentJPEG: Data?
        var isStreaming = false
    }

    private(set) var messages: [Message] = []
    var draft = ""
    private(set) var isSending = false
    private(set) var isCapturingScreen = false
    var errorMessage: String?

    /// Screen toggle: when on, every message carries a fresh screenshot.
    var alwaysUseScreen = true

    private let settings: SettingsStore
    private let client: OpenRouterClient
    private var streamTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureID: UUID?

    private static let screenRequest = """
        Look at this screenshot and infer what help I need. Give the useful result directly, not just a description of the image. If it contains a question, answer it with any necessary reasoning. If it shows a conversation, draft a natural next message I can send. If it shows an error or unfinished task, explain the fix or next step. Be concise and say when important details are unreadable.
        """

    init(settings: SettingsStore, client: OpenRouterClient) {
        self.settings = settings
        self.client = client
    }

    // MARK: - Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isCapturingScreen else { return }

        draft = ""
        errorMessage = nil

        if alwaysUseScreen {
            beginScreenSend(text)
        } else {
            messages.append(Message(role: .user, text: text))
            streamReply()
        }
    }

    /// Explicit screenshot request, independent of the ordinary screen toggle.
    func sendScreenRequest() {
        guard !isSending, !isCapturingScreen else { return }
        let context = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        errorMessage = nil
        let instruction = context.isEmpty ? Self.screenRequest : "\(Self.screenRequest)\n\nMy additional context: \(context)"
        beginScreenSend(context.isEmpty ? "Analyze screen" : context, apiText: instruction)
    }

    private func beginScreenSend(_ text: String, apiText: String? = nil) {
        let id = UUID()
        captureID = id
        isCapturingScreen = true
        captureTask = Task {
            do {
                let shot = try await ScreenCapture.captureDisplay(containing: NSEvent.mouseLocation)
                guard captureID == id, !Task.isCancelled else { return }
                guard let jpeg = shot.jpegData() else {
                    errorMessage = "Could not encode the screenshot. Please try again."
                    isCapturingScreen = false
                    captureID = nil
                    captureTask = nil
                    return
                }
                var message = Message(role: .user, text: text)
                message.apiText = apiText
                message.attachment = shot.nsImage
                message.attachmentJPEG = jpeg
                messages.append(message)
                isCapturingScreen = false
                captureID = nil
                captureTask = nil
                streamReply()
            } catch {
                guard captureID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isCapturingScreen = false
                captureID = nil
                captureTask = nil
            }
        }
    }

    /// Listen-mode quick actions: ask about the rolling transcript.
    func askAboutTranscript(_ instruction: String, transcript: String) {
        guard !transcript.isEmpty, !isSending, !isCapturingScreen else { return }
        messages.append(Message(
            role: .user,
            text: "\(instruction)\n\nTranscript so far:\n\"\"\"\n\(transcript)\n\"\"\""
        ))
        errorMessage = nil
        streamReply()
    }

    func cancelStream() {
        captureTask?.cancel()
        captureTask = nil
        captureID = nil
        isCapturingScreen = false
        streamTask?.cancel()
        streamTask = nil
        isSending = false
        if let index = messages.lastIndex(where: { $0.isStreaming }) {
            messages[index].isStreaming = false
        }
    }

    func clear() {
        cancelStream()
        messages.removeAll()
        errorMessage = nil
    }

    // MARK: - Streaming

    private func streamReply() {
        guard !isSending else { return }
        isSending = true

        var assistant = Message(role: .assistant, text: "")
        assistant.isStreaming = true
        messages.append(assistant)
        let assistantID = assistant.id

        let apiMessages = buildAPIMessages()
        let model = settings.chatModelID
        let apiKey = settings.apiKey
        let baseURL = settings.apiBaseURL

        streamTask = Task {
            defer { isSending = false }
            do {
                for try await delta in client.streamChat(messages: apiMessages, model: model, apiKey: apiKey, baseURL: baseURL) {
                    guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
                    messages[index].text += delta
                }
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].isStreaming = false
                    if messages[index].text.isEmpty {
                        messages.remove(at: index)
                    }
                }
            } catch {
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    if messages[index].text.isEmpty {
                        messages.remove(at: index)
                    } else {
                        messages[index].isStreaming = false
                    }
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func buildAPIMessages() -> [OpenRouterClient.APIMessage] {
        var out: [OpenRouterClient.APIMessage] = [.system(settings.systemPrompt)]
        for message in messages where !message.isStreaming {
            var parts: [OpenRouterClient.ContentPart] = []
            if let jpeg = message.attachmentJPEG {
                parts.append(.imageJPEG(jpeg))
            }
            let text = message.apiText ?? message.text
            if !text.isEmpty {
                parts.append(.text(text))
            }
            guard !parts.isEmpty else { continue }
            out.append(OpenRouterClient.APIMessage(
                role: message.role == .user ? "user" : "assistant",
                content: parts
            ))
        }
        return out
    }
}
