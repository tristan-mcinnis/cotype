import XCTest
@testable import CotypeCore

final class NotShownStoreTests: XCTestCase {

    private final class RecordingWriter: PersonalizationFileWriter, @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [Data] = []
        var writes: Int { lock.withLock { payloads.count } }
        var last: Data? { lock.withLock { payloads.last } }
        func write(_ data: Data, to url: URL) throws {
            lock.withLock { payloads.append(data) }
        }
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-not-shown-\(UUID().uuidString).json")
    }

    private func makeStore(
        url: URL? = nil,
        writer: PersonalizationFileWriter = SystemFileWriter(),
        debounce: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> NotShownStore {
        NotShownStore(fileURL: url ?? tempURL(), fileWriter: writer, debounce: debounce, now: now)
    }

    func testCountsPerReasonAndPerApp() {
        let store = makeStore()
        store.record(.noCaretGeometry, appIdentifier: "org.telegram.desktop")
        store.record(.noCaretGeometry, appIdentifier: "org.telegram.desktop")
        store.record(.emptyCompletion, appIdentifier: "org.telegram.desktop")
        store.record(.noCaretGeometry, appIdentifier: "com.apple.Notes")

        let snapshot = store.snapshot
        XCTAssertEqual(snapshot.total["noCaretGeometry"]?.count, 3)
        XCTAssertEqual(snapshot.total["emptyCompletion"]?.count, 1)
        XCTAssertEqual(snapshot.perApp["org.telegram.desktop"]?["noCaretGeometry"]?.count, 2)
        XCTAssertEqual(snapshot.perApp["com.apple.Notes"]?["noCaretGeometry"]?.count, 1)
        XCTAssertNil(snapshot.perApp["com.apple.Notes"]?["emptyCompletion"])
        XCTAssertEqual(snapshot.totalCount, 4)
    }

    func testLastSeenTracksTheLatestRecord() {
        let clock = LockedDate(Date(timeIntervalSince1970: 1_000))
        let store = makeStore(now: { clock.value })
        store.record(.appDisabled, appIdentifier: "a.b")
        clock.value = Date(timeIntervalSince1970: 2_000)
        store.record(.appDisabled, appIdentifier: "a.b")

        XCTAssertEqual(store.snapshot.total["appDisabled"]?.lastSeen, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(store.snapshot.perApp["a.b"]?["appDisabled"]?.lastSeen, Date(timeIntervalSince1970: 2_000))
    }

    func testWritesAreDebouncedIntoOneWrite() {
        let writer = RecordingWriter()
        let store = makeStore(writer: writer, debounce: 0.2)
        for _ in 0..<50 { store.record(.noCaretGeometry, appIdentifier: "a.b") }
        XCTAssertEqual(writer.writes, 0, "records must not write synchronously")

        let deadline = Date().addingTimeInterval(3)
        while writer.writes == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(writer.writes, 1, "a burst of records collapses into one debounced write")
    }

    func testFlushPersistsAtomicallyAndReloads() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = makeStore(url: url)
        first.record(.ghostDoesNotFit, appIdentifier: "com.apple.Notes")
        first.flush()

        let second = makeStore(url: url)
        XCTAssertEqual(second.snapshot.total["ghostDoesNotFit"]?.count, 1)
        second.record(.ghostDoesNotFit, appIdentifier: "com.apple.Notes")
        XCTAssertEqual(second.snapshot.perApp["com.apple.Notes"]?["ghostDoesNotFit"]?.count, 2)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFileShapeCarriesOnlyReasonsCountsBundleIDsAndTimestamps() throws {
        let writer = RecordingWriter()
        let store = makeStore(writer: writer)
        store.record(.noModel, appIdentifier: "org.telegram.desktop")
        store.flush()

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(writer.last)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "updatedAt", "total", "perApp"])
        let entry = try XCTUnwrap(((object["perApp"] as? [String: Any])?["org.telegram.desktop"] as? [String: Any])?["noModel"] as? [String: Any])
        XCTAssertEqual(Set(entry.keys), ["count", "lastSeen"])
    }

    func testPerAppEntriesAreBounded() {
        let store = makeStore()
        for index in 0..<(NotShownStore.maxApps + 25) {
            store.record(.appDisabled, appIdentifier: "app.\(index)")
        }
        XCTAssertLessThanOrEqual(store.snapshot.perApp.count, NotShownStore.maxApps)
        XCTAssertEqual(store.snapshot.total["appDisabled"]?.count, NotShownStore.maxApps + 25)
    }

    func testOverlongBundleIdentifierIsTruncated() {
        let store = makeStore()
        store.record(.appDisabled, appIdentifier: String(repeating: "x", count: 5_000))
        XCTAssertEqual(store.snapshot.perApp.keys.first?.count, NotShownStore.maxIdentifierLength)
    }

    func testCorruptFileLoadsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(makeStore(url: url).snapshot.totalCount, 0)
    }

    func testUnknownReasonKeysSurviveReload() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"schemaVersion":1,"updatedAt":"2026-10-16T00:00:00Z","total":{"futureReason":{"count":4,"lastSeen":"2026-10-16T00:00:00Z"}},"perApp":{}}
        """
        try Data(json.utf8).write(to: url)
        XCTAssertEqual(makeStore(url: url).snapshot.total["futureReason"]?.count, 4)
    }

    func testResetClearsCountsAndTheFile() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore(url: url)
        store.record(.noModel, appIdentifier: "a.b")
        store.flush()
        store.reset()
        XCTAssertEqual(store.snapshot.totalCount, 0)
        XCTAssertEqual(makeStore(url: url).snapshot.totalCount, 0)
    }

    func testTopReasonsOrderByCount() {
        let store = makeStore()
        store.record(.noModel, appIdentifier: "a.b")
        store.record(.noCaretGeometry, appIdentifier: "a.b")
        store.record(.noCaretGeometry, appIdentifier: "a.b")
        XCTAssertEqual(store.snapshot.ranked.map(\.key), ["noCaretGeometry", "noModel"])
    }

    func testEveryReasonHasATitleAndAUniqueRawValue() {
        let raws = NotShownReason.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for reason in NotShownReason.allCases { XCTAssertFalse(reason.title.isEmpty) }
    }

    func testSensitiveCategoriesMapToDistinctReasons() {
        XCTAssertEqual(NotShownReason(gate: .secureTextField), .secureField)
        XCTAssertEqual(NotShownReason(gate: .protectedContent), .protectedContent)
        XCTAssertEqual(NotShownReason(gate: .sensitiveApp), .sensitiveApp)
        XCTAssertEqual(NotShownReason(gate: .userExcludedApp), .userExcludedApp)
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
