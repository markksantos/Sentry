import SwiftUI
import SentryEngine

public struct AppDetailView: View {

    public let summary: AppSummary

    public init(summary: AppSummary) {
        self.summary = summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            connectionsList
        }
        .padding()
        .frame(minWidth: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            if let icon = summary.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 36))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.appName)
                    .font(.title3.weight(.semibold))

                Text("\(summary.connectionCount) connection\(summary.connectionCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Connections List

    private var connectionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(summary.connections) { connection in
                    ConnectionRowView(entry: connection)
                    if connection.id != summary.connections.last?.id {
                        Divider()
                            .padding(.leading, 24)
                    }
                }
            }
        }
    }
}
