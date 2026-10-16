import Foundation

/// A context provider that passes the request through unchanged.
/// Useful for tests and for wiring a real provider later.
public struct StaticContextProvider: ContextProvider {
    public init() {}

    public func provideContext(for request: CompletionRequest) async throws -> CompletionContext {
        CompletionContext(
            prefix: request.prefix,
            suffix: request.suffix,
            language: request.language,
            appIdentifier: request.appIdentifier,
            documentURL: request.documentURL,
            extra: request.extra
        )
    }
}
