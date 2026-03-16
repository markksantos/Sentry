import SwiftUI
import SentryEngine

public struct HistoryView: View {

    @Bindable var viewModel: HistoryViewModel

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            entryList
        }
        .onAppear { viewModel.load() }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search history...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit { viewModel.search() }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                // App filter
                Picker("App", selection: $viewModel.selectedApp) {
                    Text("All Apps").tag(String?.none)
                    ForEach(viewModel.uniqueApps, id: \.self) { app in
                        Text(app).tag(Optional(app))
                    }
                }
                .frame(maxWidth: 140)

                // Country filter
                Picker("Country", selection: $viewModel.selectedCountry) {
                    Text("All Countries").tag(String?.none)
                    ForEach(viewModel.uniqueCountries, id: \.self) { code in
                        Text(code).tag(Optional(code))
                    }
                }
                .frame(maxWidth: 100)

                Spacer()

                Button {
                    viewModel.exportCSV()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    viewModel.clearHistory()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Entry List

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else if viewModel.filteredEntries.isEmpty {
                    emptyState
                } else {
                    Text("\(viewModel.filteredEntries.count) entries")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)

                    ForEach(viewModel.filteredEntries) { entry in
                        historyRow(entry)
                        Divider().padding(.leading, 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func historyRow(_ entry: ConnectionEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.appName)
                        .font(.caption.weight(.medium))
                    if let flag = entry.flagEmoji {
                        Text(flag)
                            .font(.caption2)
                    }
                }

                Text(entry.remoteHostname ?? entry.remoteAddress)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.protocolType.rawValue.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No history yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }
}
