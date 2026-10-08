import Foundation

/// OpenRouter API client.
///
/// Chat: POST /api/v1/chat/completions with SSE streaming. Vision works by
/// attaching a JPEG data-URL part; audio transcription works by attaching an
/// `input_audio` part to a model that accepts audio input (e.g. Whisper).
struct OpenRouterClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case http(status: Int, body: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No OpenRouter API key. Add one in Settings."
            case .http(let status, let body):
                return "OpenRouter error \(status): \(body.prefix(300))"
            case .malformedResponse:
                return "Unexpected response from OpenRouter."
            }
        }
    }

    // MARK: - Request schema

    enum ContentPart: Encodable {
        case text(String)
        case imageJPEG(Data)
        case audioWAV(Data)

        private enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
            case inputAudio = "input_audio"
        }
        private struct ImageURL: Encodable { let url: String }
        private struct InputAudio: Encodable { let data: String; let format: String }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let string):
                try container.encode("text", forKey: .type)
                try container.encode(string, forKey: .text)
            case .imageJPEG(let data):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURL(url: "data:image/jpeg;base64,\(data.base64EncodedString())"), forKey: .imageURL)
            case .audioWAV(let data):
                try container.encode("input_audio", forKey: .type)
                try container.encode(InputAudio(data: data.base64EncodedString(), format: "wav"), forKey: .inputAudio)
            }
        }
    }

    struct APIMessage: Encodable {
        let role: String
        let content: [ContentPart]

        static func system(_ text: String) -> APIMessage { APIMessage(role: "system", content: [.text(text)]) }
        static func user(_ text: String) -> APIMessage { APIMessage(role: "user", content: [.text(text)]) }
        static func assistant(_ text: String) -> APIMessage { APIMessage(role: "assistant", content: [.text(text)]) }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [APIMessage]
        let stream: Bool
    }

    // MARK: - Response schema

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }
        let choices: [Choice]
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]
    }

    // MARK: - Endpoints

    static let defaultBaseURL = "https://openrouter.ai/api/v1"

    private static func chatCompletionsURL(baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = trimmed.isEmpty ? defaultBaseURL : trimmed
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw ClientError.malformedResponse
        }
        return url
    }

    private func makeRequest(body: ChatRequest, apiKey: String, baseURL: String) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }
        var request = URLRequest(url: try Self.chatCompletionsURL(baseURL: baseURL), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Streams assistant tokens as they arrive.
    func streamChat(
        messages: [APIMessage],
        model: String,
        apiKey: String,
        baseURL: String = defaultBaseURL
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        body: ChatRequest(model: model, messages: messages, stream: true),
                        apiKey: apiKey,
                        baseURL: baseURL
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await validate(response, bytes: bytes)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst("data: ".count)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                              let delta = chunk.choices.first?.delta?.content,
                              !delta.isEmpty else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot completion — used for audio transcription.
    func transcribe(audio wav: Data, model: String, apiKey: String, baseURL: String = defaultBaseURL) async throws -> String {
        let request = try makeRequest(
            body: ChatRequest(
                model: model,
                messages: [.init(role: "user", content: [
                    .text("Transcribe the audio verbatim. Output only the transcription — no commentary, no timestamps, no labels."),
                    .audioWAV(wav)
                ])],
                stream: false
            ),
            apiKey: apiKey,
            baseURL: baseURL
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let text = decoded.choices.first?.message?.content else {
            throw ClientError.malformedResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Throws for non-2xx before consuming the body stream.
    private func validate(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw ClientError.http(status: status, body: String(data: body, encoding: .utf8) ?? "")
        }
    }
}
