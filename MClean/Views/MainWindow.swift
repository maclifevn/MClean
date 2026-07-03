import SwiftUI

struct MainWindow: View {
    private static let sidebarWidth: CGFloat = 252

    @EnvironmentObject var appState: AppState
    @ObservedObject private var sandboxAccess = SandboxAccessManager.shared
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(minWidth: Self.sidebarWidth,
                       idealWidth: Self.sidebarWidth,
                       maxWidth: Self.sidebarWidth)
                .clipped()
            Divider()
            detailContainer
        }
        .frame(minWidth: 1000, minHeight: 680)
        .toolbar {
            topToolbarItems
        }
        .onReceive(NotificationCenter.default.publisher(for: .mCleanSmartScanRequested)) { _ in
            consumeMenuBarSmartScanRequest()
        }
        .onChange(of: appState.pendingExternalApp) { app in
            // A right-clicked app arrived via Finder Services — surface the
            // Installed Apps view so its related-files scan is visible.
            guard app != nil else { return }
            selectedSection = .apps
            appState.pendingExternalApp = nil
        }
        .onAppear {
            if NSClassFromString("XCTestCase") == nil {
                DispatchQueue.main.async {
                    sandboxAccess.requestFullScanAccessOnLaunch()
                }
            }
            // Covers a request that landed before MainWindow mounted (cold
            // launch, or while onboarding was still showing) — onChange alone
            // fires only on subsequent changes and would miss it.
            if appState.pendingExternalApp != nil {
                selectedSection = .apps
                appState.pendingExternalApp = nil
            }
            consumeMenuBarSmartScanRequest()
        }
        .alert("Couldn't clean everything", isPresented: Binding(
            get: { appState.cleanError != nil },
            set: { if !$0 { appState.cleanError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.cleanError = nil }
        } message: {
            Text(appState.cleanError ?? "")
        }
    }

    private func consumeMenuBarSmartScanRequest() {
        guard MenuBarQuickActionBuffer.smartScanRequested else { return }
        MenuBarQuickActionBuffer.smartScanRequested = false
        selectedSection = .cleaning(.smartScan)
        guard sandboxAccess.hasFullScanAccess || sandboxAccess.requestFullScanAccess() else { return }
        appState.startSmartScan()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sidebarSection("Overview") {
                        sidebarButton(section: .cleaning(.smartScan)) {
                            SidebarNavRow(
                                label: "Dashboard", icon: "sparkles",
                                tint: Tint.blue, badge: dashboardBadge,
                                isSelected: selectedSection == .cleaning(.smartScan)
                            )
                        }
                        sidebarButton(section: .spaceLens) {
                            SpaceLensNavRow(lens: appState.spaceLens,
                                            isSelected: selectedSection == .spaceLens)
                        }
                    }

                    sidebarSection("Applications") {
                        sidebarButton(section: .apps) {
                            SidebarNavRow(
                                label: "App Uninstaller",
                                icon: "square.grid.2x2.fill",
                                tint: Tint.purple,
                                badge: appState.installedApps.isEmpty ? nil : "\(appState.installedApps.count)",
                                isSelected: selectedSection == .apps
                            )
                        }
                        sidebarButton(section: .orphans) {
                            SidebarNavRow(
                                label: "Orphaned Files",
                                icon: "doc.questionmark.fill",
                                tint: Tint.pink,
                                badge: appState.orphanedFiles.isEmpty ? nil : "\(appState.orphanedFiles.count)",
                                isSelected: selectedSection == .orphans
                            )
                        }
                    }

                    sidebarSection("Cleanup") {
                        ForEach(CleaningCategory.scannable) { category in
                            sidebarButton(section: .cleaning(category)) {
                                SidebarNavRow(
                                    label: LocalizedStringKey(category.rawValue),
                                    icon: category.icon,
                                    tint: category.color,
                                    badge: sizeBadge(for: category),
                                    isSelected: selectedSection == .cleaning(category)
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 14)
            }

            Divider()
            healthFooter
        }
        .background(.bar)
    }

    private func sidebarSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .lineLimit(1)

            VStack(spacing: 2) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sidebarButton<Content: View>(
        section: AppSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            content()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? sidebarSelectionColor : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebarSelectionColor: Color {
        if controlActiveState == .inactive {
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        return Color(nsColor: .selectedContentBackgroundColor)
    }

    private var dashboardBadge: String? {
        appState.totalJunkSize > 0
            ? ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
            : nil
    }

    private func sizeBadge(for category: CleaningCategory) -> String? {
        guard let size = appState.categoryResults[category]?.totalSize, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    @ToolbarContentBuilder
    private var topToolbarItems: some ToolbarContent {
        if selectedSection == .cleaning(.smartScan) {
            ToolbarItem(placement: .automatic) {
                Button {
                    consumeMenuBarSmartScanRequest()
                    if !appState.scanState.isActive {
                        guard sandboxAccess.hasFullScanAccess || sandboxAccess.requestFullScanAccess() else { return }
                        appState.startSmartScan()
                    }
                } label: {
                    Label("Smart Scan", systemImage: "sparkles")
                }
                .disabled(appState.scanState.isActive)
            }
        }

        if selectedSection == .spaceLens {
            ToolbarItemGroup(placement: .automatic) {
                if let root = appState.spaceLens.rootNode {
                    Button {
                        appState.spaceLens.scan(root.url)
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }

                Button {
                    appState.spaceLens.chooseFolderAndScan()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
            }
        }
    }

    private var healthFooter: some View {
        let ok = sandboxAccess.hasFullScanAccess
        let tint = ok ? Tint.green : Tint.orange
        return HStack(spacing: 10) {
            PulsingDot(tint: tint, isPulsing: !ok)

            Text(ok ? "Full scan ready" : "Allow full scan")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(colorScheme == .dark
                    ? Color.white.opacity(0.92)
                    : Color.black.opacity(0.85))
                .lineLimit(1)

            Spacer(minLength: 4)
            if !ok {
                Button("Fix") {
                    _ = sandboxAccess.requestFullScanAccess()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Fix permission")
            }
        }
        .help(ok ? "All original scan locations are available" : "Select the startup disk in the macOS file picker")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContainer: some View {
        VStack(spacing: 0) {
            detailView
                .id(selectedSection)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity
                        )
                )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: selectedSection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Quiet ambient gradient under every section. Static layers,
            // opacities kept low enough to stay clean in light mode.
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [Tint.blue.opacity(0.05), .clear],
                    startPoint: .topLeading, endPoint: .center
                )
                RadialGradient(
                    colors: [Tint.purple.opacity(0.03), .clear],
                    center: .topTrailing, startRadius: 0, endRadius: 600
                )
            }
            .ignoresSafeArea()
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .apps:
            AppListView()
        case .orphans:
            OrphanListView()
        case .spaceLens:
            SpaceLensView()
        case .cleaning(let category):
            if category == .smartScan {
                DashboardView()
            } else {
                CategoryDetailView(category: category)
            }
        case nil:
            EmptyStateView("MClean", systemImage: "sparkles",
                           description: "Select a category from the sidebar to get started.")
        }
    }

}

/// Space Lens sidebar row. Observes the view model directly so the badge
/// refreshes when a scan completes — AppState deliberately doesn't republish
/// for Space Lens (its VM lives outside @Published, see AppState.spaceLens).
/// Safe to observe here: the VM's own publishes are low-frequency; the ~10Hz
/// scan counters live on separate objects (SpaceLensScanProgress / ticker).
private struct SpaceLensNavRow: View {
    @ObservedObject var lens: SpaceLensViewModel
    let isSelected: Bool

    var body: some View {
        SidebarNavRow(
            label: "Space Lens", icon: "circle.hexagongrid.fill",
            tint: Tint.cyan, badge: badge, isSelected: isSelected
        )
    }

    private var badge: String? {
        guard let size = lens.rootNode?.size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Sidebar row with a springy hover highlight. Extracted to a struct so each
/// row owns its hover state; the selected row's IconTile glows via the shared
/// glow treatment in AppTheme.
private struct SidebarNavRow: View {
    let label: LocalizedStringKey
    let icon: String
    let tint: Color
    let badge: String?
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(emphasizedSelection ? Color.white.opacity(0.95) : tint)
                .frame(width: 18)
                .fixedSize()
            Text(label)
                .font(.system(size: 13, weight: .medium))
                // Force an explicit, solid foreground instead of inheriting the
                // sidebar list's default. On some configs (custom accent /
                // reduced transparency, seen on M1 Max — issue #117) the
                // inherited emphasized/vibrant label style resolves transparent
                // and the row text disappears while explicitly-colored text
                // (headers, badges) stays visible. A colorScheme-driven solid
                // color sidesteps that vibrancy path entirely.
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, alignment: .leading)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if let badge {
                Text(badge)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(emphasizedSelection ? labelColor : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Solid, opaque label color that adapts to light/dark without routing
    /// through the sidebar's vibrant primary style (see #117).
    private var labelColor: Color {
        if emphasizedSelection { return Color.white.opacity(0.96) }
        return colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color.black.opacity(0.85)
    }

    private var emphasizedSelection: Bool {
        isSelected && controlActiveState != .inactive
    }
}

/// Small reusable status dot with optional pulse. Used in the sidebar health
/// footer and other "system status" surfaces.
private struct PulsingDot: View {
    let tint: Color
    var isPulsing: Bool = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isPulsing && !reduceMotion {
                Circle()
                    .stroke(tint.opacity(pulse ? 0.0 : 0.6), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.6 : 0.8)
            } else {
                Circle()
                    .fill(tint.opacity(0.20))
                    .frame(width: 16, height: 16)
            }
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .shadow(color: tint.opacity(0.6), radius: 3)
        }
        .frame(width: 18, height: 18)
        .onAppear { syncPulse() }
        .onChange(of: isPulsing) { _ in syncPulse() }
    }

    private func syncPulse() {
        guard isPulsing, !reduceMotion else {
            pulse = false
            return
        }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
