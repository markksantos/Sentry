import SwiftUI
import SentryEngine

public struct MenuBarView: View {

    @Bindable var viewModel: DashboardViewModel
    @State private var showSettings = false
    @State private var historyViewModel = HistoryViewModel()

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Divider()

            switch viewModel.selectedTab {
            case .live:
                liveContent
            case .history:
                HistoryView(viewModel: historyViewModel)
            }

            Divider()
            footer
        }
        .frame(width: 420, height: 560)
        .background(.ultraThinMaterial)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sentry")
                    .font(.headline)
                Text("\(viewModel.totalConnectionCount) active connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.scanNow()
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        Picker("", selection: $viewModel.selectedTab) {
            ForEach(DashboardViewModel.Tab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onChange(of: viewModel.selectedTab) { _, newValue in
            if newValue == .history {
                historyViewModel.load()
            }
        }
    }

    // MARK: - Live Content

    private var liveContent: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            connectionList
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search apps or addresses...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.body)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var connectionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.filteredSummaries.isEmpty {
                    emptyState
                } else {
                    AppListView(
                        summaries: $viewModel.appSummaries,
                        filtered: viewModel.filteredSummaries,
                        viewModel: viewModel
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(viewModel.isScanning ? "No connections found" : "Scanner stopped")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let lastScan = viewModel.lastScanTime {
                Text("Updated \(lastScan, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Waiting for first scan...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
