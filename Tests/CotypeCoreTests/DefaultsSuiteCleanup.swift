import Foundation

enum DefaultsSuiteCleanup {

    static func plistURL(forSuite name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
    }

    static func remove(suite name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: plistURL(forSuite: name))
    }
}
