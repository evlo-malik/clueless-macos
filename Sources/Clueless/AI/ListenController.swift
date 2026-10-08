import Foundation

/// Audio session: one toggle starts continuous capture of the microphone AND
/// system audio together. Speech is VAD-chunked and transcribed through
/// OpenRouter (default openai/whisper-large-v3-turbo) into a rolling
/// transcript until the session is ended.
@MainActor
@Observable
final class ListenController {
    struct TranscriptItem: Identifiable {
        enum Source {
            case microphone
            case systemAudio

            var label: String {
                switch self {
                case .microphone: return "You"
                case .systemAudio: return "Audio"
                }
            }
        }

        let id = UUID()
        let source: Source
        let text: String
        let timestamp = Date()
    }

    private(set) var isSessionActive = false
    private(set) var transcripts: [TranscriptItem] = []
    private(set) var isTranscribing = false
    var micLevel: Float = 0
    var errorMessage: String?

    @ObservationIgnored private let mic = MicRecorder()
    @ObservationIgnored private let systemAudio = SystemAudioRecorder()

    private let settings: SettingsStore
    private let client: OpenRouterClient
    private let conversation: ConversationController

    init(settings: SettingsStore, client: OpenRouterClient, conversation: ConversationController) {
        self.settings = settings
        self.client = client
        self.conversation = conversation

        mic.onUtterance = { [weak self] wav in
            Task { @MainActor in self?.handleUtterance(wav, source: .microphone) }
        }
        mic.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        systemAudio.onUtterance = { [weak self] wav in
            Task { @MainActor in self?.handleUtterance(wav, source: .systemAudio) }
        }
    }

    // MARK: - Session

    /// The waveform button: starts or ends the audio session.
    func toggleSession() {
        isSessionActive ? stopSession() : startSession()
    }

    private func startSession() {
        errorMessage = nil
        Task {
            if !MicRecorder.permissionGranted {
                guard await MicRecorder.requestPermission() else {
                    errorMessage = "Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone."
                    return
                }
            }
            guard ScreenCapture.permissionGranted else {
                ScreenCapture.requestPermission()
                errorMessage = "Screen Recording permission is required for system audio. Grant it in Settings, then relaunch."
                return
            }

            do {
                try mic.start()
                try await systemAudio.start()
                isSessionActive = true
            } catch {
                mic.stop()
                systemAudio.stop()
                errorMessage = "Could not start audio session: \(error.localizedDescription)"
            }
        }
    }

    private func stopSession() {
        mic.stop()
        systemAudio.stop()
        isSessionActive = false
        micLevel = 0
    }

    func stopAll() {
        if isSessionActive { stopSession() }
    }

    // MARK: - Transcription

    private func handleUtterance(_ wav: Data, source: TranscriptItem.Source) {
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                let text = try await client.transcribe(
                    audio: wav,
                    model: settings.transcriptionModelID,
                    apiKey: settings.apiKey,
                    baseURL: settings.apiBaseURL
                )
                guard !text.isEmpty else { return }
                transcripts.append(TranscriptItem(source: source, text: text))
                errorMessage = nil
            } catch {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Quick actions

    func transcriptText(limit: Int = 40) -> String {
        transcripts.suffix(limit)
            .map { "[\($0.timestamp.formatted(date: .omitted, time: .shortened))] \($0.source.label): \($0.text)" }
            .joined(separator: "\n")
    }

    func askAI(_ instruction: String) {
        conversation.askAboutTranscript(instruction, transcript: transcriptText())
    }

    func clearTranscript() {
        transcripts.removeAll()
    }
}
