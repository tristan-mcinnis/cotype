import Foundation

/// A per-website preference. `nil` fields inherit the app-level setting, so a
/// rule can disable completions on a banking site without re-declaring the rest.
public struct WebsiteRule: Codable, Equatable, Sendable {
    /// `nil` = inherit the app setting; `false` = completions off on this site.
    public var enabled: Bool?
    /// Extra writing instructions for this site. Carried in the same bounded
    /// context block as the global instructions, never as an invented template.
    public var systemPrompt: String?

    public init(enabled: Bool? = nil, systemPrompt: String? = nil) {
        self.enabled = enabled
        self.systemPrompt = systemPrompt
    }

    public var isEmpty: Bool { enabled == nil && systemPrompt == nil }
}

/// Pure host policy for website rules.
///
/// Trust rules, in order:
/// - Only `http` and `https` URLs identify a website.
/// - A URL carrying user info (`https://someone@host/`) is refused: the visible
///   address can then differ from the host that would receive the rule.
/// - The host is lowercased, a trailing dot and a leading `www.` are removed.
/// - A single-label host (`localhost`, a bare machine name) is not a website
///   identity; the app-level policy applies instead.
/// - A rule key matches its exact host and its subdomains (`example.com` matches
///   `app.example.com`), never a lookalike suffix (`notexample.com`).
public enum WebsiteDomain {

    /// Normalise a URL into a rule key, or nil when it is not a trustworthy
    /// website identity.
    public static func host(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard url.user == nil, url.password == nil else { return nil }
        guard let raw = url.host else { return nil }
        return normalizedHost(raw)
    }

    /// Parse and normalise a user-entered host or URL. A bare host is accepted;
    /// anything with a scheme must be http(s).
    public static func normalizedHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed) else { return nil }
            return host(from: url)
        }
        guard !trimmed.contains("/"), !trimmed.contains("?"), !trimmed.contains("#") else {
            // A pasted address without a scheme but with a path: parse it as https.
            guard let url = URL(string: "https://\(trimmed)") else { return nil }
            return host(from: url)
        }
        var host = trimmed.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard isPlausibleHost(host) else { return nil }
        return host
    }

    /// Letters, digits, dots and hyphens; at least two labels; no empty labels.
    /// IP addresses are rejected because a website rule keyed to a raw address is
    /// never a stable site preference.
    static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // A numeric-only last label is an IP address, not a domain; mDNS and
        // machine-local names are not website identities either.
        guard let tld = labels.last, tld.contains(where: { $0.isLetter }) else { return false }
        guard tld != "local" else { return false }
        return true
    }

    /// The stored rule key that governs `host`, preferring the most specific
    /// (longest) matching key. Exact match wins over a parent domain.
    public static func matchingKey(for host: String, in keys: some Sequence<String>) -> String? {
        let normalized = normalizedHost(host) ?? host.lowercased()
        var best: String?
        for key in keys {
            guard normalized == key || normalized.hasSuffix("." + key) else { continue }
            if best.map({ key.count > $0.count }) ?? true { best = key }
        }
        return best
    }
}

/// Reconciles the document URLs a browser exposes (the focused element's own
/// `AXDocument`/`AXURL` and the focused window's). Kept pure in Core so the
/// trust rule is testable without Accessibility.
public enum BrowserDocumentIdentity {
    /// - Returns: the single normalised host both readable sources agree on, or
    ///   nil when they disagree, when a readable source is not a website, or
    ///   when nothing is readable.
    public static func domain(elementDocument: String?, windowDocument: String?) -> String? {
        let candidates = [elementDocument, windowDocument]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        let hosts: [String?] = candidates.map { raw in
            guard let url = URL(string: raw) else { return nil }
            return WebsiteDomain.host(from: url)
        }
        // A readable candidate that is not a trustworthy website (file://,
        // about:, chrome://, malformed) makes the identity ambiguous.
        guard hosts.allSatisfy({ $0 != nil }) else { return nil }
        let unique = Set(hosts.compactMap { $0 })
        guard unique.count == 1 else { return nil }
        return unique.first
    }
}

/// Persists `WebsiteRule` values keyed by normalised host.
///
/// Same shape and safety posture as `AppOverridesStore`: a bounded JSON file,
/// serial queue, atomic write, owner-only permissions, failures swallowed
/// because a preference is never worth interrupting typing.
public final class WebsiteRulesStore: @unchecked Sendable {
    /// Keeps the file bounded like the app override store.
    public static let maxEntries = 200

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.cotype.website-rules")
    private var rules: [String: WebsiteRule]

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: WebsiteRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = [:]
        }
        SecurePermissions.apply(to: self.fileURL)
    }

    /// The rule that applies to a host, or nil when no rule matches. A rule is
    /// only ever returned for a normalised host; callers must pass nil rather
    /// than guess when the identity is unknown.
    public func rule(forHost host: String) -> (key: String, rule: WebsiteRule)? {
        queue.sync {
            guard let key = WebsiteDomain.matchingKey(for: host, in: rules.keys),
                  let rule = rules[key] else { return nil }
            return (key, rule)
        }
    }

    public func rawRule(for key: String) -> WebsiteRule? {
        queue.sync { rules[key] }
    }

    public func allKeys() -> Set<String> {
        queue.sync { Set(rules.keys) }
    }

    /// Insert or replace a rule. A host that cannot be normalised is refused, so
    /// a mistyped entry can never become a rule that matches nothing.
    @discardableResult
    public func setRule(_ rule: WebsiteRule, forHost rawHost: String) -> String? {
        guard let host = WebsiteDomain.normalizedHost(rawHost) else { return nil }
        queue.sync {
            if rules[host] == nil, rules.count >= Self.maxEntries {
                // Drop the oldest-inserted entry: dictionary order is stable
                // enough here and the cap is a safety bound, not a ranking.
                if let first = rules.keys.first { rules.removeValue(forKey: first) }
            }
            if rule.isEmpty {
                rules.removeValue(forKey: host)
            } else {
                rules[host] = rule
            }
            persist()
        }
        return host
    }

    public func removeRule(forHost host: String) {
        queue.sync {
            rules.removeValue(forKey: host)
            persist()
        }
    }

    public func clear() {
        queue.sync {
            rules.removeAll()
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            SecurePermissions.apply(to: fileURL)
        } catch {
            // Preference storage is non-critical and never blocks typing.
        }
    }

    public static func defaultFileURL() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cotype", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("website-rules.json")
    }
}
