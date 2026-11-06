import SwiftUI

/// View-side grouping of discovered leftovers into CleanMyMac-style buckets.
/// Purely presentational — AppState's flat `discoveredFiles` stays the source
/// of truth so the removal/selection logic is untouched.
enum LeftoverGroup: String, CaseIterable, Identifiable {
    case application = "Application"
    case caches = "Caches"
    case appSupport = "Application Support"
    case preferences = "Preferences"
    case logs = "Logs"
    case containers = "Containers"
    case launchAgents = "Launch Agents"
    case other = "Other Files"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .application: return "app.fill"
        case .caches: return "internaldrive.fill"
        case .appSupport: return "shippingbox.fill"
        case .preferences: return "gearshape.fill"
        case .logs: return "doc.text.fill"
        case .containers: return "cube.box.fill"
        case .launchAgents: return "bolt.fill"
        case .other: return "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .application: return Tint.blue
        case .caches: return Tint.orange
        case .appSupport: return Tint.purple
        case .preferences: return Tint.cyan
        case .logs: return Tint.yellow
        case .containers: return Tint.pink
        case .launchAgents: return Tint.red
        case .other: return Tint.green
        }
    }

    static func categorize(_ url: URL) -> LeftoverGroup {
        let path = url.path
        if path.hasSuffix(".app") { return .application }
        if path.contains("/Caches/") { return .caches }
        if path.contains("/Application Support/") { return .appSupport }
        if path.contains("/Preferences/") { return .preferences }
        if path.contains("/Logs/") || path.contains("/DiagnosticReports/") { return .logs }
        if path.contains("/Containers/") || path.contains("/Group Containers/") { return .containers }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") { return .launchAgents }
        return .other
    }
}

struct AppFilesView: View {
    @EnvironmentObject var appState: AppState
    let app: InstalledApp

    @State private var collapsedGroups: Set<LeftoverGroup> = []
    @State private var iconHovering = false
    /// One-pass size cache so group headers and the selected-size counter
    /// don't re-stat the disk on every render.
    @State private var sizeCache: [URL: Int64] = [:]
    @State private var groupedFiles: [(group: LeftoverGroup, urls: [URL])] = []
    @State private var groupSizeCache: [LeftoverGroup: Int64] = [:]
    @State private var showBulkRemovalConfirmation = false
    @State private var pendingRemovalURLs: Set<URL> = []
    @State private var bundledUninstaller: URL?
    @State private var checkedForUninstaller = false
    @State private var reviewManualRemoval = false
    @State private var showHomebrewConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("settings.general.confirmBeforeDelete") private var confirmBeforeDelete = true

    private var usesAdobeUninstaller: Bool { AdobeUninstaller.supports(app.bundleIdentifier) }
    private var vendorUninstaller: URL? {
        if case .homebrew = appState.appInstallSource { return nil }
        return bundledUninstaller
    }
    private var offersVendorUninstaller: Bool { usesAdobeUninstaller || vendorUninstaller != nil }
    private var canRemoveFiles: Bool {
        appState.appInstallSource == .standalone && canReviewManualRemoval
    }

    private var canReviewManualRemoval: Bool {
        (usesAdobeUninstaller || checkedForUninstaller) && (!offersVendorUninstaller || reviewManualRemoval)
    }

    private var allowsManualReview: Bool {
        switch appState.appInstallSource {
        case .standalone: return true
        case .installerPackage(let package): return package.canMoveBundle
        default: return false
        }
    }

    private var displayedFiles: [URL] {
        if appState.appInstallSource == .standalone { return appState.discoveredFiles }
        return appState.discoveredFiles.filter { $0.path == app.path.path }
    }

    private var totalSelectedSize: Int64 {
        appState.selectedFiles.reduce(Int64(0)) { total, url in
            total + (cachedSize(url) ?? 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            uninstallActions
            installationDetails

            Divider()

            // Content
            if appState.isScanningAppFiles {
                scanningState
            } else if displayedFiles.isEmpty {
                EmptyStateView(
                    "No Related Files",
                    systemImage: "checkmark.circle",
                    description: LocalizedStringKey(
                        String(format: String(localized: "No additional files found for %@."), app.appName)
                    ),
                    tint: Tint.green
                )
            } else {
                fileGroupsList.disabled(appState.isRemovingAppFiles)

                if canRemoveFiles { actionBar }
            }
        }
        .task(id: app.id) {
            guard !usesAdobeUninstaller else { return }
            let path = app.path
            let url = await Task.detached(priority: .utility) {
                AppUninstaller.bundledUninstaller(for: path)
            }.value
            guard !Task.isCancelled else { return }
            bundledUninstaller = url
            checkedForUninstaller = true
        }
        .task(id: displayedFiles) {
            let urls = displayedFiles
            let buckets = Dictionary(grouping: urls, by: LeftoverGroup.categorize)
            groupedFiles = LeftoverGroup.allCases.compactMap { group in
                guard let grouped = buckets[group], !grouped.isEmpty else { return nil }
                return (group, grouped)
            }
            sizeCache = [:]
            groupSizeCache = [:]

            let bundlePath = app.path.path
            let bundleSize = app.size
            let worker = Task.detached(priority: .utility) { () -> [URL: Int64] in
                var cache: [URL: Int64] = [:]
                for url in urls {
                    guard !Task.isCancelled else { break }
                    cache[url] = url.path == bundlePath ? bundleSize : FileSizeCalculator.size(of: url) ?? 0
                }
                return cache
            }
            let sizes = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, displayedFiles == urls else { return }
            sizeCache = sizes
            groupSizeCache = Dictionary(uniqueKeysWithValues: groupedFiles.map { entry in
                (entry.group, entry.urls.reduce(0) { $0 + (sizes[$1] ?? 0) })
            })
        }
        .onChange(of: showBulkRemovalConfirmation) { appState.showCleanConfirmation = $0 }
        .onDisappear { appState.showCleanConfirmation = false }
        .confirmationDialog(
            String(format: String(localized: "Move %lld files to the Trash?"), Int64(pendingRemovalURLs.count)),
            isPresented: $showBulkRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                appState.removeSelectedFiles(for: app, confirmedURLs: pendingRemovalURLs)
                pendingRemovalURLs = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items can be restored from the Trash.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 48, height: 48)
                .scaleEffect(iconHovering && !reduceMotion ? 1.06 : 1)
                .animation(reduceMotion ? nil : MotionTokens.snappy, value: iconHovering)
                .onHover { iconHovering = $0 }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.title3.bold())
                if let version = app.version {
                    Text(String(format: String(localized: "Version %@"), version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(app.path.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(app.path.path)
            }

            Spacer()

            if canRemoveFiles && !appState.discoveredFiles.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(filesCountText(count: appState.discoveredFiles.count))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    CountUpBytes(bytes: totalSelectedSize)
                        .font(.callout.bold())
                }
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9),
                           value: appState.discoveredFiles.count)
            }
        }
        .padding()
    }

    private var uninstallActions: some View {
        HStack {
            if usesAdobeUninstaller {
                Button {
                    Task { await appState.openAdobeUninstaller(for: app) }
                } label: {
                    Label("Uninstall with Adobe", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)

                if appState.isOpeningAppUninstaller {
                    ProgressView().controlSize(.small)
                }
            } else if let vendorUninstaller {
                Button {
                    appState.revealForUninstall([vendorUninstaller], app: app)
                } label: {
                    Label("Reveal Vendor Uninstaller", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
            }

            if offersVendorUninstaller && allowsManualReview && !reviewManualRemoval {
                Button("Review Manual Removal") { reviewManualRemoval = true }
            }

            Spacer()

            Button {
                appState.revealForUninstall([app.path], app: app)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .help("Reveal in Finder")
        }
        .controlSize(.small)
        .disabled(appState.isRemovingAppFiles || appState.isOpeningAppUninstaller)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var installationDetails: some View {
        Group {
            switch appState.appInstallSource {
            case .none:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking how this app was installed…").foregroundStyle(.secondary)
                }
            case .standalone:
                EmptyView()
            case .homebrew(let cask):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Installed with Homebrew", systemImage: "shippingbox")
                        .font(.headline)
                    Text("\(cask.token) · \(cask.version)").foregroundStyle(.secondary)
                    if !cask.canRunInMClean {
                        Text("Review this cask’s uninstall command in Terminal. Its recipe may affect other components.")
                            .foregroundStyle(.secondary)
                        if !cask.otherManagedPaths.isEmpty {
                            Text(cask.otherManagedPaths.joined(separator: "\n"))
                                .lineLimit(3)
                                .font(.caption)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                        Text(cask.terminalCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    HStack {
                        if cask.canRunInMClean {
                            Button("Uninstall with Homebrew", role: .destructive) { showHomebrewConfirmation = true }
                                .buttonStyle(.borderedProminent)
                                .confirmationDialog("Uninstall with Homebrew?", isPresented: $showHomebrewConfirmation,
                                                    titleVisibility: .visible) {
                                    Button("Uninstall with Homebrew", role: .destructive) {
                                        Task { await appState.uninstallHomebrewCask(cask, for: app) }
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Homebrew will uninstall this cask using its standard removal command.")
                                }
                        }
                        Button("Copy Terminal Command") {
                            Task { await appState.copyHomebrewUninstallCommand(cask, for: app) }
                        }
                    }
                }
            case .installerPackage(let package):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Installed from a package", systemImage: "shippingbox")
                        .font(.headline)
                    Text(package.receipts.map { "\($0.id) · \($0.version)" }.joined(separator: "\n"))
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    if package.canMoveBundle {
                        Text("Manual removal moves only this application bundle to the Trash.")
                            .foregroundStyle(.secondary)
                        if canReviewManualRemoval {
                            Button("Move App to Trash", role: .destructive) {
                                pendingRemovalURLs = [app.path]
                                showBulkRemovalConfirmation = true
                            }
                        }
                    } else {
                        Text("Use the developer’s uninstaller for this package and its components.")
                            .foregroundStyle(.secondary)
                    }
                }
            case .unverified:
                Text("The installation source could not be verified. Review this app in Finder.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
        .font(.callout)
        .disabled(appState.isRemovingAppFiles || appState.isOpeningAppUninstaller)
        .padding(.horizontal)
        .padding(.bottom, appState.appInstallSource == .standalone ? 0 : 10)
    }

    // MARK: - Scanning state

    private var scanningState: some View {
        VStack(spacing: 14) {
            Spacer()
            if reduceMotion {
                ProgressView(LocalizedStringKey("Scanning for related files..."))
            } else {
                SearchPulse()
                Text("Scanning for related files...")
                    .font(.system(size: 13, weight: .medium))
            }
            Text(checkingLocationsText(count: appState.currentAppFileSearchLocationCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grouped list

    private var fileGroupsList: some View {
        List {
            ForEach(groupedFiles, id: \.group) { entry in
                DisclosureGroup(isExpanded: groupExpansionBinding(entry.group)) {
                    // No .staggered() inside the lazy List — a delayed reveal
                    // would blank rows as they scroll in. The removal
                    // transition still sweeps deleted rows out.
                    ForEach(entry.urls, id: \.self) { fileURL in
                        FileRow(
                            fileURL: fileURL,
                            isSelected: canRemoveFiles ? fileSelectionBinding(for: fileURL) : nil,
                            fileSize: cachedSize(fileURL),
                            onRemove: canRemoveFiles ? {
                                appState.removeSelectedFiles(for: app, confirmedURLs: [fileURL])
                            } : nil
                        )
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                )
                        )
                    }
                } label: {
                    groupHeader(entry.group, urls: entry.urls)
                }
            }
        }
        .id(app.id)
    }

    private func groupHeader(_ group: LeftoverGroup, urls: [URL]) -> some View {
        let groupSize = groupSizeCache[group] ?? 0
        let allSelected = urls.allSatisfy { appState.selectedFiles.contains($0) }

        return HStack(spacing: 10) {
            if canRemoveFiles {
                Toggle(isOn: Binding(
                    get: { allSelected },
                    set: { selected in
                        if selected {
                            appState.selectedFiles.formUnion(urls)
                        } else {
                            appState.selectedFiles.subtract(urls)
                        }
                    }
                )) {
                    Text(LocalizedStringKey(group.rawValue))
                }
                .toggleStyle(AnimatedCheckboxStyle())
                .labelsHidden()
            }

            IconTile(systemName: group.icon, tint: group.tint, size: 22, corner: 6)
            Text(LocalizedStringKey(group.rawValue))
                .font(.system(size: 12.5, weight: .semibold))
            Text("\(urls.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: groupSize, countStyle: .file))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func groupExpansionBinding(_ group: LeftoverGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group) },
            set: { expanded in
                let change = {
                    if expanded {
                        collapsedGroups.remove(group)
                    } else {
                        collapsedGroups.insert(group)
                    }
                }
                if reduceMotion {
                    change()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { change() }
                }
            }
        )
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            Button("Select All") {
                appState.selectedFiles = Set(appState.discoveredFiles)
            }
            Button("Deselect All") {
                appState.selectedFiles.removeAll()
            }

            Spacer()

            if !appState.selectedFiles.isEmpty {
                Button(role: .destructive) {
                    if confirmBeforeDelete {
                        pendingRemovalURLs = appState.selectedFiles
                        showBulkRemovalConfirmation = true
                    } else {
                        appState.removeSelectedFiles(for: app, confirmedURLs: appState.selectedFiles)
                    }
                } label: {
                    Text(removeFilesLabel)
                }
                .buttonStyle(GlowProminentButtonStyle(tint: Tint.red, gradient: TintGradient.destructive))
                .disabled(appState.isRemovingAppFiles)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                   value: appState.selectedFiles.isEmpty)
        .padding()
        .background(.bar)
    }

    // MARK: - Helpers

    private func filesCountText(count: Int) -> String {
        String(format: String(localized: "%lld files"), Int64(count))
    }

    private func checkingLocationsText(count: Int) -> String {
        String(format: String(localized: "Checking %lld locations..."), Int64(count))
    }

    private var removeFilesLabel: String {
        String(
            format: String(localized: "Remove %lld files (%@)"),
            Int64(appState.selectedFiles.count),
            ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
        )
    }

    private func fileSelectionBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { appState.selectedFiles.contains(url) },
            set: { selected in
                if selected {
                    appState.selectedFiles.insert(url)
                } else {
                    appState.selectedFiles.remove(url)
                }
            }
        )
    }

    private func cachedSize(_ url: URL) -> Int64? {
        sizeCache[url]
    }

}

/// Magnifier over expanding sonar rings — the "actively searching" beat for
/// the related-files scan. Only built when Reduce Motion is off.
private struct SearchPulse: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(Tint.blue.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulse ? 1.8 : 1.0)
                    .opacity(pulse ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 1.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.7),
                        value: pulse
                    )
            }
            Circle()
                .fill(Tint.blue.opacity(0.12))
                .frame(width: 44, height: 44)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Tint.blue)
        }
        .frame(width: 56, height: 56)
        .onAppear { pulse = true }
    }
}

// MARK: - File Row with hover-to-reveal actions

struct FileRow: View {
    let fileURL: URL
    let isSelected: Binding<Bool>?
    let fileSize: Int64?
    let onRemove: (() -> Void)?

    @State private var isHovering = false
    @State private var showConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("settings.general.confirmBeforeDelete") private var confirmBeforeDelete = true

    var body: some View {
        Group {
            if let isSelected {
                Toggle(isOn: isSelected) { rowContents }
                    .toggleStyle(AnimatedCheckboxStyle())
            } else {
                rowContents
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .scaleEffect(isHovering && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
            if let onRemove {
                Button("Move to Trash", role: .destructive) { requestRemoval(onRemove) }
            }
        }
        .alert(
            Text(String(format: String(localized: "Remove %@?"), fileURL.lastPathComponent)),
            isPresented: $showConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove?() }
        } message: {
            Text("This item will be moved to the Trash and can be restored.")
        }
    }

    private var rowContents: some View {
        HStack {
            Image(nsImage: FileIconCache.icon(forPath: fileURL.path))
                .resizable()
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(fileURL.lastPathComponent)
                    .lineLimit(1)
                Text(fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Buttons stay in the layout permanently and fade with
            // hover, so the trailing size badge never jumps sideways.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .opacity(isHovering ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (isHovering ? 1 : 0.8))
            .allowsHitTesting(isHovering)

            if let onRemove {
                Button {
                    requestRemoval(onRemove)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this file")
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (isHovering ? 1 : 0.8))
                .allowsHitTesting(isHovering)
            }

            if let size = fileSize {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func requestRemoval(_ remove: () -> Void) {
        if confirmBeforeDelete { showConfirmation = true } else { remove() }
    }
}
