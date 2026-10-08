import Foundation

/// User-configurable settings. Model IDs are free text — any OpenRouter model
/// ID works. The API key lives in the Keychain, never in UserDefaults.
@MainActor
@Observable
final class SettingsStore {
    private static let keychainService = "com.clueless.app"
    private static let keychainAccount = "openrouter-api-key"

    static let defaultSystemPrompt = """
        You are Clueless, an assistant living in a small floating overlay on the user's Mac. \
        Answer concisely and directly — short paragraphs or tight bullet points. \
        When analyzing a screenshot, infer the user's goal and give the useful result directly. \
        Answer visible questions, suggest a natural next reply for conversations, and help resolve visible errors. \
        Mention uncertainty when important details are unreadable.
        """

    var chatModelID: String {
        didSet { UserDefaults.standard.set(chatModelID, forKey: "clueless.chatModelID") }
    }
    var transcriptionModelID: String {
        didSet { UserDefaults.standard.set(transcriptionModelID, forKey: "clueless.transcriptionModelID") }
    }
    var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "clueless.systemPrompt") }
    }
    /// OpenAI-compatible base URL. Defaults to OpenRouter.
    var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: "clueless.apiBaseURL") }
    }
    var apiKey: String {
        didSet {
            KeychainStore.set(apiKey.isEmpty ? nil : apiKey,
                              service: Self.keychainService,
                              account: Self.keychainAccount)
            hasAPIKey = !apiKey.isEmpty
        }
    }
    private(set) var hasAPIKey: Bool

    init() {
        let defaults = UserDefaults.standard
        chatModelID = defaults.string(forKey: "clueless.chatModelID") ?? "openai/gpt-5.6-luna"
        transcriptionModelID = defaults.string(forKey: "clueless.transcriptionModelID") ?? "openai/whisper-large-v3-turbo"
        systemPrompt = defaults.string(forKey: "clueless.systemPrompt") ?? Self.defaultSystemPrompt
        apiBaseURL = defaults.string(forKey: "clueless.apiBaseURL") ?? OpenRouterClient.defaultBaseURL
        let key = KeychainStore.get(service: Self.keychainService, account: Self.keychainAccount) ?? ""
        apiKey = key
        hasAPIKey = !key.isEmpty
    }
}
