import SwiftUI

public struct SettingsView: View {

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("scanInterval") private var scanInterval = 3
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true

    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            settingsList
            Divider()
            aboutSection
        }
        .frame(width: 340)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Settings List

    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Launch at Login
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                        .font(.subheadline.weight(.medium))
                    Text("Start Sentry automatically when you log in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            // Scan Interval
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Interval")
                        .font(.subheadline.weight(.medium))
                    Text("How often to check for new connections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(
                    "\(scanInterval)s",
                    value: $scanInterval,
                    in: 1...10,
                    step: 1
                )
                .labelsHidden()
                Text("\(scanInterval)s")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 30, alignment: .trailing)
            }

            Divider()

            // Notifications
            Toggle(isOn: $notificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                        .font(.subheadline.weight(.medium))
                    Text("Alert on suspicious connections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
        .padding(16)
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 4) {
            Text("Sentry")
                .font(.subheadline.weight(.semibold))
            Text("Version \(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("macOS Network Monitor")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
