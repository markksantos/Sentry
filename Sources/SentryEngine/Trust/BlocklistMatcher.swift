import Foundation

// MARK: - BlocklistMatcher

public struct BlocklistMatcher: Sendable {

    private let blockedDomains: Set<String>

    /// Number of tracker domains loaded from the blocklist.
    public var trackerCount: Int { blockedDomains.count }

    // MARK: - Initialization

    /// Loads `tracker-domains.txt` from the module bundle.
    /// Falls back to an empty set if the file is missing or unreadable.
    public init() {
        guard let url = Bundle.module.url(forResource: "tracker-domains", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            self.blockedDomains = []
            return
        }

        var domains = Set<String>()
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                domains.insert(trimmed.lowercased())
            }
        }
        self.blockedDomains = domains
    }

    // MARK: - Public API

    /// Returns `true` if the hostname (or any of its parent domain suffixes) appears in the blocklist.
    ///
    /// For example, given hostname `"ads.doubleclick.net"`, this checks:
    /// - `ads.doubleclick.net`
    /// - `doubleclick.net`
    /// - `net`
    public func isTracker(_ hostname: String) -> Bool {
        let normalized = hostname.lowercased()
        let components = normalized.split(separator: ".")

        // Walk from the full hostname down to progressively shorter suffixes
        for startIndex in components.indices {
            let suffix = components[startIndex...].joined(separator: ".")
            if blockedDomains.contains(suffix) {
                return true
            }
        }

        return false
    }

    /// Checks whether a connection is to a tracker by inspecting the resolved hostname.
    /// If no hostname is available, the raw IP cannot be matched and returns `false`.
    public func isTrackerByIP(_ ip: String, hostname: String?) -> Bool {
        guard let hostname, !hostname.isEmpty else {
            return false
        }
        return isTracker(hostname)
    }
}
