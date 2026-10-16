import Foundation

/// Read-only snapshot of the local-models daemon control plane (127.0.0.1:8078).
///
/// The daemon is the control plane for the Local Models system: it owns the
/// registry, model lifecycle, and warm state. This reports daemon reachability,
/// which model aliases are registered/warm, and each alias's live completion
/// endpoint. Strictly read-only: the client issues only a GET `/v1/models` and
/// never mutates daemon state.
public struct LocalModelsStatus: Equatable {
    /// The completion-model alias the consumer asks about (default "gemma-it").
    public let configuredModelAlias: String
    /// Every registered model alias, in registry order.
    public let modelIDs: [String]
    /// Aliases whose backend currently has the model loaded (warm).
    public let warmModelIDs: [String]
    /// Live completion endpoint per alias as advertised by the daemon (raw, e.g.
    /// "http://127.0.0.1:8079"). The UI and registry-routed streaming consume this.
    public let endpointsByID: [String: String]
    /// True when the daemon answered the control-plane GET.
    public let isReachable: Bool
    /// A user-facing message when the daemon is unreachable or returned bad data.
    public let error: String?

    public init(
        configuredModelAlias: String,
        modelIDs: [String],
        warmModelIDs: [String],
        endpointsByID: [String: String] = [:],
        isReachable: Bool,
        error: String? = nil
    ) {
        self.configuredModelAlias = configuredModelAlias
        self.modelIDs = modelIDs
        self.warmModelIDs = warmModelIDs
        self.endpointsByID = endpointsByID
        self.isReachable = isReachable
        self.error = error
    }

    public var isConfiguredModelRegistered: Bool { isModelRegistered(configuredModelAlias) }
    public var isConfiguredModelWarm: Bool { isModelWarm(configuredModelAlias) }

    public func isModelRegistered(_ alias: String) -> Bool { modelIDs.contains(alias) }
    public func isModelWarm(_ alias: String) -> Bool { warmModelIDs.contains(alias) }

    /// The live completion endpoint the daemon advertises for an alias, or nil.
    public func endpoint(for alias: String) -> String? { endpointsByID[alias] }
}

/// Loopback-only policy for every URL Cotype derives from Local Models.
///
/// Cotype reads editor text; a non-loopback control plane or advertised
/// completion endpoint would send that text off the machine, so both the
/// control plane and the registry-advertised endpoint must be loopback HTTP.
public enum LoopbackPolicy {
    public static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

/// Read-only client for the local-models daemon control plane.
///
/// `fetchStatus()` issues a GET `/v1/models` to the control plane at
/// `http://127.0.0.1:8078` (never the network) and folds the response into a
/// `LocalModelsStatus`. It never warms, unloads, or otherwise mutates the daemon.
public struct LocalModelsStatusClient {
    public static let defaultControlPlaneURL = URL(string: "http://127.0.0.1:8078")!
    /// A status read is a health check, not a load: it gives up quickly so a
    /// wedged daemon cannot park a refresh on URLSession's 60-second default.
    public static let defaultRequestTimeout: TimeInterval = 3

    /// Where GET /v1/models is issued. Defaults to the local control plane.
    public let baseURL: URL
    /// The completion-model alias the UI surface asks about (default `gemma-it`).
    public let configuredModelAlias: String
    /// Per-request timeout for the control-plane GET.
    public let requestTimeout: TimeInterval
    /// Injected so tests can stub the transport (URLProtocol) without a live daemon.
    public let session: URLSession

    public init(
        baseURL: URL = LocalModelsStatusClient.defaultControlPlaneURL,
        configuredModelAlias: String = DaemonRoutedEngine.defaultModel,
        requestTimeout: TimeInterval = LocalModelsStatusClient.defaultRequestTimeout,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.configuredModelAlias = configuredModelAlias
        self.requestTimeout = requestTimeout
        self.session = session
    }

    /// The control-plane GET /v1/models URL.
    public var modelsURL: URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent("models")
    }

    /// The exact GET issued by `fetchStatus()`: uncached, short timeout, no body.
    public var modelsRequest: URLRequest {
        var request = URLRequest(
            url: modelsURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "GET"
        return request
    }

    /// Fetch and fold daemon status into a `LocalModelsStatus`.
    public func fetchStatus() async -> LocalModelsStatus {
        guard LoopbackPolicy.isLoopback(baseURL) else {
            return Self.unreachable(
                configuredModelAlias: configuredModelAlias,
                error: "Local Models must be reached over loopback; \(baseURL.host ?? "this host") is not a loopback address."
            )
        }
        do {
            let (data, response) = try await session.data(for: modelsRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return Self.unreachable(configuredModelAlias: configuredModelAlias, error: "Daemon returned HTTP \(code).")
            }
            return Self.decode(data, configuredModelAlias: configuredModelAlias)
        } catch {
            return Self.unreachable(configuredModelAlias: configuredModelAlias, error: error.localizedDescription)
        }
    }

    /// Pure decoder seam: fold the raw /v1/models JSON body into a status. Public
    /// so it can be fixture-tested without any transport.
    public static func decode(_ data: Data, configuredModelAlias: String) -> LocalModelsStatus {
        do {
            let envelope = try JSONDecoder().decode(ModelsEnvelope.self, from: data)
            let models = envelope.models ?? []
            var endpoints: [String: String] = [:]
            for model in models {
                if let endpoint = model.endpoint { endpoints[model.id] = endpoint }
            }
            return LocalModelsStatus(
                configuredModelAlias: configuredModelAlias,
                modelIDs: models.map(\.id),
                warmModelIDs: models.filter { $0.warm == true }.map(\.id),
                endpointsByID: endpoints,
                isReachable: true,
                error: nil
            )
        } catch {
            return unreachable(configuredModelAlias: configuredModelAlias, error: "Daemon returned an unreadable response.")
        }
    }

    private static func unreachable(configuredModelAlias: String, error: String) -> LocalModelsStatus {
        LocalModelsStatus(
            configuredModelAlias: configuredModelAlias,
            modelIDs: [],
            warmModelIDs: [],
            isReachable: false,
            error: error
        )
    }
}

/// Coalesces reads of the daemon control plane.
///
/// The settings card refreshes when a pane appears and when Refresh is pressed.
/// Without a gate, a burst of those calls would fan out into one GET each. This
/// keeps at most one read in flight and hands every concurrent caller the same
/// result. It owns no timer and no repeating loop: a read runs only when a
/// caller asks for one.
public actor LocalModelsStatusRefresher {
    public typealias Fetch = @Sendable () async -> LocalModelsStatus

    private let fetch: Fetch
    private var inFlight: Task<LocalModelsStatus, Never>?

    /// Seam for tests and for callers that own their transport.
    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public init(client: LocalModelsStatusClient) {
        self.fetch = { await client.fetchStatus() }
    }

    /// The current status, reusing the in-flight read when one is already running.
    public func refresh() async -> LocalModelsStatus {
        if let inFlight { return await inFlight.value }
        let fetch = self.fetch
        let task = Task { await fetch() }
        inFlight = task
        let status = await task.value
        inFlight = nil
        return status
    }

    /// Abandon the in-flight read (in-flight URLSession work is cancelled).
    public func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
    }
}

/// Thinnest Codable slice of the daemon's GET /v1/models body.
private struct ModelsEnvelope: Decodable {
    struct ModelEntry: Decodable {
        let id: String
        let warm: Bool?
        let endpoint: String?
    }
    let `default`: String?
    let models: [ModelEntry]?
}
