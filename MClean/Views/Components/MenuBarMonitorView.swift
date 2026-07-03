import SwiftUI
import AppKit

/// Zero-size helper that captures SwiftUI's `openWindow` action into
/// `WindowOpener.shared` when the main window appears, so the AppKit menu-bar
/// popover can reopen the window after it's been closed.
struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowOpener.shared.open = { id in openWindow(id: id) } }
    }
}

/// Drop-down panel hosted in the menu-bar `NSPopover` (via `NSHostingController`)
/// with live CPU / memory / disk meters and quick actions. Kept self-contained
/// so the menu bar surface stays decoupled from the main window's `AppState`.
struct MenuBarMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    let onSmartScan: () -> Void
    let onOpenApp: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 13)

            Divider()

            VStack(spacing: 12) {
                MeterRow(
                    title: "CPU", systemImage: "cpu", tint: Tint.blue,
                    fraction: monitor.cpuUsage,
                    detail: "\(Int((monitor.cpuUsage * 100).rounded()))%"
                )
                MeterRow(
                    title: "Memory", systemImage: "memorychip", tint: Tint.purple,
                    fraction: monitor.memoryFraction,
                    detail: byteDetail(monitor.memoryUsed, monitor.memoryTotal)
                )
                MeterRow(
                    title: "Disk", systemImage: "internaldrive", tint: Tint.green,
                    fraction: monitor.diskFraction,
                    detail: byteDetail(monitor.diskUsed, monitor.diskTotal)
                )
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                Button(action: onSmartScan) {
                    Label("Scan Now", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(action: onOpenApp) {
                    Label("Open MClean", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            HStack {
                Button(action: onOpenSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuit) {
                    Label("Quit MClean", systemImage: "power")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: 304)
        .onAppear { monitor.start(); monitor.startDetail() }
        .onDisappear { monitor.stopDetail(); monitor.stop() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            MCleanAppIcon(size: 34, shadow: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("MClean")
                    .font(.system(size: 14, weight: .semibold))
                Text("System Monitor")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(Tint.green)
                    .frame(width: 7, height: 7)
                Text("Live")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func byteDetail(_ used: Int64, _ total: Int64) -> String {
        let u = ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
        return "\(u) / \(t)"
    }

}

/// One labeled meter: title on the left, a thin tinted progress bar, and a
/// trailing numeric detail. Mirrors the restrained chrome used elsewhere.
private struct MeterRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let fraction: Double
    let detail: String

    private var clamped: Double { max(0, min(1, fraction)) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(spacing: 5) {
                HStack {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: clamped)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .controlSize(.small)
            }
        }
    }
}
