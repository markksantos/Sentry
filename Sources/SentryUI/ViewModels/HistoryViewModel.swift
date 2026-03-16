import AppKit
import Foundation
import Observation
import SentryEngine

@MainActor
@Observable
public final class HistoryViewModel {

    public var entries: [ConnectionEntry] = []
    public var searchText: String = ""
    public var selectedApp: String?
    public var selectedCountry: String?
    public var isLoading: Bool = false

    private var store: SQLiteStore?

    public init() {
        self.store = try? SQLiteStore()
    }

    // MARK: - Computed

    public var filteredEntries: [ConnectionEntry] {
        var result = entries
        if let app = selectedApp, !app.isEmpty {
            result = result.filter { $0.appName == app }
        }
        if let country = selectedCountry, !country.isEmpty {
            result = result.filter { $0.countryCode == country }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.appName.lowercased().contains(query)
                    || $0.remoteAddress.lowercased().contains(query)
                    || ($0.remoteHostname?.lowercased().contains(query) ?? false)
            }
        }
        return result
    }

    public var uniqueApps: [String] {
        Array(Set(entries.map(\.appName))).sorted()
    }

    public var uniqueCountries: [String] {
        Array(Set(entries.compactMap(\.countryCode))).sorted()
    }

    // MARK: - Actions

    public func load() {
        guard let store else { return }
        isLoading = true
        Task {
            let result = try? await store.allEntries(limit: 1000, offset: 0)
            entries = result ?? []
            isLoading = false
        }
    }

    public func search() {
        guard let store, !searchText.isEmpty else {
            load()
            return
        }
        isLoading = true
        Task {
            let result = try? await store.search(term: searchText)
            entries = result ?? []
            isLoading = false
        }
    }

    public func exportCSV() {
        guard let store else { return }
        Task {
            if let url = try? await store.exportCSV() {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func clearHistory() {
        guard let store else { return }
        Task {
            try? await store.clearHistory()
            entries = []
        }
    }
}
