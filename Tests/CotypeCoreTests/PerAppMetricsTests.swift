import XCTest
@testable import CotypeCore

/// Statistics and app discovery must not depend on content samples. With
/// content logging off (no samples written), the content-free counters still
/// describe every app that produced a completion event.
final class PerAppMetricsTests: XCTestCase {

    private func makeStore(_ name: String) -> (PersonalizationStore, [URL]) {
        let dir = FileManager.default.temporaryDirectory
        let base = dir.appendingPathComponent("cotype-perapp-\(name)-\(UUID().uuidString)")
        let urls = [
            base.appendingPathExtension("samples"),
            base.appendingPathExtension("config"),
            base.appendingPathExtension("metrics"),
        ]
        return (PersonalizationStore(fileURL: urls[0], configURL: urls[1], metricsURL: urls[2]), urls)
    }

    func testCountersPopulatePerAppUsageWithoutAnySamples() {
        let (store, urls) = makeStore("counters")
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Metrics only: this is exactly what happens with logging off.
        store.recordShown(appIdentifier: "com.example.editor")
        store.recordMetric(.accepted, appIdentifier: "com.example.editor")
        store.recordMetric(.canceled, appIdentifier: "com.example.mail")
        store.recordMetric(.failed, appIdentifier: "com.example.mail")

        XCTAssertEqual(store.count, 0, "no content samples were written")
        let usage = store.perAppUsage()
        XCTAssertEqual(usage.map(\.appIdentifier), ["com.example.editor", "com.example.mail"])

        let editor = try? XCTUnwrap(usage.first)
        XCTAssertEqual(editor?.shown, 1)
        XCTAssertEqual(editor?.accepted, 1)
        XCTAssertEqual(editor?.total, 2)

        let mail = usage.last
        XCTAssertEqual(mail?.canceled, 1)
        XCTAssertEqual(mail?.failed, 1)
        XCTAssertEqual(mail?.total, 2)
    }

    func testCountersSurviveAReloadFromDisk() {
        let (store, urls) = makeStore("reload")
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        store.recordShown(appIdentifier: "com.example.editor")
        store.recordMetric(.accepted, appIdentifier: "com.example.editor")
        store.flush()

        let reloaded = PersonalizationStore(fileURL: urls[0], configURL: urls[1], metricsURL: urls[2])
        XCTAssertEqual(reloaded.perAppUsage().first?.accepted, 1)
    }

    func testRowsAreOrderedByActivity() {
        let (store, urls) = makeStore("order")
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        for _ in 0..<3 { store.recordShown(appIdentifier: "com.busy") }
        store.recordShown(appIdentifier: "com.quiet")
        XCTAssertEqual(store.perAppUsage().map(\.appIdentifier), ["com.busy", "com.quiet"])
    }
}
