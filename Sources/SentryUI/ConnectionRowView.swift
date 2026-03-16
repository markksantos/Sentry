import SwiftUI
import SentryEngine

public struct ConnectionRowView: View {

    public let entry: ConnectionEntry
    public let isTracker: Bool

    public init(entry: ConnectionEntry, isTracker: Bool = false) {
        self.entry = entry
        self.isTracker = isTracker
    }

    public var body: some View {
        HStack(spacing: 8) {
            protocolBadge
            directionArrow
            addressInfo
            Spacer()
            if isTracker {
                trackerBadge
            }
            statePill
        }
        .frame(height: 36)
        .padding(.vertical, 2)
    }

    // MARK: - Protocol Badge

    private var protocolBadge: some View {
        Text(entry.protocolType.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(entry.protocolType == .tcp ? Color.blue : Color.purple)
            )
    }

    // MARK: - Direction Arrow

    private var directionArrow: some View {
        Image(systemName: directionIconName)
            .font(.caption)
            .foregroundStyle(directionColor)
            .frame(width: 14)
    }

    private var directionIconName: String {
        switch entry.direction {
        case .outbound: return "arrow.up.right"
        case .inbound:  return "arrow.down.left"
        case .unknown:  return "arrow.left.arrow.right"
        }
    }

    private var directionColor: Color {
        switch entry.direction {
        case .outbound: return .blue
        case .inbound:  return .green
        case .unknown:  return .gray
        }
    }

    // MARK: - Address Info

    private var addressInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let flag = entry.flagEmoji {
                    Text(flag)
                        .font(.caption)
                }
                Text(remoteDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 4) {
                if let hostname = entry.remoteHostname, !hostname.isEmpty,
                   hostname != remoteDisplay.replacingOccurrences(of: ":\(entry.remotePort)", with: "") {
                    Text(hostname)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("\(entry.localAddress):\(entry.localPort)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var remoteDisplay: String {
        if let hostname = entry.remoteHostname, !hostname.isEmpty {
            return "\(hostname):\(entry.remotePort)"
        }
        return "\(entry.remoteAddress):\(entry.remotePort)"
    }

    // MARK: - Tracker Badge

    private var trackerBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .help("Known tracker domain")
    }

    // MARK: - State Pill

    private var statePill: some View {
        Text(entry.state.displayName)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(stateTextColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(entry.state.color.opacity(0.2))
            )
            .overlay(
                Capsule()
                    .strokeBorder(entry.state.color.opacity(0.4), lineWidth: 0.5)
            )
    }

    private var stateTextColor: Color {
        switch entry.state {
        case .established, .listen, .synSent, .synReceived, .closing, .lastAck:
            return entry.state.color
        default:
            return .primary
        }
    }
}
