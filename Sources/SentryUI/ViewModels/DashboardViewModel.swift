import AppKit
import Foundation
import Observation
import SentryEngine
import UserNotifications

// MARK: - AppSummary

public struct AppSummary: Identifiable, Sendable {
    public var id: String { appName }

    public let appName: String
    public let icon: NSImage?
    public let connectionCount: Int
    public let connections: [ConnectionEntry]
    public var isExpanded: Bool
    public var trustStatus: TrustLevel

    public init(
        appName: String,
        icon: NSImage?,
        connectionCount: Int,
        connections: [ConnectionEntry],
        isExpanded: Bool = false,
        trustStatus: TrustLevel = .unknown
    ) {
        self.appName = appName
        self.icon = icon
        self.connectionCount = connectionCount
        self.connections = connections
        self.isExpanded = isExpanded
        self.trustStatus = trustStatus
    }
}

// MARK: - ConnectionDisplay

/// A connection enriched with trust/tracker info for display.
public struct ConnectionDisplay: Identifiable, Sendable {
    public var id: UUID { entry.id }
    public let entry: ConnectionEntry
    public let trustLevel: TrustLevel
    public let isTracker: Bool

    public init(entry: ConnectionEntry, trustLevel: TrustLevel = .unknown, isTracker: Bool = false) {
        self.entry = entry
        self.trustLevel = trustLevel
        self.isTracker = isTracker
    }
}

// MARK: - DashboardViewModel

@MainActor
@Observable
public final class DashboardViewModel {

    // MARK: Published State

    public var appSummaries: [AppSummary] = []
    public var searchText: String = ""
    public var isScanning: Bool = false
    public var lastScanTime: Date?
    public var selectedTab: Tab = .live

    public enum Tab: String, CaseIterable {
        case live = "Live"
        case history = "History"
    }

    // MARK: Computed

    public var filteredSummaries: [AppSummary] {
        guard !searchText.isEmpty else { return appSummaries }
        let query = searchText.lowercased()
        return appSummaries.compactMap { summary in
            if summary.appName.lowercased().contains(query) {
                return summary
            }
            let matched = summary.connections.filter { conn in
                conn.remoteAddress.lowercased().contains(query)
                    || (conn.remoteHostname?.lowercased().contains(query) ?? false)
                    || (conn.countryCode?.lowercased().contains(query) ?? false)
            }
            guard !matched.isEmpty else { return nil }
            return AppSummary(
                appName: summary.appName,
                icon: summary.icon,
                connectionCount: matched.count,
                connections: matched,
                isExpanded: summary.isExpanded,
                trustStatus: summary.trustStatus
            )
        }
    }

    public var totalConnectionCount: Int {
        appSummaries.reduce(0) { $0 + $1.connectionCount }
    }

    // MARK: Private

    private var scanner: NetworkScanner?
    private var scanTask: Task<Void, Never>?
    private var iconCache: [String: NSImage] = [:]

    // Phase 2/3 services
    private let geoIP: GeoIPLookup?
    private let dnsResolver: ReverseDNSResolver
    private var store: SQLiteStore?
    private var trustManager: TrustManager?
    private let blocklist: BlocklistMatcher

    // MARK: Init

    public init() {
        self.geoIP = GeoIPLookup()
        self.dnsResolver = ReverseDNSResolver()
        self.blocklist = BlocklistMatcher()
        self.store = try? SQLiteStore()
        self.trustManager = try? TrustManager()
    }

    // MARK: Lifecycle

    public func start() {
        guard scanner == nil else { return }
        let newScanner = NetworkScanner()
        scanner = newScanner
        isScanning = true

        scanTask = Task { [weak self] in
            let stream = await newScanner.start()
            for await connections in stream {
                guard !Task.isCancelled else { break }
                await self?.processConnections(connections)
            }
        }
    }

    public func stop() {
        scanTask?.cancel()
        scanTask = nil
        if let scanner {
            Task { await scanner.stop() }
        }
        scanner = nil
        isScanning = false
    }

    public func scanNow() {
        guard let scanner else {
            start()
            return
        }
        Task {
            do {
                let connections = try await scanner.scan()
                await processConnections(connections)
            } catch {
                // Scan failed; stream continues.
            }
        }
    }

    // MARK: - Trust Actions

    public func setTrust(app: String, host: String, level: TrustLevel) {
        guard let trustManager else { return }
        Task {
            await trustManager.setTrustLevel(app: app, host: host, level: level)
        }
    }

    public func trustAllForApp(_ appName: String) {
        guard let trustManager else { return }
        Task {
            await trustManager.trustAllForApp(appName)
        }
    }

    // MARK: - Processing Pipeline

    private func processConnections(_ connections: [ConnectionEntry]) async {
        // Enrich with GeoIP + DNS
        var enriched = connections
        for i in enriched.indices {
            let ip = enriched[i].remoteAddress

            // GeoIP
            if let result = geoIP?.lookup(ip) {
                enriched[i].countryCode = result.countryCode
                enriched[i].flagEmoji = result.flagEmoji
            }
        }

        // Batch DNS resolution for unique remote IPs
        let uniqueIPs = Set(enriched.map(\.remoteAddress))
        let hostnames = await dnsResolver.resolveMany(Array(uniqueIPs))
        for i in enriched.indices {
            if let hostname = hostnames[enriched[i].remoteAddress] {
                enriched[i].remoteHostname = hostname
            }
        }

        // Persist to history
        if let store {
            try? await store.upsertBatch(enriched)
        }

        // Check for new connections (trust system)
        if let trustManager {
            let newConns = await trustManager.checkConnections(enriched)
            // Fire notifications for truly new connections
            await fireNotifications(for: newConns)
        }

        // Update UI
        updateSummaries(from: enriched)
    }

    private func fireNotifications(for newConnections: [NewConnection]) async {
        guard !newConnections.isEmpty else { return }

        // Check if notifications are enabled (default to true)
        let defaults = UserDefaults.standard
        if defaults.dictionaryRepresentation().keys.contains("notificationsEnabled"),
           !defaults.bool(forKey: "notificationsEnabled") {
            return
        }

        let center = UNUserNotificationCenter.current()

        // Request permission if needed
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        guard settings.authorizationStatus != .denied else { return }

        for conn in newConnections.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = "New Connection"
            content.subtitle = conn.appName
            let countryInfo = conn.flagEmoji.map { " (\($0))" } ?? ""
            content.body = "connecting to \(conn.remoteHost)\(countryInfo)"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "sentry-\(conn.appName)-\(conn.remoteHost)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func updateSummaries(from connections: [ConnectionEntry]) {
        let expandedApps = Set(appSummaries.filter(\.isExpanded).map(\.appName))

        let grouped = Dictionary(grouping: connections, by: \.appName)

        appSummaries = grouped
            .map { appName, conns in
                AppSummary(
                    appName: appName,
                    icon: resolveIcon(for: conns),
                    connectionCount: conns.count,
                    connections: conns.sorted { $0.timestamp > $1.timestamp },
                    isExpanded: expandedApps.contains(appName)
                )
            }
            .sorted { $0.connectionCount > $1.connectionCount }

        lastScanTime = Date()
    }

    // MARK: - Trust Helpers

    public func trustLevel(for entry: ConnectionEntry) -> TrustLevel {
        // Check blocklist first
        if blocklist.isTrackerByIP(entry.remoteAddress, hostname: entry.remoteHostname) {
            return .suspicious
        }
        // Synchronous check not possible with actor; return unknown for now
        // Real trust levels are resolved during processConnections
        return .unknown
    }

    public func isTracker(_ entry: ConnectionEntry) -> Bool {
        blocklist.isTrackerByIP(entry.remoteAddress, hostname: entry.remoteHostname)
    }

    // MARK: - Icon Resolution

    private func resolveIcon(for connections: [ConnectionEntry]) -> NSImage? {
        guard let first = connections.first else { return nil }
        let appName = first.appName

        if let cached = iconCache[appName] {
            return cached
        }

        let icon = iconForProcess(pid: first.pid, appName: appName)
        if let icon {
            iconCache[appName] = icon
        }
        return icon
    }

    private func iconForProcess(pid: Int32, appName: String) -> NSImage? {
        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            if let bundleURL = runningApp.bundleURL {
                return NSWorkspace.shared.icon(forFile: bundleURL.path)
            }
        }

        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.lowercased() == appName.lowercased()
                || ($0.bundleIdentifier?.lowercased().contains(appName.lowercased()) ?? false)
        }
        if let candidate = candidates.first, let bundleURL = candidate.bundleURL {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        return nil
    }
}
