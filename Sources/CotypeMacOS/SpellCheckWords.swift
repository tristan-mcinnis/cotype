import AppKit

/// The system spell checker as `CaretBoundary`'s word oracle.
///
/// `NSSpellChecker` is main-thread API, and the pipeline calls this from its
/// generation task, so each lookup hops to the main thread. Answers are cached:
/// the same partial word is checked on every streamed token.
public final class SpellCheckWords: @unchecked Sendable {
    // Guarded by `lock`: `cache` is read and written from pipeline tasks.
    public static let shared = SpellCheckWords()

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    public func isWord(_ word: String) -> Bool {
        let key = word.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let check = {
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
        }
        let result = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)

        lock.lock()
        if cache.count > 4_096 { cache.removeAll() }
        cache[key] = result
        lock.unlock()
        return result
    }
}
