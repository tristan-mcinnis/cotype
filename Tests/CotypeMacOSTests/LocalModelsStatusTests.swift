import XCTest
import CotypeCore
@testable import CotypeMacOS

final class LocalModelsStatusTests: XCTestCase {

    private let configuredAlias = DaemonRoutedEngine.defaultModel

    // MARK: - Pure decoder seam (fixture, no transport)

    func testDecodeReachableRegisteredWarmWithEndpoint() throws {
        let data = Data("""
        {"default":"gemma-it","models":[
          {"id":"gemma-it","backend":"llama-gguf","capabilities":["completion"],
           "path":"~/Models/gguf/gemma.gguf","warm":true,"backend_available":true,
           "endpoint":"http://127.0.0.1:8079"}
        ]}
        """.utf8)

        let status = LocalModelsStatusClient.decode(data, configuredModelAlias: configuredAlias)
        XCTAssertTrue(status.isReachable)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.modelIDs, ["gemma-it"])
        XCTAssertTrue(status.isConfiguredModelRegistered)
        XCTAssertTrue(status.isConfiguredModelWarm)
        XCTAssertEqual(status.endpoint(for: "gemma-it"), "http://127.0.0.1:8079")
    }

    func testDecodeRegisteredButCold() throws {
        let data = Data("""
        {"models":[
          {"id":"gemma-it","warm":false,"endpoint":"http://127.0.0.1:8079"}
        ]}
        """.utf8)

        let status = LocalModelsStatusClient.decode(data, configuredModelAlias: configuredAlias)
        XCTAssertTrue(status.isReachable)
        XCTAssertTrue(status.isConfiguredModelRegistered)
        XCTAssertFalse(status.isConfiguredModelWarm)
        XCTAssertEqual(status.warmModelIDs, [])
    }

    func testDecodeConfiguredAliasAbsent() throws {
        let data = Data("""
        {"models":[
          {"id":"qwen3-vl","warm":true,"endpoint":"http://127.0.0.1:8080"}
        ]}
        """.utf8)

        let status = LocalModelsStatusClient.decode(data, configuredModelAlias: configuredAlias)
        XCTAssertTrue(status.isReachable)
        XCTAssertFalse(status.isConfiguredModelRegistered)
        XCTAssertFalse(status.isConfiguredModelWarm)
    }

    func testDecodeEmptyModelsIsReachableButNotRegistered() throws {
        let data = Data(#"{"default":"gemma-it","models":[]}"#.utf8)
        let status = LocalModelsStatusClient.decode(data, configuredModelAlias: configuredAlias)
        XCTAssertTrue(status.isReachable)
        XCTAssertTrue(status.modelIDs.isEmpty)
        XCTAssertFalse(status.isConfiguredModelRegistered)
    }

    func testDecodeInvalidJSONIsUnreachable() throws {
        let data = Data("not json at all".utf8)
        let status = LocalModelsStatusClient.decode(data, configuredModelAlias: configuredAlias)
        XCTAssertFalse(status.isReachable)
        XCTAssertNotNil(status.error)
        XCTAssertFalse(status.isConfiguredModelRegistered)
        XCTAssertFalse(status.isConfiguredModelWarm)
    }

    // MARK: - Registry-routed completion endpoint policy

    func testCompletionBaseURLUsesAdvertisedEndpointAndAppendsV1() throws {
        let status = LocalModelsStatus(
            configuredModelAlias: configuredAlias,
            modelIDs: [configuredAlias],
            warmModelIDs: [configuredAlias],
            endpointsByID: [configuredAlias: "http://127.0.0.1:9123"],
            isReachable: true
        )
        let url = try LocalModelsCompletionEngine.completionBaseURL(status: status, modelAlias: configuredAlias)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:9123/v1")
    }

    func testCompletionBaseURLPreservesExistingV1Path() throws {
        let status = LocalModelsStatus(
            configuredModelAlias: configuredAlias,
            modelIDs: [configuredAlias],
            warmModelIDs: [configuredAlias],
            endpointsByID: [configuredAlias: "http://localhost:8079/v1"],
            isReachable: true
        )
        let url = try LocalModelsCompletionEngine.completionBaseURL(status: status, modelAlias: configuredAlias)
        XCTAssertEqual(url.absoluteString, "http://localhost:8079/v1")
    }

    func testCompletionBaseURLRejectsRemoteEndpoint() {
        let status = LocalModelsStatus(
            configuredModelAlias: configuredAlias,
            modelIDs: [configuredAlias],
            warmModelIDs: [configuredAlias],
            endpointsByID: [configuredAlias: "https://remote.example/v1"],
            isReachable: true
        )
        XCTAssertThrowsError(try LocalModelsCompletionEngine.completionBaseURL(status: status, modelAlias: configuredAlias)) { error in
            XCTAssertEqual(error as? LocalModelsCompletionError, .unsafeOrMissingEndpoint(configuredAlias))
        }
    }

    func testCompletionBaseURLRequiresWarmConfiguredModel() {
        let status = LocalModelsStatus(
            configuredModelAlias: configuredAlias,
            modelIDs: [configuredAlias],
            warmModelIDs: [],
            endpointsByID: [configuredAlias: "http://127.0.0.1:8079"],
            isReachable: true
        )
        XCTAssertThrowsError(try LocalModelsCompletionEngine.completionBaseURL(status: status, modelAlias: configuredAlias)) { error in
            XCTAssertEqual(error as? LocalModelsCompletionError, .modelNotWarm(configuredAlias))
        }
    }

    // MARK: - Client via URLProtocol

    func testFetchStatusReachableParsesModelsPathAndBody() async throws {
        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data("""
            {"default":"gemma-it","models":[
              {"id":"gemma-it","warm":true,"endpoint":"http://127.0.0.1:8079"}
            ]}
            """.utf8)
            return (response, body)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LocalModelsStatusClient(session: session)
        let status = await client.fetchStatus()
        XCTAssertTrue(status.isReachable)
        XCTAssertNil(status.error)
        XCTAssertTrue(status.isConfiguredModelRegistered)
        XCTAssertTrue(status.isConfiguredModelWarm)
    }

    /// A status read must be a plain, uncached GET against loopback with a short
    /// timeout, so a wedged daemon cannot park a refresh on URLSession's default
    /// 60-second timeout.
    func testFetchStatusIssuesLoopbackGETWithShortTimeout() async throws {
        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.timeoutInterval, 3, accuracy: 0.01)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"models":[]}"#.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LocalModelsStatusClient(session: session)
        let status = await client.fetchStatus()
        XCTAssertTrue(status.isReachable)
    }

    func testFetchStatusConnectionFailureIsUnreachable() async throws {
        let session = makeMockSession()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LocalModelsStatusClient(session: session)
        let status = await client.fetchStatus()
        XCTAssertFalse(status.isReachable)
        XCTAssertNotNil(status.error)
        XCTAssertFalse(status.isConfiguredModelRegistered)
        XCTAssertFalse(status.isConfiguredModelWarm)
    }

    func testFetchStatusHTTPErrorIsUnreachable() async throws {
        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("boom".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LocalModelsStatusClient(session: session)
        let status = await client.fetchStatus()
        XCTAssertFalse(status.isReachable)
        XCTAssertNotNil(status.error)
        XCTAssertFalse(status.isConfiguredModelRegistered)
    }

    /// Privacy: a control plane that is not loopback is refused before any
    /// request leaves the machine.
    func testFetchStatusRefusesNonLoopbackControlPlane() async {
        let session = makeMockSession()
        var handlerRan = false
        MockURLProtocol.requestHandler = { request in
            handlerRan = true
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"models":[]}"#.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LocalModelsStatusClient(
            baseURL: URL(string: "https://remote.example")!,
            session: session
        )
        let status = await client.fetchStatus()
        XCTAssertFalse(status.isReachable)
        XCTAssertNotNil(status.error)
        XCTAssertFalse(handlerRan, "a non-loopback control plane must never be contacted")
    }

    /// Cancelling a status read tears the HTTP request down instead of letting
    /// URLSession's default timeout hold it open.
    func testCancellingAStatusReadTearsDownTheRequest() async throws {
        let session = makeMockSession(protocolClasses: [HangingURLProtocol.self])
        defer { session.invalidateAndCancel() }
        let started = expectation(description: "status request started")
        let stopped = expectation(description: "status request torn down")
        HangingURLProtocol.started = started
        HangingURLProtocol.stopped = stopped
        defer {
            HangingURLProtocol.started = nil
            HangingURLProtocol.stopped = nil
        }

        let client = LocalModelsStatusClient(session: session)
        let read = Task { await client.fetchStatus() }
        await fulfillment(of: [started], timeout: 2)

        read.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        _ = await read.value
    }

    // MARK: - Daemon lane request contract (status route + completion POST)

    /// One manual completion: resolve the registry, then POST a bounded,
    /// deterministic streaming request to the advertised loopback endpoint.
    func testCompletionEnginePostsBoundedRequestToAdvertisedEndpoint() async throws {
        let session = makeMockSession()
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/v1/models":
                let body = Data("""
                {"default":"gemma-it","models":[
                  {"id":"gemma-it","warm":true,"endpoint":"http://127.0.0.1:8079"}
                ]}
                """.utf8)
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body
                )
            case "/v1/chat/completions":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.timeoutInterval, 15, accuracy: 0.01)
                let data = try self.requestBody(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(json["model"] as? String, "gemma-it")
                XCTAssertEqual(json["stream"] as? Bool, true)
                XCTAssertEqual((json["max_tokens"] as? NSNumber)?.intValue, 32)
                XCTAssertEqual((json["temperature"] as? NSNumber)?.doubleValue, 0)
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("data: [DONE]\n\n".utf8)
                )
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        defer { MockURLProtocol.requestHandler = nil }

        let statusClient = LocalModelsStatusClient(configuredModelAlias: configuredAlias, session: session)
        let engine = LocalModelsCompletionEngine(
            modelAlias: configuredAlias,
            maxTokens: 32,
            temperature: 0,
            statusClient: statusClient,
            // Keep-alive is covered by EndToEndPipelineTests; here it must not
            // post to the stubbed session this test asserts paths on.
            warmer: LocalModelsWarmer(transport: { _, _ in }),
            engineFactory: { baseURL, model in
                OpenAICompatibleEngine(
                    name: "local-models-daemon",
                    baseURL: baseURL,
                    model: model,
                    maxTokens: 32,
                    temperature: 0,
                    session: session
                )
            }
        )

        var ended = false
        for try await event in engine.stream(prompt: Prompt(user: "hello")) {
            if case .end = event { ended = true }
        }
        XCTAssertTrue(ended)
    }

    // MARK: - Refresh policy

    /// Appear and Refresh pressed together must produce one daemon read, not two.
    func testConcurrentRefreshesCoalesceIntoOneFetch() async {
        let gate = FetchGate()
        let calls = FetchCounter()
        let refresher = LocalModelsStatusRefresher {
            await calls.increment()
            await gate.markStarted()
            await gate.waitForRelease()
            return Self.reachableStatus(alias: "gemma-it")
        }

        let first = Task { await refresher.refresh() }
        await gate.waitUntilStarted()
        let second = Task { await refresher.refresh() }
        // Let the second call reach the actor while the first read is parked.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let duringFlight = await calls.value()
        XCTAssertEqual(duringFlight, 1)

        await gate.release()
        let firstStatus = await first.value
        let secondStatus = await second.value
        XCTAssertEqual(firstStatus, secondStatus)
        let total = await calls.value()
        XCTAssertEqual(total, 1, "a burst of refreshes must collapse into one daemon read")
    }

    /// A read that already finished must not block the next one.
    func testRefreshAfterCompletionIssuesANewFetch() async {
        let calls = FetchCounter()
        let refresher = LocalModelsStatusRefresher {
            await calls.increment()
            return Self.reachableStatus(alias: "gemma-it")
        }

        _ = await refresher.refresh()
        _ = await refresher.refresh()
        let total = await calls.value()
        XCTAssertEqual(total, 2)
    }

    /// Stopping the monitor abandons the read in flight instead of letting it
    /// finish the request.
    func testCancelInFlightAbandonsTheRunningFetch() async {
        let gate = FetchGate()
        let calls = FetchCounter()
        let refresher = LocalModelsStatusRefresher {
            await calls.increment()
            await gate.markStarted()
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                // Cancelled: the parked read gave up immediately.
            }
            return Self.reachableStatus(alias: "gemma-it")
        }

        let read = Task { await refresher.refresh() }
        await gate.waitUntilStarted()
        let startedAt = ContinuousClock.now
        await refresher.cancelInFlight()
        _ = await read.value
        let elapsed = ContinuousClock.now - startedAt

        let total = await calls.value()
        XCTAssertEqual(total, 1)
        XCTAssertLessThan(elapsed, .seconds(3), "cancellation must abandon the read promptly")
    }

    // MARK: - Helpers

    private static func reachableStatus(alias: String) -> LocalModelsStatus {
        LocalModelsStatus(
            configuredModelAlias: alias,
            modelIDs: [alias],
            warmModelIDs: [alias],
            endpointsByID: [alias: "http://127.0.0.1:8079"],
            isReachable: true
        )
    }

    private func makeMockSession(protocolClasses: [AnyClass] = [MockURLProtocol.self]) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = protocolClasses
        return URLSession(configuration: config)
    }

    /// URLProtocol receives a POST body as a stream, not as `httpBody`.
    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// URLProtocol that hands the request to a scripted handler, so client async
/// fetch/status logic can be tested without a live daemon.
private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// URLProtocol that never answers, so a test can cancel the read and observe the
/// request being torn down. No fixture data is involved.
private final class HangingURLProtocol: URLProtocol {
    // Test-only signals; each test clears them when it finishes.
    nonisolated(unsafe) static var started: XCTestExpectation?
    nonisolated(unsafe) static var stopped: XCTestExpectation?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        HangingURLProtocol.started?.fulfill()
    }

    override func stopLoading() {
        HangingURLProtocol.stopped?.fulfill()
    }
}

/// Coordinates the refresh-policy tests: the injected fetch announces that it
/// started, then parks until the test releases it.
private actor FetchGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters = []
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

/// Counts how many reads actually reached the transport.
private actor FetchCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

// MARK: - Warm on demand

final class LocalModelsWarmerTests: XCTestCase {
    private let controlPlane = URL(string: "http://127.0.0.1:8078")!

    func testWarmRequestIsANonBlockingLoopbackPost() throws {
        let request = try XCTUnwrap(LocalModelsWarmer.warmRequest(modelAlias: "gemma-it", controlPlane: controlPlane))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8078/v1/warm")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gemma-it")
        XCTAssertEqual(body["wait"] as? Bool, false)
        XCTAssertNil(LocalModelsWarmer.warmRequest(modelAlias: "gemma-it", controlPlane: URL(string: "http://example.com")!))
    }

    func testColdRequestsAndKeepAlivesAreRateLimited() async {
        let clock = TestClock()
        let sent = SentCounter()
        let warmer = LocalModelsWarmer(
            warmRetryInterval: 20,
            keepAliveInterval: 600,
            now: { clock.now },
            transport: { _, _ in sent.increment() }
        )
        await warmer.requestWarm(modelAlias: "gemma-it", controlPlane: controlPlane)
        await warmer.lastSend?.value
        await warmer.requestWarm(modelAlias: "gemma-it", controlPlane: controlPlane)
        XCTAssertEqual(sent.value, 1, "a second cold hit within 20 s sends nothing")

        clock.advance(21)
        await warmer.requestWarm(modelAlias: "gemma-it", controlPlane: controlPlane)
        await warmer.lastSend?.value
        XCTAssertEqual(sent.value, 2)

        // A warm request also counts as a keep-alive.
        await warmer.noteUse(modelAlias: "gemma-it", controlPlane: controlPlane)
        XCTAssertEqual(sent.value, 2)
        clock.advance(601)
        await warmer.noteUse(modelAlias: "gemma-it", controlPlane: controlPlane)
        await warmer.lastSend?.value
        XCTAssertEqual(sent.value, 3)
    }
}

private final class TestClock: @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

private final class SentCounter: @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
