import XCTest
@testable import CotypeCore

final class SettingsStoreTests: XCTestCase {

    private func tempFileURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-test-\(name)-\(UUID().uuidString).json")
    }

    /// A PersonalizationStore with fully isolated sample/config/metric files, so
    /// no test touches the real Application Support directory.
    private func privacyStore(_ name: String) -> PersonalizationStore {
        PersonalizationStore(
            fileURL: tempFileURL("\(name)-samples"),
            configURL: tempFileURL("\(name)-config"),
            metricsURL: tempFileURL("\(name)-metrics")
        )
    }

    // MARK: AppOverridesStore

    func testOverrideInheritsDefault() {
        let store = AppOverridesStore(fileURL: tempFileURL("overrides"))
        store.setOverride(AppOverride(systemPrompt: "default prompt"), for: AppOverridesStore.defaultKey)

        let effective = store.override(for: "com.example.xcode")
        XCTAssertEqual(effective.systemPrompt, "default prompt")
    }

    func testOverrideMergesOverDefault() {
        let store = AppOverridesStore(fileURL: tempFileURL("overrides"))
        store.setOverride(
            AppOverride(enabled: true, systemPrompt: "base"),
            for: AppOverridesStore.defaultKey
        )
        store.setOverride(AppOverride(systemPrompt: "xcode-specific"), for: "com.example.xcode")

        let effective = store.override(for: "com.example.xcode")
        XCTAssertEqual(effective.systemPrompt, "xcode-specific") // own field wins
        XCTAssertEqual(effective.enabled, true)                   // inherited
    }

    func testOverrideDisabledFlag() {
        let store = AppOverridesStore(fileURL: tempFileURL("overrides"))
        store.setOverride(AppOverride(enabled: false), for: "com.example.mail")

        let effective = store.override(for: "com.example.mail")
        XCTAssertEqual(effective.enabled, false)
    }

    func testOverridesPersistAcrossInstances() {
        let url = tempFileURL("overrides")
        let store1 = AppOverridesStore(fileURL: url)
        store1.setOverride(AppOverride(systemPrompt: "persisted"), for: "com.example.app")

        let store2 = AppOverridesStore(fileURL: url)
        XCTAssertEqual(store2.override(for: "com.example.app").systemPrompt, "persisted")
    }

    func testRemoveOverride() {
        let store = AppOverridesStore(fileURL: tempFileURL("overrides"))
        store.setOverride(AppOverride(systemPrompt: "default prompt"), for: AppOverridesStore.defaultKey)
        store.setOverride(AppOverride(systemPrompt: "app prompt"), for: "com.example.app")

        store.removeOverride(for: "com.example.app")
        // After removal the app falls back to the default.
        XCTAssertEqual(store.override(for: "com.example.app").systemPrompt, "default prompt")
    }

    // MARK: PersonalizationStore

    func testRecordAndCount() {
        let store = privacyStore("record")
        store.recordAccepted(prefix: "func f() {", completion: "return 1", appIdentifier: "xcode")
        store.recordRejected(prefix: "func g() {", completion: "return 2", appIdentifier: "xcode")

        XCTAssertEqual(store.count, 2)
    }

    func testSamplesFilterByApp() {
        let store = privacyStore("filter")
        store.recordAccepted(prefix: "a", completion: "1", appIdentifier: "xcode")
        store.recordAccepted(prefix: "b", completion: "2", appIdentifier: "mail")

        XCTAssertEqual(store.samples(forApp: "xcode").count, 1)
        XCTAssertEqual(store.samples(forApp: "xcode").first?.completion, "1")
        XCTAssertEqual(store.samples().count, 2)
    }

    func testLegacyArraySamplesMigrateAndRemainAppendable() throws {
        let url = tempFileURL("personalization-legacy")
        let legacy = [PersonalizationSample(
            prefix: "old", completion: "sample", accepted: true, appIdentifier: "mail"
        )]
        try JSONEncoder().encode(legacy).write(to: url)

        let store = PersonalizationStore(fileURL: url, configURL: tempFileURL("legacy-config"), metricsURL: tempFileURL("legacy-metrics"))
        store.recordRejected(prefix: "new", completion: "sample", appIdentifier: "mail")
        store.flush()

        let reloaded = PersonalizationStore(fileURL: url, configURL: tempFileURL("legacy-config"), metricsURL: tempFileURL("legacy-metrics"))
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.samples().first?.prefix, "new")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.hasPrefix("["), "legacy array should migrate to JSON Lines")
    }

    func testSamplesPersistAcrossInstances() {
        let url = tempFileURL("personalization")
        let store1 = PersonalizationStore(fileURL: url, configURL: tempFileURL("persist-config"), metricsURL: tempFileURL("persist-metrics"))
        store1.recordAccepted(prefix: "p", completion: "c", appIdentifier: "xcode")
        store1.flush()

        let store2 = PersonalizationStore(fileURL: url, configURL: tempFileURL("persist-config"), metricsURL: tempFileURL("persist-metrics"))
        XCTAssertEqual(store2.count, 1)
        XCTAssertEqual(store2.samples().first?.completion, "c")
    }

    func testClearSamples() {
        let store = privacyStore("clear")
        store.recordAccepted(prefix: "p", completion: "c", appIdentifier: "xcode")
        store.clear()
        XCTAssertEqual(store.count, 0)
    }
}
