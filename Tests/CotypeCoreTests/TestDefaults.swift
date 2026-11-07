import Foundation

/// A fresh defaults suite stored in the temp folder. A plain suite name writes
/// a plist to ~/Library/Preferences that no API removes, so every run leaked one.
func makeUserDefaults() -> UserDefaults {
    UserDefaults(suiteName: NSTemporaryDirectory() + "cotype-test-\(UUID().uuidString)")!
}
