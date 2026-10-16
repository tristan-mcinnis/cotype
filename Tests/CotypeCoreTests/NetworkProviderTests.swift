import XCTest
@testable import CotypeCore

private final class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Response)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let response = try Self.lock.withLock {
                try XCTUnwrap(Self.handler)(request)
            }
            let http = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            ))
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.body.isEmpty {
                client?.urlProtocol(self, didLoad: response.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class NetworkProviderTests: XCTestCase {
    private var session: URLSession!
    private var directory: URL!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-network-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        StubURLProtocol.lock.withLock { StubURLProtocol.handler = nil }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testModelDescriptorEncodesPathSegments() {
        let descriptor = ModelDescriptor(
            repo: "owner/model name",
            filename: "gemma model.gguf",
            destination: directory.appendingPathComponent("model.gguf")
        )
        XCTAssertEqual(
            descriptor.resolvedURL.absoluteString,
            "https://huggingface.co/owner/model%20name/resolve/main/gemma%20model.gguf"
        )
    }

    func testDownloaderWritesFreshFileAndCompletes() async throws {
        let body = Data("complete model".utf8)
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
                return .init(
                    status: 200,
                    headers: ["Content-Length": "\(body.count)"],
                    body: body
                )
            }
        }

        let destination = directory.appendingPathComponent("fresh.gguf")
        let progress = try await collectDownload(to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertEqual(progress.last?.downloadedBytes, Int64(body.count))
        XCTAssertEqual(progress.last?.isComplete, true)
    }

    func testDownloaderRestartsProgressWhenServerIgnoresRange() async throws {
        let stale = Data(repeating: 1, count: 100)
        let replacement = Data("new model".utf8)
        let destination = directory.appendingPathComponent("restart.gguf")
        try stale.write(to: destination)
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=100-")
                return .init(
                    status: 200,
                    headers: ["Content-Length": "\(replacement.count)"],
                    body: replacement
                )
            }
        }

        let progress = try await collectDownload(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertTrue(progress.allSatisfy { $0.downloadedBytes <= Int64(replacement.count) })
    }

    func testDownloaderResumesAtValidatedOffset() async throws {
        let first = Data("partial-".utf8)
        let rest = Data("model".utf8)
        let destination = directory.appendingPathComponent("resume.gguf")
        try first.write(to: destination)

        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=\(first.count)-")
                return .init(
                    status: 206,
                    headers: [
                        "Content-Range": "bytes \(first.count)-\(first.count + rest.count - 1)/\(first.count + rest.count)",
                        "Content-Length": "\(rest.count)",
                    ],
                    body: rest
                )
            }
        }

        let progress = try await collectDownload(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), first + rest)
        XCTAssertEqual(progress.last?.downloadedBytes, Int64(first.count + rest.count))
        XCTAssertEqual(progress.last?.isComplete, true)
    }

    func testOpenAICompatibleEngineParsesStreamingSSE() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"hello "}}]}

        data: {"choices":[{"delta":{"content":"world"}}]}

        data: [DONE]

        """
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                let body = try self.requestBody(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
                XCTAssertTrue(messages.last?["content"]?.contains("<after_cursor>\nsuffix") == true)
                return .init(status: 200, body: Data(sse.utf8))
            }
        }

        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://example.test/v1")!,
            model: "local",
            apiKey: "secret",
            session: session
        )
        var output = ""
        var ended = false
        for try await event in engine.stream(prompt: Prompt(system: "system", user: "user", suffix: "suffix")) {
            switch event {
            case .token(let token): output += token
            case .end: ended = true
            }
        }
        XCTAssertEqual(output, "hello world")
        XCTAssertTrue(ended)
    }

    /// The daemon lane must send a bounded, deterministic request: a hard token
    /// ceiling and temperature 0 so a completion cannot run away or drift, a
    /// short request timeout so a wedged server cannot hold the trigger, and no
    /// cached response standing in for a live generation.
    func testOpenAICompatibleEngineSendsBoundedStreamingContract() async throws {
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                XCTAssertEqual(request.timeoutInterval, 15, accuracy: 0.01)
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                let body = try self.requestBody(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["stream"] as? Bool, true)
                XCTAssertEqual((json["max_tokens"] as? NSNumber)?.intValue, 32)
                XCTAssertEqual((json["temperature"] as? NSNumber)?.doubleValue, 0)
                return .init(status: 200, body: Data("data: [DONE]\n\n".utf8))
            }
        }
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://example.test/v1")!,
            model: "local",
            session: session
        )
        for try await _ in engine.stream(prompt: Prompt(user: "hello")) {}
    }

    /// Clamp a requested budget/temperature into the engine's bounds so a stray
    /// preference cannot ask the daemon for an unbounded generation.
    func testOpenAICompatibleEngineClampsGenerationBudgetIntoBounds() {
        let url = URL(string: "https://example.test/v1")!
        let defaults = OpenAICompatibleEngine(baseURL: url, model: "local")
        XCTAssertEqual(defaults.maxTokens, 32)
        XCTAssertEqual(defaults.temperature, 0)
        XCTAssertEqual(defaults.requestTimeout, 15, accuracy: 0.01)

        let huge = OpenAICompatibleEngine(baseURL: url, model: "local", maxTokens: 100_000)
        XCTAssertEqual(huge.maxTokens, OpenAICompatibleEngine.maxAllowedTokens)

        let zero = OpenAICompatibleEngine(baseURL: url, model: "local", maxTokens: 0)
        XCTAssertEqual(zero.maxTokens, 1)

        let hot = OpenAICompatibleEngine(baseURL: url, model: "local", temperature: 9)
        XCTAssertEqual(hot.temperature, OpenAICompatibleEngine.maxTemperature)

        let cold = OpenAICompatibleEngine(baseURL: url, model: "local", temperature: -1)
        XCTAssertEqual(cold.temperature, 0)
    }

    func testOpenAICompatibleEngineRejectsHTTPFailure() async throws {
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { _ in .init(status: 500, body: Data("error".utf8)) }
        }
        let engine = OpenAICompatibleEngine(
            baseURL: URL(string: "https://example.test/v1")!,
            model: "local",
            session: session
        )
        do {
            for try await _ in engine.stream(prompt: Prompt(user: "hello")) {}
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testDownloaderTreatsCompleteRangeAsIdempotent() async throws {
        let complete = Data("complete".utf8)
        let destination = directory.appendingPathComponent("complete.gguf")
        try complete.write(to: destination)
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { _ in
                .init(status: 416, headers: ["Content-Range": "bytes */\(complete.count)"])
            }
        }

        let progress = try await collectDownload(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), complete)
        XCTAssertEqual(progress.last?.downloadedBytes, Int64(complete.count))
        XCTAssertEqual(progress.last?.isComplete, true)
    }

    func testDownloaderRejectsMismatchedResumeRangeWithoutCorruptingFile() async throws {
        let partial = Data("safe partial".utf8)
        let destination = directory.appendingPathComponent("mismatch.gguf")
        try partial.write(to: destination)

        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = { _ in
                .init(
                    status: 206,
                    headers: ["Content-Range": "bytes 0-2/3"],
                    body: Data("bad".utf8)
                )
            }
        }

        do {
            _ = try await collectDownload(to: destination)
            XCTFail("Expected rangeMismatch")
        } catch ModelDownloadError.rangeMismatch {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: destination), partial)
    }

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

    private func collectDownload(to destination: URL) async throws -> [DownloadProgress] {
        let descriptor = ModelDescriptor(
            repo: "owner/repo",
            filename: destination.lastPathComponent,
            destination: destination
        )
        var values: [DownloadProgress] = []
        for try await value in GGUFDownloader(session: session).download(descriptor) {
            values.append(value)
        }
        return values
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
