import Foundation

/// A deterministic engine for tests and demos. Streams a canned response
/// word by word with a small delay.
public struct MockInferenceEngine: InferenceEngine {
    public let name: String
    public var response: String
    public var wordDelayNanoseconds: UInt64

    public init(
        name: String = "mock",
        response: String = "your own completion",
        wordDelayNanoseconds: UInt64 = 30_000_000
    ) {
        self.name = name
        self.response = response
        self.wordDelayNanoseconds = wordDelayNanoseconds
    }

    public func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let words = response.split(separator: " ")
                for (index, word) in words.enumerated() {
                    try? await Task.sleep(nanoseconds: wordDelayNanoseconds)
                    if Task.isCancelled { break }
                    let token = index < words.count - 1 ? "\(word) " : String(word)
                    continuation.yield(.token(token))
                }
                continuation.yield(.end)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A real streaming engine for any OpenAI-compatible `/v1/chat/completions`
/// endpoint: llama-server, LM Studio, Ollama, OpenAI, Anthropic gateways.
public struct OpenAICompatibleEngine: InferenceEngine {
    /// Cotype predicts the next few words (see `SuggestionLength`), so a request asks for a short
    /// continuation rather than leaving the server's default budget unbounded.
    public static let defaultMaxTokens = 32
    /// Hard ceiling on `max_tokens`, whatever a caller passes.
    public static let maxAllowedTokens = 256
    /// Greedy sampling: deterministic completions and a stable eval lane.
    public static let defaultTemperature = 0.0
    public static let maxTemperature = 1.0
    /// A completion request is abandoned after this long, so a wedged server
    /// cannot hold the trigger key hostage on URLSession's 60-second default.
    public static let defaultRequestTimeout: TimeInterval = 15

    /// Clamp a requested token budget into `1...maxAllowedTokens`.
    public static func boundedMaxTokens(_ maxTokens: Int) -> Int {
        min(max(1, maxTokens), maxAllowedTokens)
    }

    /// Clamp a requested temperature into `0...maxTemperature`.
    public static func boundedTemperature(_ temperature: Double) -> Double {
        min(max(0, temperature), maxTemperature)
    }

    public let name: String
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    public let extraHeaders: [String: String]
    /// Effective (clamped) generation budget sent as `max_tokens`.
    public let maxTokens: Int
    /// Effective (clamped) sampling temperature; `0` is greedy.
    public let temperature: Double
    /// Per-request timeout applied to the streaming POST.
    public let requestTimeout: TimeInterval
    private let session: URLSession

    public init(
        name: String = "openai-compatible",
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        maxTokens: Int = OpenAICompatibleEngine.defaultMaxTokens,
        temperature: Double = OpenAICompatibleEngine.defaultTemperature,
        requestTimeout: TimeInterval = OpenAICompatibleEngine.defaultRequestTimeout,
        session: URLSession = .shared
    ) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.maxTokens = OpenAICompatibleEngine.boundedMaxTokens(maxTokens)
        self.temperature = OpenAICompatibleEngine.boundedTemperature(temperature)
        self.requestTimeout = requestTimeout
        self.session = session
    }

    public func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        if let text = prompt.continuation {
            return streamContinuation(text)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL
                        .appendingPathComponent("chat")
                        .appendingPathComponent("completions")
                    var request = URLRequest(
                        url: url,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: requestTimeout
                    )
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let apiKey, !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    for (key, value) in extraHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    var messages: [[String: String]] = []
                    if !prompt.system.isEmpty {
                        messages.append(["role": "system", "content": prompt.system])
                    }
                    messages.append(["role": "user", "content": prompt.userWithSuffixContext])
                    let body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                        "max_tokens": maxTokens,
                        "temperature": temperature,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty
                        else { continue }
                        continuation.yield(.token(content))
                    }
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Plain-text continuation over `/v1/completions` (llama-server): no chat
    /// template, one line, and a grammar that makes the first token begin with
    /// the healed boundary (see `ContinuationPrompt`), which is then stripped.
    func streamContinuation(_ prompt: ContinuationPrompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try continuationRequest(prompt)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    var stripper = ContinuationPrompt.LeadingStripper(prompt.requiredLeading)
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let text = choices.first?["text"] as? String, !text.isEmpty
                        else { continue }
                        let piece = stripper.strip(text)
                        if !piece.isEmpty { continuation.yield(.token(piece)) }
                    }
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The exact `/v1/completions` request for a continuation. Internal so tests
    /// can check the body without a server.
    func continuationRequest(_ prompt: ContinuationPrompt) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("completions")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt.text,
            "stream": true,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stop": ContinuationPrompt.stopSequences,
            // llama-server keeps the shared document prefix in its KV cache
            // between keystrokes; other servers ignore the field.
            "cache_prompt": true,
        ]
        if let grammar = Self.leadingGrammar(prompt.requiredLeading) {
            body["grammar"] = grammar
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// GBNF that forces output to begin with `leading` and then allows anything.
    static func leadingGrammar(_ leading: String) -> String? {
        guard !leading.isEmpty else { return nil }
        let escaped = leading
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "root ::= \"\(escaped)\" [^\\x00]*"
    }
}
