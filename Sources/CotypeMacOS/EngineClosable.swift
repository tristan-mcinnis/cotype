import Foundation
import CotypeCore

/// An inference engine that can be explicitly closed to free its resources.
///
/// `EngineManager` owns a single cached engine. Making the close contract a
/// protocol (rather than hard-coding `LlamaCppEngine`) lets tests inject a mock
/// engine and lets the manager drive unload deterministically.
public protocol EngineClosable: InferenceEngine, AnyObject {
    /// Free any held resources. Idempotent.
    func close()
    /// A short, stable identifier for the engine (e.g. "llama.cpp").
    var name: String { get }
}

extension LlamaCppEngine: EngineClosable {}
