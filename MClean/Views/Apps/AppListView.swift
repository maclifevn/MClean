import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selection: InstalledApp.ID?
    @State private var sortOrder: [KeyPathComparator<InstalledApp>] = [
        .init(\.appName, order: .forward)
    ]

    private var filteredApps: [InstalledApp] {
        let base: [InstalledApp]
        if searchText.isEmpty {
            base = appState.installedApps
        } else {
            let query = searchText.lowercased()
            base = appState.installedApps.filter {
                $0.appName.lowercased().contains(query) ||
                $0.bundleIdentifier.lowercased().contains(query)
            }
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                appTable
                    .frame(width: 300)

                Divider()

                fileDetail
                    .frame(minWidth: 380, maxWidth: .infinity)
            }

            if let report = appState.appRemovalReport {
                Divider()
                AppRemovalSummary(
                    report: report,
                    onReveal: { appState.revealForUninstall($0, app: report.app) },
                    onRequestAccess: appState.requestFullDiskAccessAndRetryUninstall,
                    onDismiss: { appState.appRemovalReport = nil }
                )
                .id(report.id)
            }
            if let status = appState.appUninstallStatus {
                Divider()
                HStack {
                    Text(status)
                    Spacer()
                    Button("Done") { appState.appUninstallStatus = nil }
                }
                .font(.callout)
                .controlSize(.small)
                .padding(12)
                .background(.bar)
            }
        }
        .task {
            // Lazy first load: installed apps are no longer walked at launch
            // (that starved cold-boot Smart Scans of disk). Load them the
            // first time the uninstaller is actually opened.
            if appState.installedApps.isEmpty && !appState.isLoadingApps {
                appState.loadInstalledApps()
            }
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle(installedAppsTitle)
        .toolbar {
            // The uninstall action lives ONLY in AppFilesView's bottom bar
            // ("Remove N files (size)"). A duplicate toolbar button used to
            // sit here, hidden via .opacity(0) when nothing was selected —
            // on macOS 26 the glass toolbar draws the tinted capsule behind
            // the button itself, so the "hidden" state rendered as an empty
            // red pill.
            ToolbarItemGroup {
                Button {
                    appState.loadInstalledApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isRemovingAppFiles || appState.isOpeningAppUninstaller)
            }
        }
        .alert("Removal Failed", isPresented: Binding(
            get: { appState.appUninstallNotice != nil },
            set: { if !$0 { appState.appUninstallNotice = nil } }
        )) {
            Button("OK", role: .cancel) { appState.appUninstallNotice = nil }
        } message: {
            Text(appState.appUninstallNotice ?? "")
        }
    }

    private var installedAppsTitle: String {
        String(format: String(localized: "Installed Apps (%lld)"), Int64(appState.installedApps.count))
    }

    // MARK: - App Table (left side)

    private var appTable: some View {
        Group {
            if appState.isLoadingApps {
                VStack(spacing: 12) {
                    ProgressView(LocalizedStringKey("Loading installed apps..."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.installedApps.isEmpty {
                EmptyStateView(
                    "No Apps Found",
                    systemImage: "square.grid.2x2",
                    description: "Could not find any installed applications.",
                    action: { appState.loadInstalledApps() },
                    actionLabel: "Retry"
                )
            } else {
                Table(filteredApps, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Application", value: \.appName) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 20, height: 20)
                            Text(app.appName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .help(app.path.path)
                    }
                    .width(min: 170, ideal: 210, max: 240)

                    TableColumn("Size", value: \.size) { app in
                        Text(app.formattedSize)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 64, ideal: 72, max: 82)
                }
                .disabled(appState.isRemovingAppFiles || appState.isOpeningAppUninstaller)
                .onChange(of: selection) { newValue in
                    guard let id = newValue,
                          let app = appState.installedApps.first(where: { $0.id == id })
                    else { return }
                    // Skip when the selection was just synced from an external
                    // (Finder Services) hand-off that already scanned this app,
                    // so we don't fire a redundant second scan.
                    guard appState.selectedApp?.id != app.id else { return }
                    appState.selectedApp = app
                    appState.scanForAppFiles(app)
                }
                .onChange(of: appState.selectedApp) { app in
                    // Reflect an externally-driven selection (Finder Services)
                    // in the table highlight.
                    if selection != app?.id { selection = app?.id }
                }
                .onAppear {
                    // Sync the highlight when this view mounts already pointed
                    // at an externally-selected app.
                    if selection != appState.selectedApp?.id {
                        selection = appState.selectedApp?.id
                    }
                }
            }
        }
    }

    // MARK: - File Detail (right side)

    @ViewBuilder
    private var fileDetail: some View {
        if let app = appState.selectedApp {
            AppFilesView(app: app)
                .id(app.id)
        } else {
            EmptyStateView(
                "Select an App",
                systemImage: "cursorarrow.click.2",
                description: "Select an app from the list to see all its related files across your system.",
                tint: Tint.purple
            )
        }
    }
}

private struct AppRemovalSummary: View {
    let report: AppRemovalReport
    let onReveal: ([URL]) -> Void
    let onRequestAccess: () -> Void
    let onDismiss: () -> Void
    @State private var showDetails = false

    private var summary: String {
        String(
            format: String(localized: "%lld moved to Trash, %lld already absent, %lld remaining"),
            Int64(report.result.moved.count), Int64(report.result.missing.count), Int64(report.result.failures.count)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.app.appName).font(.headline)
                    Text(summary).foregroundStyle(.secondary)
                }

                Spacer()

                if report.needsFullDiskAccess {
                    Button("Review Full Disk Access", action: onRequestAccess)
                }
                let revealable = report.result.failures.filter { $0.reason.canRevealInFinder }
                if !revealable.isEmpty {
                    Button("Reveal in Finder") { onReveal(revealable.map(\.target.url)) }
                }
                Button("Done", action: onDismiss)
            }

            if !report.result.failures.isEmpty {
                DisclosureGroup("Items still on disk", isExpanded: $showDetails) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(report.result.failures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.target.url.path)
                                        .textSelection(.enabled)
                                    Text(failure.reason.message)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(12)
        .background(.bar)
    }
}
