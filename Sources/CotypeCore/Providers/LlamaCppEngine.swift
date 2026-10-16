import Foundation
import llama

// MARK: - llama.cpp log control
//
// llama.cpp logs model-load progress and backend selection to stderr, which is
// noisy in an interactive app. We can install a single process-wide callback
// that forwards only messages at or above a chosen severity. The callback is
// installed once (idempotent) and restored when the last quiet engine closes.

private let llamaLogLock = NSLock()
private var llamaLogInstalled = false
private var llamaLogOriginal: ggml_log_callback?
private var llamaLogOriginalUserData: UnsafeMutableRawPointer?
private var llamaLogThreshold: UInt32 = 4   // GGML_LOG_LEVEL_ERROR (swallow INFO/DEBUG/WARN)

private let llamaLogForward: ggml_log_callback = { level, text, userData in
    guard let text else { return }
    llamaLogLock.lock()
    let forward = level.rawValue >= llamaLogThreshold
    let original = llamaLogOriginal
    let originalUserData = llamaLogOriginalUserData
    llamaLogLock.unlock()
    guard forward else { return }
    if let original {
        original(level, text, originalUserData)
    } else {
        // Free-threaded fallback: write directly to stderr.
        fputs(text, stderr)
    }
}

/// In-process llama.cpp inference engine (Metal-accelerated on Apple Silicon).
///
/// Loads a GGUF model and streams tokens. This is the same class of engine
/// Cotypist uses under the hood, reimplemented as a pluggable `InferenceEngine`
/// so the generation loop is fully observable and replaceable.
public final class LlamaCppEngine: InferenceEngine {

    public enum EngineError: LocalizedError {
        case modelLoadFailed(String)
        case contextCreationFailed
        case tokenizationFailed
        case decodeFailed
        case samplerCreationFailed
        case engineClosed
        case invalidConfiguration(String)

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path): return "Failed to load model at \(path)"
            case .contextCreationFailed: return "Failed to create llama.cpp context"
            case .tokenizationFailed: return "Failed to tokenize prompt"
            case .decodeFailed: return "llama_decode failed"
            case .samplerCreationFailed: return "Failed to create llama.cpp sampler"
            case .engineClosed: return "The llama.cpp engine is already closed"
            case .invalidConfiguration(let message): return "Invalid llama.cpp configuration: \(message)"
            }
        }
    }

    public let name: String

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let nContext: UInt32
    private let nBatch: UInt32
    private let maxTokens: Int32
    private let temperature: Float
    private let topP: Float
    private let stopStrings: [String]
    private let sanitizerConfig: OutputSanitizer.Config
    private let lifecycleLock = NSLock()

    /// Create an engine backed by a local GGUF model.
    ///
    /// - Parameters:
    ///   - path: filesystem path to the `.gguf` file.
    ///   - nCtx: context size in tokens.
    ///   - nBatch: decode batch size (prompt chunks).
    ///   - gpuLayers: number of layers offloaded to Metal. `-1` = all.
    ///   - temperature: `0` gives greedy (deterministic) sampling.
    ///   - stopStrings: stop sequences that halt generation.
    ///   - quietLogs: when `true`, install a llama.cpp log filter that silences
    ///     INFO/DEBUG backend chatter, forwarding only WARN and above. The
    ///     original logger is restored when the engine closes.
    public init(
        path: String,
        name: String = "llama.cpp",
        nCtx: UInt32 = 4096,
        nBatch: UInt32 = 512,
        gpuLayers: Int32 = -1,
        maxTokens: Int32 = 256,
        temperature: Float = 0.0,
        topP: Float = 0.95,
        stopStrings: [String] = ["\n\n", "```"],
        quietLogs: Bool = false
    ) throws {
        guard nCtx > 1 else { throw EngineError.invalidConfiguration("nCtx must be greater than 1") }
        guard nBatch > 0 else { throw EngineError.invalidConfiguration("nBatch must be greater than 0") }
        guard maxTokens > 0 else { throw EngineError.invalidConfiguration("maxTokens must be greater than 0") }
        self.name = name
        self.nContext = nCtx
        self.nBatch = nBatch
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopStrings = stopStrings
        if stopStrings.isEmpty {
            self.sanitizerConfig = OutputSanitizer.Config(
                stopSequences: OutputSanitizer.Config.defaultStopSequences)
        } else {
            self.sanitizerConfig = OutputSanitizer.Config(stopSequences: stopStrings)
        }
        if quietLogs { Self.installQuietLogging() }

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = gpuLayers
        guard let loaded = llama_model_load_from_file(path, mparams) else {
            throw EngineError.modelLoadFailed(path)
        }
        self.model = loaded
        guard let loadedVocab = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            throw EngineError.modelLoadFailed(path)
        }
        self.vocab = loadedVocab

        var cparams = llama_context_default_params()
        cparams.n_ctx = nCtx
        cparams.n_batch = nBatch
        cparams.n_ubatch = min(nBatch, 512)
        guard let ctx = llama_init_from_model(loaded, cparams) else {
            llama_model_free(loaded)
            throw EngineError.contextCreationFailed
        }
        self.context = ctx
    }

    private var closed = false

    deinit {
        close()
    }

    /// Free the model and context. Idempotent; call it explicitly before
    /// process teardown so Metal resources are released cleanly.
    public func close() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !closed else { return }
        closed = true
        llama_free(context)
        llama_model_free(model)
        Self.restoreLogging()
    }

    public func stream(prompt: Prompt) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.generate(prompt) { piece in
                        continuation.yield(.token(piece))
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

    // MARK: - Generation loop

    private func generate(_ prompt: Prompt, onToken: (String) -> Void) throws {
        // A llama context is mutable and cannot decode two requests at once.
        // The lock also prevents close() from releasing Metal resources while a
        // completion is active.
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !closed else { throw EngineError.engineClosed }

        // Start each completion from an empty KV cache so consecutive
        // completions on a shared engine never leak context into each other.
        if let mem = llama_get_memory(context) {
            llama_memory_clear(mem, true)
        }
        let inputLimit = max(1, Int(nContext) - Int(maxTokens))

        if let continuation = prompt.continuation {
            try continueText(continuation, inputLimit: inputLimit, onToken: onToken)
            return
        }

        // Accessibility APIs can expose an entire document. Truncate the prompt
        // so it cannot overflow llama.cpp's KV cache, while preserving the Gemma
        // system/user/model header structure and the nearest-to-caret content.
        // A naive suffix-only token truncation can drop the `<|turn>user` header
        // and leave a malformed turn that the model ends immediately.
        var tokens = try tokenize(Self.formatGemmaPrompt(prompt))
        guard !tokens.isEmpty else { return }
        if tokens.count > inputLimit {
            var charBudget = inputLimit * 3 // ~3 chars/token estimate for mixed content
            var truncated = prompt
            for _ in 0..<8 {
                truncated = Self.truncatingForContext(prompt, maxChars: charBudget)
                tokens = try tokenize(Self.formatGemmaPrompt(truncated))
                guard !tokens.isEmpty else { return }
                if tokens.count <= inputLimit { break }
                charBudget = max(64, charBudget * 4 / 5)
            }
            if tokens.count > inputLimit {
                // Last-resort fallback: keep BOS + the nearest-to-caret tail.
                let bos = tokens[0]
                tokens = inputLimit == 1
                    ? [bos]
                    : [bos] + tokens.suffix(inputLimit - 1)
            }
        }

        let sampler = try makeSampler()
        defer { llama_sampler_free(sampler) }

        // Seed the KV cache with the prompt.
        try decode(tokens)

        // Sample one token at a time, streaming pieces through a boundary guard
        // so a partial delimiter (e.g. `<|tur`) is never emitted before it
        // resolves into either a real control token (cut) or ordinary text.
        var streamGuard = StreamingOutputGuard(config: sanitizerConfig)
        var generated = 0

        let generationLimit = min(maxTokens, Int32(max(0, Int(nContext) - tokens.count)))
        while generated < generationLimit {
            if Task.isCancelled { break }
            let token = llama_sampler_sample(sampler, context, -1)
            let raw = tokenPiece(token, special: true)

            // End of turn / template leakage as a SINGLE special token. Stop
            // without accepting the delimiter so it never enters the stream.
            if llama_vocab_is_eog(vocab, token) || Self.isTurnDelimiter(raw) {
                break
            }

            llama_sampler_accept(sampler, token)
            generated += 1

            // Advance the KV cache for every accepted token.
            try decode([token])

            // Thinking / tool / multimodal channel content: drop the marker
            // token but keep generating. The streaming guard also drops any
            // literal-text channel tag the model emits as plain text.
            if Self.isStructuralToken(raw) { continue }

            let piece = tokenPiece(token)
            let emitted = streamGuard.append(piece)
            if !emitted.isEmpty { onToken(emitted) }
            if streamGuard.isStopped { break }
        }

        // Flush any text held back for boundary detection, minus a trailing
        // partial control token.
        let flushed = streamGuard.finish()
        if !flushed.isEmpty { onToken(flushed) }
    }

    /// Plain-text continuation: no chat template, stop at the line end, and a
    /// token-healed first step (see `ContinuationPrompt`). Caller holds the
    /// lifecycle lock and has cleared the KV cache.
    private func continueText(_ prompt: ContinuationPrompt, inputLimit: Int, onToken: (String) -> Void) throws {
        // Document text is data: never parse it into control tokens.
        var tokens = try tokenize(prompt.text, parseSpecial: false)
        guard !tokens.isEmpty else { return }
        if tokens.count > inputLimit {
            // Keep BOS and the text nearest the caret.
            let bos = tokens[0]
            tokens = inputLimit == 1 ? [bos] : [bos] + tokens.suffix(inputLimit - 1)
        }

        let sampler = try makeSampler()
        defer { llama_sampler_free(sampler) }
        try decode(tokens)

        var config = sanitizerConfig
        config.stopSequences = ContinuationPrompt.stopSequences
        var streamGuard = StreamingOutputGuard(config: config)
        var stripper = ContinuationPrompt.LeadingStripper(prompt.requiredLeading)
        var generated = 0
        let generationLimit = min(maxTokens, Int32(max(0, Int(nContext) - tokens.count)))

        while generated < generationLimit {
            if Task.isCancelled { break }
            let token: llama_token
            if generated == 0, !prompt.requiredLeading.isEmpty,
               let healed = bestToken(startingWith: prompt.requiredLeading) {
                token = healed
            } else {
                token = llama_sampler_sample(sampler, context, -1)
            }
            let raw = tokenPiece(token, special: true)
            if llama_vocab_is_eog(vocab, token) || Self.isTurnDelimiter(raw) { break }

            llama_sampler_accept(sampler, token)
            generated += 1
            try decode([token])
            if Self.isStructuralToken(raw) { continue }

            let piece = stripper.strip(tokenPiece(token))
            let emitted = streamGuard.append(piece)
            if !emitted.isEmpty { onToken(emitted) }
            if streamGuard.isStopped { break }
        }
        let flushed = streamGuard.finish()
        if !flushed.isEmpty { onToken(flushed) }
    }

    /// Token ids whose text starts with a given boundary string, cached per
    /// boundary (one vocabulary scan, then free). Only touched under
    /// `lifecycleLock`, like the llama context itself.
    private var boundaryTokenCache: [String: [Bool]] = [:]

    /// The highest-scoring next token whose text begins with `leading` (token
    /// healing). Nil when no token qualifies, so the caller samples normally.
    private func bestToken(startingWith leading: String) -> llama_token? {
        let count = Int(llama_vocab_n_tokens(vocab))
        guard count > 0, let logits = llama_get_logits_ith(context, -1) else { return nil }
        let allowed: [Bool]
        if let cached = boundaryTokenCache[leading] {
            allowed = cached
        } else {
            var mask = [Bool](repeating: false, count: count)
            for id in 0..<count {
                let token = llama_token(id)
                if llama_vocab_is_control(vocab, token) { continue }
                let piece = tokenPiece(token)
                mask[id] = piece.count > leading.count ? piece.hasPrefix(leading) : false
            }
            boundaryTokenCache[leading] = mask
            allowed = mask
        }
        var best: Int?
        var bestLogit = -Float.infinity
        for id in 0..<count where allowed[id] && logits[id] > bestLogit {
            best = id
            bestLogit = logits[id]
        }
        return best.map { llama_token($0) }
    }

    // MARK: - llama.cpp log control

    /// Install a process-wide llama.cpp log callback that forwards only messages
    /// at or above WARN. Idempotent; the original callback is captured so it can
    /// be restored by `restoreLogging()`.
    private static func installQuietLogging() {
        llamaLogLock.lock()
        defer { llamaLogLock.unlock() }
        guard !llamaLogInstalled else { return }
        let captured = llama_log_get_capture()
        llamaLogOriginal = captured.callback
        llamaLogOriginalUserData = captured.userData
        llama_log_set(llamaLogForward, nil)
        llamaLogInstalled = true
    }

    /// Restore the original llama.cpp logger (no-op if quiet logging was never
    /// installed, or was already restored).
    private static func restoreLogging() {
        llamaLogLock.lock()
        defer { llamaLogLock.unlock() }
        guard llamaLogInstalled else { return }
        llama_log_set(llamaLogOriginal, llamaLogOriginalUserData)
        llamaLogInstalled = false
        llamaLogOriginal = nil
        llamaLogOriginalUserData = nil
    }

    /// Capture the currently-installed log callback and its user data, wrapping
    /// `llama_log_get`'s two-out-pointer signature.
    private static func llama_log_get_capture() -> (callback: ggml_log_callback?, userData: UnsafeMutableRawPointer?) {
        var callback: ggml_log_callback?
        var userData: UnsafeMutableRawPointer?
        llama_log_get(&callback, &userData)
        return (callback, userData)
    }

    // MARK: - llama.cpp helpers

    static func formatGemmaPrompt(_ prompt: Prompt) -> String {
        // Gemma 4 control-token format (see ai.google.dev/gemma/docs/core/prompt-formatting-gemma4).
        var text = ""
        if !prompt.system.isEmpty {
            text += "<|turn>system\n\(prompt.system)<turn|>\n"
        }
        text += "<|turn>user\n\(prompt.userWithSuffixContext)<turn|>\n"
        text += "<|turn>model\n"
        return text
    }

    /// Truncate the user content so the formatted Gemma prompt stays within a
    /// roughly `maxChars`-character budget while preserving the system/user/model
    /// header structure.
    ///
    /// A naive token truncation keeps only the suffix of the prompt, which can
    /// drop the `<|turn>user` opening and leave a malformed turn the model treats
    /// as an immediate end-of-turn. Instead, only the *content* — the `user`
    /// text furthest from the caret — is trimmed from the front; the header
    /// markers, the nearest-to-caret tail, and any FIM suffix block are kept.
    static func truncatingForContext(_ prompt: Prompt, maxChars: Int) -> Prompt {
        // Fixed structural overhead (headers / turn markers / infill wrapper
        // tags), not content. Measure it with a one-character probe so a huge
        // suffix cannot itself be counted as "overhead" and escape truncation.
        let hasSystem = !prompt.system.isEmpty
        let hasSuffix = prompt.suffix?.isEmpty == false
        let probe = Prompt(system: hasSystem ? "s" : "", user: "", suffix: hasSuffix ? "x" : nil)
        let overhead = max(
            0,
            formatGemmaPrompt(probe).count - (hasSystem ? 1 : 0) - (hasSuffix ? 1 : 0)
        )
        let budget = max(64, maxChars - overhead)

        var system = prompt.system
        var suffix = prompt.suffix ?? ""
        var user = prompt.user

        // Allocate one total content budget across system + nearest suffix + nearest
        // prefix, preserving the header/tag structure.
        var remaining = budget
        if system.count > remaining {
            system = String(system.prefix(remaining))
            remaining = 0
        } else {
            remaining -= system.count
        }
        if suffix.count > remaining {
            // Keep the LEADING chars (nearest the caret) of the suffix.
            suffix = String(suffix.prefix(remaining))
            user = ""  // no content budget left for the prefix
        } else {
            remaining -= suffix.count
            if user.count > remaining {
                // Keep the TRAILING chars (nearest the caret) of the prefix.
                user = String(user.suffix(remaining))
            }
        }

        return Prompt(system: system, user: user, suffix: suffix.isEmpty ? nil : suffix)
    }

    private func tokenize(_ text: String, parseSpecial: Bool = true) throws -> [llama_token] {
        let capacity = Int32(text.utf8.count + 32)
        var tokens = [llama_token](repeating: 0, count: Int(capacity))
        let count = text.withCString { ptr in
            llama_tokenize(vocab, ptr, Int32(text.utf8.count), &tokens, capacity, true, parseSpecial)
        }
        if count < 0 { throw EngineError.tokenizationFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func decode(_ tokens: [llama_token]) throws {
        var index = 0
        while index < tokens.count {
            let chunk = Array(tokens[index..<min(index + Int(nBatch), tokens.count)])
            var mutable = chunk
            let rc = mutable.withUnsafeMutableBufferPointer { buf -> Int32 in
                let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
                return llama_decode(context, batch)
            }
            if rc != 0 { throw EngineError.decodeFailed }
            index += chunk.count
        }
    }

    private func makeSampler() throws -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else {
            throw EngineError.samplerCreationFailed
        }

        func add(_ sampler: UnsafeMutablePointer<llama_sampler>?) throws {
            guard let sampler else { throw EngineError.samplerCreationFailed }
            llama_sampler_chain_add(chain, sampler)
        }

        do {
            // Repetition penalty up front so it applies to the logits before sampling.
            try add(llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
            if temperature <= 0 {
                try add(llama_sampler_init_greedy())
            } else {
                try add(llama_sampler_init_temp(temperature))
                try add(llama_sampler_init_top_p(topP, 1))
            }
            return chain
        } catch {
            llama_sampler_free(chain)
            throw error
        }
    }

    private func tokenPiece(_ token: llama_token, special: Bool = false) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let written = buf.withUnsafeMutableBufferPointer { ptr in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(ptr.count), 0, special)
        }
        guard written > 0 else { return "" }
        return String(decoding: buf.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Gemma 4 structural channel/tool tokens that must not leak into output.
    private static let structuralPrefixes: [String] = [
        "<|channel", "<channel", "<|tool", "<tool", "<|think",
        "<|image", "<|audio", "<|\"",
    ]

    static func isStructuralToken(_ raw: String) -> Bool {
        guard raw.hasPrefix("<") else { return false }
        return structuralPrefixes.contains { raw.hasPrefix($0) }
    }

    /// True when a single token is a Gemma turn delimiter that must stop
    /// generation (the `<|turn>` / `<turn|>` control tokens in both forms).
    static func isTurnDelimiter(_ raw: String) -> Bool {
        raw.contains("<|turn>") || raw.contains("<turn|>")
    }

    // MARK: - Default model location

    /// First existing supported model for the legacy standalone lane. The
    /// app-managed copy takes priority, then the Local Models GGUF directory,
    /// with the old `~/models` root retained for backwards compatibility.
    public static func defaultModelPath() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let directories = [
            home.appendingPathComponent("Library/Application Support/Cotype/Models"),
            home.appendingPathComponent("Models/gguf"),
            home.appendingPathComponent("models"),
        ]
        let candidates = [
            "gemma-4-E2B-it-Q4_K_M.gguf",
        ]
        for directory in directories {
            for name in candidates {
                let url = directory.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url.path }
            }
        }
        return nil
    }
}
