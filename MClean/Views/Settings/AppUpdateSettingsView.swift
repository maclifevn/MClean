import AppKit
import SwiftUI

struct AppUpdateSettingsView: View {
    @ObservedObject private var updater = UpdateService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep MClean up to date")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Download and install verified updates within MClean.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if updater.isChecking { ProgressView().controlSize(.small) }
                Button("Check for Updates") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates || !updater.hasStarted)
                    .accessibilityIdentifier("settings.checkForUpdates")
            }

            status

            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticChecks($0) }
            ))
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticInstallation($0) }
            ))
            .disabled(!updater.automaticallyChecksForUpdates)

            Text("MClean checks once a day. Automatic installation takes effect when you quit the app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if updater.isWaitingToInstall {
                Label("The update will restart MClean after the current task finishes.", systemImage: "hourglass")
                    .font(.caption)
            }
            if let checked = updater.lastChecked {
                Text(String(format: String(localized: "Last checked: %@"), checked.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Link("View releases", destination: UpdateService.releasesURL)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .available(let version):
            Label(String(format: String(localized: "MClean %@ is available"), version), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Tint.blue)
        case .upToDate:
            Label("You're using the latest available version of MClean.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't check for updates", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tint.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
