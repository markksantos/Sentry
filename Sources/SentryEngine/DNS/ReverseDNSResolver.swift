import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Actor-isolated reverse DNS resolver with caching and TTL-based expiration.
///
/// Uses POSIX `getnameinfo` for lookups, offloaded to a detached task so the
/// actor is never blocked by network I/O.
public actor ReverseDNSResolver {

    // MARK: - Types

    private struct CacheEntry {
        let hostname: String?
        let expirationDate: Date
    }

    // MARK: - Configuration

    /// Time-to-live for cache entries.
    private let ttl: TimeInterval

    /// Maximum number of cache entries before eviction.
    private let maxCacheSize: Int

    // MARK: - State

    private var cache: [String: CacheEntry] = [:]

    /// Track insertion order for LRU-style eviction.
    private var insertionOrder: [String] = []

    // MARK: - Initialization

    /// - Parameters:
    ///   - ttl: Cache time-to-live in seconds. Defaults to 300 (5 minutes).
    ///   - maxCacheSize: Maximum number of cached entries. Defaults to 1000.
    public init(ttl: TimeInterval = 300, maxCacheSize: Int = 1000) {
        self.ttl = ttl
        self.maxCacheSize = maxCacheSize
    }

    // MARK: - Public API

    /// Resolve a single IP address to its hostname via reverse DNS.
    /// Returns the hostname, or `nil` if resolution fails or times out.
    public func resolve(_ ip: String) async -> String? {
        // Return cached result if still valid.
        if let entry = cache[ip], entry.expirationDate > Date() {
            return entry.hostname
        }

        // Remove expired entry if present.
        if cache[ip] != nil {
            removeFromCache(ip)
        }

        // Perform the lookup off the actor to avoid blocking.
        let hostname = await performLookup(ip)

        // Cache the result.
        addToCache(ip: ip, hostname: hostname)

        return hostname
    }

    /// Resolve multiple IP addresses in parallel.
    /// Returns a dictionary mapping each IP to its hostname (omitting failures).
    public func resolveMany(_ ips: [String]) async -> [String: String] {
        // De-duplicate input.
        let uniqueIPs = Array(Set(ips))

        return await withTaskGroup(of: (String, String?).self) { group in
            for ip in uniqueIPs {
                group.addTask { [self] in
                    let hostname = await self.resolve(ip)
                    return (ip, hostname)
                }
            }

            var results: [String: String] = [:]
            for await (ip, hostname) in group {
                if let hostname = hostname {
                    results[ip] = hostname
                }
            }
            return results
        }
    }

    // MARK: - Cache Management

    private func addToCache(ip: String, hostname: String?) {
        // Evict oldest entries if at capacity.
        while cache.count >= maxCacheSize, !insertionOrder.isEmpty {
            let oldest = insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }

        cache[ip] = CacheEntry(
            hostname: hostname,
            expirationDate: Date().addingTimeInterval(ttl)
        )
        insertionOrder.append(ip)
    }

    private func removeFromCache(_ ip: String) {
        cache.removeValue(forKey: ip)
        if let index = insertionOrder.firstIndex(of: ip) {
            insertionOrder.remove(at: index)
        }
    }

    // MARK: - DNS Lookup

    /// Perform the actual reverse DNS lookup using `getnameinfo`.
    /// Runs in a detached task to avoid blocking the actor.
    private nonisolated func performLookup(_ ip: String) async -> String? {
        // Use a task with a timeout to avoid hanging on unresponsive DNS.
        let lookupTask = Task.detached { () -> String? in
            Self.getnameInfoLookup(ip)
        }

        // Race the lookup against a 5-second timeout.
        let timeoutTask = Task.detached { () -> String? in
            try? await Task.sleep(for: .seconds(5))
            return nil
        }

        // Whichever finishes first wins.
        let result = await withTaskGroup(of: String??.self) { group in
            group.addTask {
                await lookupTask.value
            }
            group.addTask {
                _ = await timeoutTask.value
                return nil as String?
            }

            // Take the first completed result.
            let first = await group.next() ?? nil
            group.cancelAll()

            // If first result is from timeout (nil), still cancel the lookup.
            lookupTask.cancel()
            timeoutTask.cancel()

            return first
        }

        return result ?? nil
    }

    /// Synchronous `getnameinfo` call.
    private static func getnameInfoLookup(_ ip: String) -> String? {
        // Try IPv4 first.
        if let result = lookupIPv4(ip) {
            return result
        }
        // Try IPv6.
        if let result = lookupIPv6(ip) {
            return result
        }
        return nil
    }

    private static func lookupIPv4(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)

        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
            return nil
        }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getnameinfo(
                    sockaddrPtr,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    0  // No flags: do full reverse lookup.
                )
            }
        }

        guard result == 0 else { return nil }

        let name = String(cString: hostname)
        // If getnameinfo returns the IP itself, treat as failure.
        if name == ip { return nil }
        return name
    }

    private static func lookupIPv6(_ ip: String) -> String? {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)

        guard inet_pton(AF_INET6, ip, &addr.sin6_addr) == 1 else {
            return nil
        }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getnameinfo(
                    sockaddrPtr,
                    socklen_t(MemoryLayout<sockaddr_in6>.size),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    0
                )
            }
        }

        guard result == 0 else { return nil }

        let name = String(cString: hostname)
        if name == ip { return nil }
        return name
    }
}
