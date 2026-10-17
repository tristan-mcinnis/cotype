import Foundation

/// Why a completion that was requested never reached the screen.
///
/// Every case marks one early return between "a completion was requested" and
/// "ghost text is on screen". The raw value is the key in `not-shown.json`, so
/// renaming a case changes the file shape.
public enum NotShownReason: String, CaseIterable, Codable, Sendable {
    case completionsDisabled
    case appDisabled
    case noModel
    case noFocusedEditor
    case secureField
    case protectedContent
    case sensitiveApp
    case userExcludedApp
    case unreadableContext
    case engineFailure
    case cancelledWhileGenerating
    case abstainedInsideWord
    case emptyCompletion
    case focusChangedDuringGeneration
    case focusMismatchAtRender
    case noCaretGeometry
    case ghostDoesNotFit

    public init(gate category: SensitiveContextCategory) {
        switch category {
        case .secureTextField: self = .secureField
        case .protectedContent: self = .protectedContent
        case .sensitiveApp: self = .sensitiveApp
        case .userExcludedApp: self = .userExcludedApp
        }
    }

    public var title: String {
        switch self {
        case .completionsDisabled: return "Completions switched off"
        case .appDisabled: return "App turned off"
        case .noModel: return "No model installed"
        case .noFocusedEditor: return "No focused editor found"
        case .secureField: return "Secure text field"
        case .protectedContent: return "Protected content"
        case .sensitiveApp: return "Sensitive app"
        case .userExcludedApp: return "Excluded app"
        case .unreadableContext: return "Text not readable"
        case .engineFailure: return "Model or engine error"
        case .cancelledWhileGenerating: return "Cancelled before a result"
        case .abstainedInsideWord: return "Caret inside a word"
        case .emptyCompletion: return "Model gave nothing usable"
        case .focusChangedDuringGeneration: return "Focus moved during generation"
        case .focusMismatchAtRender: return "Focus moved before drawing"
        case .noCaretGeometry: return "No caret position from the app"
        case .ghostDoesNotFit: return "Ghost does not fit the field"
        }
    }
}

/// Content-free record of why completions were not shown: counts, reason codes,
/// bundle identifiers and timestamps only. No typed text, completion text, or
/// window titles ever reach this type.
public struct NotShownSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public var count: Int
        public var lastSeen: Date
    }

    public var schemaVersion: Int
    public var updatedAt: Date
    /// Reason raw value to entry, across every app.
    public var total: [String: Entry]
    /// Bundle identifier to reason raw value to entry (bounded).
    public var perApp: [String: [String: Entry]]

    public init(
        schemaVersion: Int = NotShownSnapshot.currentSchemaVersion,
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        total: [String: Entry] = [:],
        perApp: [String: [String: Entry]] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.total = total
        self.perApp = perApp
    }

    public var totalCount: Int { total.values.reduce(0) { $0 + $1.count } }

    /// Reasons by descending count, ties broken by the most recent sighting.
    public var ranked: [(key: String, value: Entry)] {
        total.sorted {
            $0.value.count != $1.value.count
                ? $0.value.count > $1.value.count
                : $0.value.lastSeen > $1.value.lastSeen
        }
    }
}

/// Persists `NotShownSnapshot` next to `privacy-metrics.json` as `not-shown.json`.
///
/// Records mutate memory under a lock and schedule one trailing write after
/// `debounce` seconds, so a burst of per-keystroke hides costs one atomic write
/// and the typing path never blocks on disk.
public final class NotShownStore: @unchecked Sendable {
    public static let maxApps = 200
    public static let maxIdentifierLength = 200

    /// The shared instance the menu app and the Statistics pane both read.
    public static let shared = NotShownStore()

    private let fileURL: URL
    private let writer: PersonalizationFileWriter
    private let debounce: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.cotype.not-shown.writer")
    private var state: NotShownSnapshot
    private var dirty = false
    private var writeScheduled = false

    public init(
        fileURL: URL? = nil,
        fileWriter: PersonalizationFileWriter = SystemFileWriter(),
        debounce: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.writer = fileWriter
        self.debounce = debounce
        self.now = now
        self.state = Self.load(from: self.fileURL)
        SecurePermissions.apply(to: self.fileURL)
    }

    public static func defaultFileURL() -> URL {
        PersonalizationStore.defaultMetricsURL()
            .deletingLastPathComponent()
            .appendingPathComponent("not-shown.json")
    }

    public var snapshot: NotShownSnapshot {
        lock.withLock { state }
    }

    public func record(_ reason: NotShownReason, appIdentifier: String) {
        let app = String(appIdentifier.prefix(Self.maxIdentifierLength))
        let stamp = now()
        let shouldSchedule: Bool = lock.withLock {
            bump(&state.total[reason.rawValue], at: stamp)
            if state.perApp[app] == nil, state.perApp.count >= Self.maxApps,
               let evict = state.perApp.min(by: { Self.sum($0.value) < Self.sum($1.value) })?.key {
                state.perApp.removeValue(forKey: evict)
            }
            bump(&state.perApp[app, default: [:]][reason.rawValue], at: stamp)
            state.updatedAt = stamp
            dirty = true
            guard !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        ioQueue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.persist()
        }
    }

    /// Writes any pending counts now. Used on quit and by tests.
    public func flush() {
        ioQueue.sync { persist() }
    }

    /// Forgets every count and removes the file.
    public func reset() {
        ioQueue.sync {
            lock.withLock {
                state = NotShownSnapshot()
                dirty = false
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func persist() {
        let payload: Data? = lock.withLock {
            writeScheduled = false
            guard dirty else { return nil }
            dirty = false
            return Self.encode(state)
        }
        guard let payload else { return }
        try? writer.write(payload, to: fileURL)
        SecurePermissions.apply(to: fileURL)
    }

    private func bump(_ entry: inout NotShownSnapshot.Entry?, at stamp: Date) {
        entry = NotShownSnapshot.Entry(count: (entry?.count ?? 0) + 1, lastSeen: stamp)
    }

    private static func sum(_ entries: [String: NotShownSnapshot.Entry]) -> Int {
        entries.values.reduce(0) { $0 + $1.count }
    }

    private static func encode(_ snapshot: NotShownSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(snapshot)
    }

    private static func load(from url: URL) -> NotShownSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(NotShownSnapshot.self, from: data) else {
            return NotShownSnapshot()
        }
        return decoded
    }
}
