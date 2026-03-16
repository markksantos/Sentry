import SwiftUI
import SentryEngine

struct AppListView: View {

    @Binding var summaries: [AppSummary]
    let filtered: [AppSummary]
    let viewModel: DashboardViewModel

    var body: some View {
        ForEach(filtered) { summary in
            disclosureSection(for: summary)
        }
    }

    // MARK: - Disclosure Section

    @ViewBuilder
    private func disclosureSection(for summary: AppSummary) -> some View {
        let isExpanded = bindingForExpansion(appName: summary.appName)

        DisclosureGroup(isExpanded: isExpanded) {
            VStack(spacing: 0) {
                ForEach(summary.connections) { connection in
                    ConnectionRowView(
                        entry: connection,
                        isTracker: viewModel.isTracker(connection)
                    )
                    .contextMenu {
                        connectionContextMenu(entry: connection)
                    }
                    if connection.id != summary.connections.last?.id {
                        Divider()
                            .padding(.leading, 32)
                    }
                }
            }
            .padding(.leading, 4)
        } label: {
            appLabel(for: summary)
                .contextMenu {
                    appContextMenu(for: summary)
                }
        }
        .padding(.vertical, 4)
    }

    // MARK: - App Label

    private func appLabel(for summary: AppSummary) -> some View {
        HStack(spacing: 10) {
            if let icon = summary.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.dashed")
                    .font(.title3)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }

            Text(summary.appName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text("\(summary.connectionCount)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(.secondary.opacity(0.6))
                )
        }
        .contentShape(Rectangle())
    }

    // MARK: - Context Menus

    private func appContextMenu(for summary: AppSummary) -> some View {
        Group {
            Button {
                viewModel.trustAllForApp(summary.appName)
            } label: {
                Label("Trust All from \(summary.appName)", systemImage: "checkmark.shield")
            }
        }
    }

    private func connectionContextMenu(entry: ConnectionEntry) -> some View {
        let host = entry.remoteHostname ?? entry.remoteAddress
        return Group {
            Button {
                viewModel.setTrust(app: entry.appName, host: host, level: .trusted)
            } label: {
                Label("Mark as Trusted", systemImage: "checkmark.circle")
            }

            Button {
                viewModel.setTrust(app: entry.appName, host: host, level: .suspicious)
            } label: {
                Label("Mark as Suspicious", systemImage: "exclamationmark.triangle")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(entry.remoteAddress):\(entry.remotePort)", forType: .string)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }

            if let hostname = entry.remoteHostname {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hostname, forType: .string)
                } label: {
                    Label("Copy Hostname", systemImage: "doc.on.doc")
                }
            }
        }
    }

    // MARK: - Helpers

    private func bindingForExpansion(appName: String) -> Binding<Bool> {
        Binding<Bool>(
            get: {
                summaries.first(where: { $0.appName == appName })?.isExpanded ?? false
            },
            set: { newValue in
                if let idx = summaries.firstIndex(where: { $0.appName == appName }) {
                    summaries[idx].isExpanded = newValue
                }
            }
        )
    }
}
