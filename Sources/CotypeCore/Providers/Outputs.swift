import Foundation

/// Renders nothing. For headless/tests.
public struct NoopRenderer: CompletionRenderer {
    public init() {}
    public func present(_ candidate: String, for request: CompletionRequest) {}
    public func clear() {}
}

/// Inserts by printing. For CLI demos and tests.
public struct PrintInserter: CompletionInserter {
    public init() {}
    public func insert(_ text: String) async throws {
        print("insert: \(text)")
    }
}
