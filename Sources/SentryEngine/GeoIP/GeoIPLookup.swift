import Foundation

// MARK: - GeoIPResult

/// The result of a GeoIP lookup containing country code and flag emoji.
public struct GeoIPResult: Sendable, Hashable {
    /// ISO 3166-1 alpha-2 country code (e.g. "US", "DE").
    public let countryCode: String
    /// Flag emoji derived from the country code (e.g. "🇺🇸", "🇩🇪").
    public let flagEmoji: String
}

// MARK: - GeoIPLookup

/// Thread-safe wrapper around `MMDBReader` that provides cached GeoIP lookups
/// with flag emoji conversion.
public final class GeoIPLookup: @unchecked Sendable {

    // MARK: - Properties

    private let reader: MMDBReader?
    private var cache: [String: GeoIPResult?] = [:]
    private let lock = NSLock()

    // MARK: - Initialization

    /// Failable initializer that loads the MMDB from the bundle resource.
    /// Returns `nil` if the database file is missing or empty.
    public init?() {
        guard let url = Bundle.module.url(
            forResource: "GeoLite2-Country",
            withExtension: "mmdb"
        ) else {
            return nil
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }

        guard let mmdb = try? MMDBReader(data: data) else {
            return nil
        }

        self.reader = mmdb
    }

    /// Initialize with a pre-built reader (useful for testing).
    public init(reader: MMDBReader) {
        self.reader = reader
    }

    // MARK: - Public API

    /// Look up an IP address and return the country info, or `nil` if not found
    /// or the IP is private/reserved.
    public func lookup(_ ip: String) -> GeoIPResult? {
        // Skip private/reserved IPs.
        if isPrivateIP(ip) {
            return nil
        }

        // Check cache.
        lock.lock()
        if let cached = cache[ip] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Perform lookup.
        let result = performLookup(ip)

        // Cache the result (including nil, to avoid repeated lookups).
        lock.lock()
        cache[ip] = result
        lock.unlock()

        return result
    }

    // MARK: - Private

    private func performLookup(_ ip: String) -> GeoIPResult? {
        guard let reader = reader else { return nil }
        guard let record = reader.lookup(ip) else { return nil }

        // Navigate the MaxMind GeoLite2-Country response structure.
        // Typical path: record["country"]["iso_code"]
        let countryCode: String?
        if let country = record["country"] as? [String: Any] {
            countryCode = country["iso_code"] as? String
        } else if let registered = record["registered_country"] as? [String: Any] {
            countryCode = registered["iso_code"] as? String
        } else {
            countryCode = nil
        }

        guard let code = countryCode, code.count == 2 else { return nil }

        let emoji = flagEmoji(for: code)
        return GeoIPResult(countryCode: code, flagEmoji: emoji)
    }

    /// Convert a 2-letter country code to its flag emoji using regional indicator symbols.
    /// Each ASCII letter A-Z maps to Unicode regional indicator U+1F1E6..U+1F1FF.
    private func flagEmoji(for countryCode: String) -> String {
        let uppercased = countryCode.uppercased()
        var emoji = ""
        for scalar in uppercased.unicodeScalars {
            guard scalar.value >= 0x41, scalar.value <= 0x5A else { continue }
            let regionalIndicator = 0x1F1E6 + (scalar.value - 0x41)
            if let us = UnicodeScalar(regionalIndicator) {
                emoji.append(String(us))
            }
        }
        return emoji
    }

    /// Check if an IP address is in a private/reserved range.
    private func isPrivateIP(_ ip: String) -> Bool {
        // IPv6 loopback.
        if ip == "::1" || ip == "0:0:0:0:0:0:0:1" {
            return true
        }

        // IPv4 private ranges.
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            // Not an IPv4 address -- check for IPv6 private ranges.
            return isPrivateIPv6(ip)
        }

        let first = parts[0]
        let second = parts[1]

        // 127.0.0.0/8 - loopback
        if first == 127 { return true }
        // 10.0.0.0/8 - private
        if first == 10 { return true }
        // 172.16.0.0/12 - private
        if first == 172, second >= 16, second <= 31 { return true }
        // 192.168.0.0/16 - private
        if first == 192, second == 168 { return true }
        // 169.254.0.0/16 - link-local
        if first == 169, second == 254 { return true }
        // 0.0.0.0
        if first == 0 { return true }

        return false
    }

    /// Check for private IPv6 addresses (link-local, ULA, etc.).
    private func isPrivateIPv6(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        // fe80::/10 - link-local
        if lower.hasPrefix("fe80") { return true }
        // fc00::/7 - unique local address (ULA)
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        // :: unspecified
        if lower == "::" { return true }
        return false
    }
}
