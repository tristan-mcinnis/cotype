import XCTest
import CotypeCore
@testable import CotypeMenuApp

/// App discovery in App Settings reads the content-free counters, not stored
/// samples, so an app appears with real numbers even when logging is off.
@MainActor
final class AppSettingsModelTests: XCTestCase {

    private func makeStore() -> (PersonalizationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-appsettings-\(UUID().uuidString)")
        let urls = [
            base.appendingPathExtension("samples"),
            base.appendingPathExtension("config"),
            base.appendingPathExtension("metrics"),
        ]
        return (PersonalizationStore(fileURL: urls[0], configURL: urls[1], metricsURL: urls[2]), urls)
    }

    private func makeOverrides() -> AppOverridesStore {
        AppOverridesStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cotype-appsettings-overrides-\(UUID().uuidString).json")
        )
    }

    func testAppsAppearFromMetricsWithNoSamples() {
        let (personalization, urls) = makeStore()
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        personalization.recordShown(appIdentifier: "com.example.editor")
        personalization.recordMetric(.accepted, appIdentifier: "com.example.editor")
        personalization.recordShown(appIdentifier: "com.apple.mail")

        let model = AppSettingsModel(store: makeOverrides(), personalization: personalization)
        XCTAssertEqual(personalization.count, 0, "no content samples exist")
        XCTAssertEqual(model.entries.map(\.bundleID).prefix(2), ["com.example.editor", "com.apple.mail"])
        XCTAssertEqual(model.entries.first?.count, 2)
        XCTAssertEqual(model.entries.dropFirst().first?.count, 1)
    }

    func testAnOverriddenAppWithNoUsageIsStillListed() {
        let (personalization, urls) = makeStore()
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let overrides = makeOverrides()
        overrides.setOverride(AppOverride(enabled: false), for: "com.example.unused")

        let model = AppSettingsModel(store: overrides, personalization: personalization)
        XCTAssertTrue(model.entries.contains { $0.bundleID == "com.example.unused" })
        XCTAssertTrue(model.entries.contains { $0.bundleID == AppOverridesStore.defaultKey })
    }
}
