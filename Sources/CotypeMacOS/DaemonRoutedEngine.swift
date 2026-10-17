import Foundation
import CotypeCore

/// Production engine router for the Local Models system.
///
/// When daemon mode is enabled, Cotype asks the loopback control plane for the
/// configured model alias and streams from the warm endpoint advertised by the
/// registry. The control plane and advertised completion endpoint must both be
/// loopback URLs. There is deliberately no silent failover: a down daemon, cold
/// model, bad registry response, or unsafe endpoint surfaces as an error instead
/// of loading the multi-GB in-process model behind the user's back.
public struct DaemonRoutedEngine: InferenceEngine {
    public static let enabledKey = "useLocalModelsDaemon"
    /// Retained only so old preferences can be identified/removed. Streaming no
    /// longer trusts this hidden value; the Local Models registry is authoritative.
    public static let endpointKey = "localModelsDaemonEndpoint"
    public static let modelKey = "localModelsDaemonModel"
    /// Generation-tuning keys. The budget key is the explicit-override value;
    /// `TokenBudget` decides whether it applies at all.
    public static let maxTokensKey = TokenBudget.explicitValueKey
    public static let temperatureKey = "temperature"
    public static let defaultEndpoint = "http://127.0.0.1:8079/v1"
    public static let defaultModel = "gemma-it"

    public let name = "daemon-routed"
    private let fallback: InferenceEngine
    private let defaults: UserDefaults

    public init(fallback: InferenceEngine, defaults: UserDefaults = .standard) {
        self.fallback = fallback
        self.defaults = defaults
    }

    /// The registry-routed daemon engine, or nil only when daemon mode is off.
    /// Enabled mode always returns an engine so invalid/down daemon state cannot
    /// silently fall through to the in-process fallback.
    public static func daemonEngine(defaults: UserDefaults = .standard) -> LocalModelsCompletionEngine? {
        guard defaults.bool(forKey: enabledKey) else { return nil }
        let model = defaults.string(forKey: modelKey) ?? defaultModel
        // One policy decides the budget for every lane; the Settings pane shows
        // exactly this number.
        let maxTokens = TokenBudget.effective(defaults).tokens
        let temperature = defaults.object(forKey: temperatureKey) as? Double ?? OpenAICompatibleEngine.defaultTemperature
        return LocalModelsCompletionEngine(modelAlias: model, maxTokens: maxTokens, temperature: temperature)
    }

    /// The model alias Cotype is configured to complete with.
    public static func configuredModel(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: modelKey) ?? defaultModel
    }

    public static func isDaemonMode(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        if let daemon = Self.daemonEngine(defaults: defaults) {
            return daemon.stream(prompt: prompt)
        }
        return fallback.stream(prompt: prompt)
    }
}

/// Resolves one completion alias through Local Models before every generation.
/// This keeps the menu bar/control plane authoritative when ports or model
/// assignments change and prevents Cotype from sending editor text anywhere
/// except a loopback endpoint.
public struct LocalModelsCompletionEngine: InferenceEngine {
    public let name = "local-models-daemon"
    public let modelAlias: String
    /// Effective (clamped) generation budget for daemon completions.
    public let maxTokens: Int
    /// Effective (clamped) sampling temperature; `0` is greedy.
    public let temperature: Double
    public let statusClient: LocalModelsStatusClient
    /// Asks Local Models to load the model when it is cold and keeps it warm
    /// while Cotype is in use (see `LocalModelsWarmer`).
    public let warmer: LocalModelsWarmer

    private let engineFactory: (URL, String) -> InferenceEngine

    public init(
        modelAlias: String = DaemonRoutedEngine.defaultModel,
        maxTokens: Int = OpenAICompatibleEngine.defaultMaxTokens,
        temperature: Double = OpenAICompatibleEngine.defaultTemperature,
        statusClient: LocalModelsStatusClient? = nil,
        warmer: LocalModelsWarmer = .shared,
        engineFactory: ((URL, String) -> InferenceEngine)? = nil
    ) {
        self.modelAlias = modelAlias
        self.maxTokens = OpenAICompatibleEngine.boundedMaxTokens(maxTokens)
        self.temperature = OpenAICompatibleEngine.boundedTemperature(temperature)
        self.statusClient = statusClient ?? LocalModelsStatusClient(configuredModelAlias: modelAlias)
        self.warmer = warmer
        let maxTokens = self.maxTokens
        let temperature = self.temperature
        self.engineFactory = engineFactory ?? { baseURL, model in
            OpenAICompatibleEngine(
                name: "local-models-daemon",
                baseURL: baseURL,
                model: model,
                maxTokens: maxTokens,
                temperature: temperature
            )
        }
    }

    public func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let status = await statusClient.fetchStatus()
                let controlPlane = statusClient.baseURL
                do {
                    let endpoint: URL
                    do {
                        endpoint = try Self.completionBaseURL(status: status, modelAlias: modelAlias)
                    } catch LocalModelsCompletionError.modelNotWarm(let alias) {
                        // The daemon unloads a model after 30 idle minutes, and
                        // Cotype streams straight from llama-server, which the
                        // daemon does not count as use. Ask it to load the model
                        // now (non-blocking); the next pause in typing gets a
                        // suggestion. Fail this one with a clear reason.
                        await warmer.requestWarm(modelAlias: alias, controlPlane: controlPlane, session: statusClient.session)
                        throw LocalModelsCompletionError.modelNotWarm(alias)
                    }
                    await warmer.noteUse(modelAlias: modelAlias, controlPlane: controlPlane, session: statusClient.session)
                    let engine = engineFactory(endpoint, modelAlias)
                    for try await event in engine.stream(prompt: prompt) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Resolve and validate the registry-advertised endpoint. Public as a pure
    /// test seam and useful to status/UI callers that need the exact same policy.
    public static func completionBaseURL(status: LocalModelsStatus, modelAlias: String) throws -> URL {
        guard status.isReachable else {
            throw LocalModelsCompletionError.daemonUnavailable(status.error)
        }
        guard status.isModelRegistered(modelAlias) else {
            throw LocalModelsCompletionError.modelNotRegistered(modelAlias)
        }
        guard status.isModelWarm(modelAlias) else {
            throw LocalModelsCompletionError.modelNotWarm(modelAlias)
        }
        guard let raw = status.endpoint(for: modelAlias),
              let endpoint = URL(string: raw),
              LoopbackPolicy.isLoopback(endpoint)
        else {
            throw LocalModelsCompletionError.unsafeOrMissingEndpoint(modelAlias)
        }

        if endpoint.path == "/v1" || endpoint.path.hasSuffix("/v1") {
            return endpoint
        }
        return endpoint.appendingPathComponent("v1")
    }
}

public enum LocalModelsCompletionError: LocalizedError, Equatable {
    case daemonUnavailable(String?)
    case modelNotRegistered(String)
    case modelNotWarm(String)
    case unsafeOrMissingEndpoint(String)

    public var errorDescription: String? {
        switch self {
        case .daemonUnavailable:
            return "Local Models is not reachable. Start it from the Local Models menu bar."
        case .modelNotRegistered(let alias):
            return "\(alias) is not registered in Local Models."
        case .modelNotWarm(let alias):
            return "\(alias) is loading in Local Models. Suggestions start in a few seconds."
        case .unsafeOrMissingEndpoint(let alias):
            return "Local Models did not advertise a safe loopback endpoint for \(alias)."
        }
    }
}

/// Keeps the shared completion model loaded while Cotype is used.
///
/// Local Models unloads a backend after `idle_unload_seconds` (30 minutes) of
/// *daemon-routed* use. Cotype streams from llama-server directly for latency,
/// so without this the model went cold mid-day and every suggestion failed
/// with "not loaded" until someone warmed it by hand. Two calls fix that:
///
/// - `requestWarm` when the registry reports the model cold: one non-blocking
///   `POST /v1/warm {"wait": false}`, at most every `warmRetryInterval`.
/// - `noteUse` after a successful routing: the same non-blocking warm at most
///   every `keepAliveInterval`, which stamps the daemon's idle clock (a warm
///   model answers it with an 8-token reply and no reload).
///
/// Loopback-only, like every other Local Models call.
public actor LocalModelsWarmer {
    public static let shared = LocalModelsWarmer()

    /// Sends one warm request. The default posts it on the session the status
    /// client uses, so a test with a stubbed session never reaches a real daemon.
    public typealias Transport = @Sendable (URLRequest, URLSession) async throws -> Void

    public let warmRetryInterval: TimeInterval
    public let keepAliveInterval: TimeInterval
    private let transport: Transport
    private let now: @Sendable () -> Date
    private var lastWarmRequest: [String: Date] = [:]
    private var lastKeepAlive: [String: Date] = [:]

    public init(
        warmRetryInterval: TimeInterval = 20,
        keepAliveInterval: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = { Date() },
        transport: Transport? = nil
    ) {
        self.warmRetryInterval = warmRetryInterval
        self.keepAliveInterval = keepAliveInterval
        self.now = now
        self.transport = transport ?? { request, session in
            _ = try await session.data(for: request)
        }
    }

    /// Ask the daemon to load a cold model (non-blocking).
    public func requestWarm(modelAlias: String, controlPlane: URL, session: URLSession = .shared) {
        let time = now()
        if let last = lastWarmRequest[modelAlias], time.timeIntervalSince(last) < warmRetryInterval { return }
        lastWarmRequest[modelAlias] = time
        lastKeepAlive[modelAlias] = time
        CotypeLog.loop.info("warm: asked Local Models to load \(modelAlias, privacy: .public)")
        send(modelAlias: modelAlias, controlPlane: controlPlane, session: session)
    }

    /// Record a completion routed to a warm model; refresh the daemon's idle
    /// clock when the last refresh is older than `keepAliveInterval`.
    public func noteUse(modelAlias: String, controlPlane: URL, session: URLSession = .shared) {
        let time = now()
        if let last = lastKeepAlive[modelAlias], time.timeIntervalSince(last) < keepAliveInterval { return }
        lastKeepAlive[modelAlias] = time
        CotypeLog.loop.debug("warm: keep-alive for \(modelAlias, privacy: .public)")
        send(modelAlias: modelAlias, controlPlane: controlPlane, session: session)
    }

    /// The exact warm request. Public as a test seam.
    public static func warmRequest(modelAlias: String, controlPlane: URL) -> URLRequest? {
        guard LoopbackPolicy.isLoopback(controlPlane) else { return nil }
        var request = URLRequest(
            url: controlPlane.appendingPathComponent("v1").appendingPathComponent("warm"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 5
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelAlias, "wait": false])
        return request
    }

    /// Fire the warm request without holding up the completion that noticed
    /// the need; the returned task is for tests.
    @discardableResult
    private func send(modelAlias: String, controlPlane: URL, session: URLSession) -> Task<Void, Never>? {
        guard let request = Self.warmRequest(modelAlias: modelAlias, controlPlane: controlPlane) else { return nil }
        let transport = self.transport
        let task = Task.detached {
            do {
                try await transport(request, session)
            } catch {
                CotypeLog.loop.error("warm: request for \(modelAlias, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        lastSend = task
        return task
    }

    /// The most recent warm request, so tests can await delivery.
    public private(set) var lastSend: Task<Void, Never>?
}
