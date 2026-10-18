import XCTest
@testable import CotypeCore

/// Website rules must be conservative: no rule applies without a trustworthy
/// host, and a rule never matches a lookalike domain.
final class WebsiteRulesTests: XCTestCase {

    private func makeStore() -> (WebsiteRulesStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotype-websites-\(UUID().uuidString).json")
        return (WebsiteRulesStore(fileURL: url), url)
    }

    // MARK: Host identity

    func testHttpsHostIsNormalised() {
        XCTAssertEqual(WebsiteDomain.host(from: URL(string: "https://www.Example.com./path?q=1")!), "example.com")
        XCTAssertEqual(WebsiteDomain.host(from: URL(string: "http://app.example.com")!), "app.example.com")
    }

    func testNonWebAndUserInfoURLsAreRefused() {
        XCTAssertNil(WebsiteDomain.host(from: URL(string: "file:///var/tmp/notes.txt")!))
        XCTAssertNil(WebsiteDomain.host(from: URL(string: "about:blank")!))
        XCTAssertNil(WebsiteDomain.host(from: URL(string: "chrome://settings")!))
        XCTAssertNil(WebsiteDomain.host(from: URL(string: "https://someone@example.com/")!))
    }

    func testSingleLabelAndNumericHostsAreNotWebsiteIdentities() {
        XCTAssertNil(WebsiteDomain.normalizedHost("localhost"))
        XCTAssertNil(WebsiteDomain.normalizedHost("127.0.0.1"))
        XCTAssertNil(WebsiteDomain.normalizedHost("machine.local"))
        XCTAssertNil(WebsiteDomain.normalizedHost("not a host"))
        XCTAssertNil(WebsiteDomain.normalizedHost(""))
    }

    func testBareHostsAndAddressesAreAccepted() {
        XCTAssertEqual(WebsiteDomain.normalizedHost("example.com"), "example.com")
        XCTAssertEqual(WebsiteDomain.normalizedHost("WWW.Example.COM."), "example.com")
        XCTAssertEqual(WebsiteDomain.normalizedHost("https://example.com/inbox"), "example.com")
        XCTAssertEqual(WebsiteDomain.normalizedHost("example.com/some/path"), "example.com")
    }

    /// A rule for `example.com` governs its subdomains, never a lookalike.
    func testSubdomainMatchingIsSuffixAware() {
        let keys = ["example.com", "app.example.com", "notexample.com"]
        XCTAssertEqual(WebsiteDomain.matchingKey(for: "example.com", in: keys), "example.com")
        XCTAssertEqual(WebsiteDomain.matchingKey(for: "mail.example.com", in: keys), "example.com")
        XCTAssertEqual(
            WebsiteDomain.matchingKey(for: "deep.mail.example.com", in: keys),
            "example.com"
        )
        XCTAssertEqual(
            WebsiteDomain.matchingKey(for: "app.example.com", in: keys),
            "app.example.com",
            "the most specific rule wins"
        )
        XCTAssertEqual(WebsiteDomain.matchingKey(for: "notexample.com", in: keys), "notexample.com")
        XCTAssertNil(WebsiteDomain.matchingKey(for: "example.com.evil.test", in: keys))
        XCTAssertNil(WebsiteDomain.matchingKey(for: "unrelated.test", in: keys))
    }

    // MARK: Reconciliation of AX document sources

    func testAgreeingDocumentsYieldOneHost() {
        XCTAssertEqual(
            BrowserDocumentIdentity.domain(
                elementDocument: "https://example.com/inbox",
                windowDocument: "https://www.example.com/inbox"
            ),
            "example.com"
        )
    }

    func testDisagreeingDocumentsAreAmbiguous() {
        XCTAssertNil(BrowserDocumentIdentity.domain(
            elementDocument: "https://example.com/",
            windowDocument: "https://other.test/"
        ))
    }

    func testUnreadableOrNonWebDocumentsAreAmbiguous() {
        XCTAssertNil(BrowserDocumentIdentity.domain(
            elementDocument: "file:///var/tmp/letter.txt",
            windowDocument: "https://example.com/"
        ))
        XCTAssertNil(BrowserDocumentIdentity.domain(elementDocument: nil, windowDocument: nil))
        XCTAssertNil(BrowserDocumentIdentity.domain(elementDocument: "", windowDocument: "not a url"))
    }

    func testOnlyOneReadableSourceIsEnough() {
        XCTAssertEqual(
            BrowserDocumentIdentity.domain(elementDocument: nil, windowDocument: "https://example.com/x"),
            "example.com"
        )
        XCTAssertEqual(
            BrowserDocumentIdentity.domain(elementDocument: "https://example.com/x", windowDocument: nil),
            "example.com"
        )
    }

    // MARK: Store

    func testRuleRoundTripsAndIsCaseInsensitive() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(store.setRule(WebsiteRule(enabled: false), forHost: "WWW.Example.com"), "example.com")
        let match = store.rule(forHost: "mail.example.com")
        XCTAssertEqual(match?.key, "example.com")
        XCTAssertEqual(match?.rule.enabled, false)
    }

    func testUnnormalisableHostsAreRefused() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(store.setRule(WebsiteRule(enabled: false), forHost: "file:///tmp/x"))
        XCTAssertTrue(store.allKeys().isEmpty)
    }

    func testEmptyRuleRemovesTheEntry() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.setRule(WebsiteRule(enabled: true), forHost: "example.com")
        store.setRule(WebsiteRule(), forHost: "example.com")
        XCTAssertTrue(store.allKeys().isEmpty)
    }

    func testFileIsBoundedAndReRead() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        for i in 0..<(WebsiteRulesStore.maxEntries + 5) {
            store.setRule(WebsiteRule(enabled: true), forHost: "site\(i).example")
        }
        XCTAssertLessThanOrEqual(store.allKeys().count, WebsiteRulesStore.maxEntries)
        XCTAssertEqual(WebsiteRulesStore(fileURL: url).allKeys().count, store.allKeys().count)
    }
}
