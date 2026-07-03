import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            CleaningSettingsView()
                .tabItem { Label("Cleaning", systemImage: "trash") }
            ScheduleSettingsView()
                .tabItem { Label("Schedule", systemImage: "clock") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 430)
    }
}

// MARK: - General

enum SearchSensitivity: String, CaseIterable, Identifiable, Codable {
    case strict = "Strict"
    case enhanced = "Enhanced"
    case deep = "Deep"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .strict: return "Exact bundle ID and name matches only. Safest option."
        case .enhanced: return "Includes partial name matching and bundle ID components."
        case .deep: return "Includes company name, entitlements, and team identifier matching."
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("settings.general.launchAtLogin") private var launchAtLogin = false
    @AppStorage("settings.general.searchSensitivity") private var sensitivity: SearchSensitivity = .enhanced
    @AppStorage("settings.general.confirmBeforeDelete") private var confirmBeforeDelete = true
    @AppStorage("settings.general.menuBarMonitor") private var menuBarMonitor = true
    @AppStorage("settings.general.hideDockIcon") private var hideDockIcon = false
    @AppStorage(Haptics.soundEffectsKey) private var soundEffects = true
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRaw = AppLanguage.current.rawValue
    @State private var languageNeedsRelaunch = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var sandboxAccess = SandboxAccessManager.shared

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch MClean at login", isOn: launchAtLoginBinding)
            }

            Section("App Scanning") {
                Picker("Search sensitivity", selection: $sensitivity) {
                    ForEach(SearchSensitivity.allCases) { level in
                        VStack(alignment: .leading) {
                            Text(LocalizedStringKey(level.rawValue))
                            Text(LocalizedStringKey(level.description))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Language") {
                Picker("Language", selection: appLanguageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }

                if languageNeedsRelaunch {
                    Text("Restart MClean to apply the selected language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    Button("Relaunch Now") {
                        relaunchApp()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Section("System Monitor") {
                Toggle("Show system monitor in menu bar", isOn: menuBarMonitorBinding)
                Text("Live CPU, memory, and disk meters in the menu bar. MClean keeps running in the background while this is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dock") {
                Toggle("Hide Dock icon", isOn: hideDockIconBinding)
                Text("Hides MClean from the Dock and the ⌘Tab app switcher. Reopen it from the menu-bar monitor or by launching MClean again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Folder Access") {
                if !sandboxAccess.hasFullScanAccess {
                    Text("Select the startup disk to preserve the original Smart Scan coverage. macOS asks you to confirm it in the native file picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("All original scan locations are available", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(Tint.green)
                    ForEach(sandboxAccess.authorizedURLs, id: \.path) { url in
                        Text(url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path)
                    }
                }
                HStack {
                    if !sandboxAccess.hasFullScanAccess {
                        Button("Allow Full Scan…") { _ = sandboxAccess.requestFullScanAccess() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Add Folder…") { _ = sandboxAccess.chooseFolders() }
                    if sandboxAccess.hasAuthorizedFolders {
                        Button("Revoke Access", role: .destructive) { sandboxAccess.revokeAll() }
                    }
                }
            }

            Section("Sound") {
                Toggle("Play sound effects", isOn: $soundEffects)
            }

            Section("Safety") {
                Toggle("Confirm before deleting files", isOn: $confirmBeforeDelete)
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                   value: languageNeedsRelaunch)
    }

    private var hideDockIconBinding: Binding<Bool> {
        Binding(
            get: { hideDockIcon },
            set: { newValue in
                hideDockIcon = newValue
                // Tell AppDelegate to switch the activation policy live.
                NotificationCenter.default.post(name: .mCleanDockIconChanged, object: nil)
            }
        )
    }

    private var menuBarMonitorBinding: Binding<Bool> {
        Binding(
            get: { menuBarMonitor },
            set: { newValue in
                menuBarMonitor = newValue
                // Tell AppDelegate to add/remove the status item without relaunch.
                NotificationCenter.default.post(name: .mCleanMenuBarMonitorChanged, object: nil)
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                toggleLaunchAtLogin(newValue)
            }
        )
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRaw) ?? .system },
            set: { newValue in
                appLanguageRaw = newValue.rawValue
                applyLanguage(newValue)
            }
        )
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger.shared.log("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)", level: .error)
            launchAtLogin = !enabled
        }
    }

    private func applyLanguage(_ language: AppLanguage) {
        AppLanguagePreferences.apply(language)
        languageNeedsRelaunch = true
    }

    private func relaunchApp() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]

        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            Logger.shared.log("Failed to relaunch MClean: \(error.localizedDescription)", level: .error)
        }
    }
}

// MARK: - Cleaning

struct CleaningSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.cleaning.skipHiddenFiles") private var skipHiddenFiles = true
    @AppStorage("settings.cleaning.largeFileThreshold") private var largeFileThresholdMB: Int = 100
    @AppStorage("settings.cleaning.oldFileMonths") private var oldFileMonths: Int = 12

    private static let excludedFoldersKey = "settings.cleaning.largeFileExcludedFolders"
    @State private var excludedFolders: [String] = []

    var body: some View {
        Form {
            Section("File Discovery") {
                Toggle("Skip hidden files during scan", isOn: $skipHiddenFiles)
            }

            Section("Large Files") {
                Stepper(
                    String(format: String(localized: "Minimum size: %lld MB"), Int64(largeFileThresholdMB)),
                    value: $largeFileThresholdMB,
                    in: 10...1000,
                    step: 10
                )
                Stepper(
                    String(format: String(localized: "Files older than: %lld months"), Int64(oldFileMonths)),
                    value: $oldFileMonths,
                    in: 1...60
                )
            }

            Section("Excluded Folders") {
                if excludedFolders.isEmpty {
                    Text("Files inside these folders are skipped from the Large & Old Files scan (Downloads, Documents, Desktop).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedFolders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((folder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folder)
                            Spacer()
                            Button {
                                removeExcludedFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Remove from exclusions"))
                        }
                    }
                }
                Button("Add Folder…") { addExcludedFolder() }
            }

            Section("Orphan Finder") {
                HStack {
                    // Read the live count directly (it's a UserDefaults-backed
                    // computed property on AppState) so it stays correct when
                    // orphans are ignored from the Orphans view while this tab
                    // is open. AppState fires objectWillChange on both ignore
                    // (via @Published orphanedFiles) and clear, re-rendering this.
                    Text(String(format: String(localized: "Ignored orphans: %lld"), Int64(appState.ignoredOrphanCount)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget Ignored") {
                        appState.clearIgnoredOrphans()
                    }
                    .disabled(appState.ignoredOrphanCount == 0)
                }
                Text("Ignored files won't appear in future orphan scans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            excludedFolders = UserDefaults.standard.stringArray(forKey: Self.excludedFoldersKey) ?? []
        }
    }

    private func persistExcludedFolders() {
        UserDefaults.standard.set(excludedFolders, forKey: Self.excludedFoldersKey)
    }

    private func addExcludedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder…")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !excludedFolders.contains(url.path) {
            excludedFolders.append(url.path)
        }
        persistExcludedFolders()
    }

    private func removeExcludedFolder(_ folder: String) {
        excludedFolders.removeAll { $0 == folder }
        persistExcludedFolders()
    }
}

// MARK: - Schedule

struct ScheduleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("Automatic Scanning") {
                Toggle("Enable scheduled scanning", isOn: $appState.scheduler.config.isEnabled)

                if appState.scheduler.config.isEnabled {
                    Group {
                        Picker("Scan interval", selection: $appState.scheduler.config.interval) {
                            ForEach(ScheduleInterval.allCases) { interval in
                                Text(LocalizedStringKey(interval.rawValue)).tag(interval)
                            }
                        }

                        Toggle("Auto-clean after scan", isOn: $appState.scheduler.config.autoClean)
                        Toggle("Notify on completion", isOn: $appState.scheduler.config.notifyOnCompletion)

                        HStack {
                            Text("Last run")
                            Spacer()
                            Text(appState.scheduler.config.formattedLastRun)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                   value: appState.scheduler.config.isEnabled)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    MCleanAppIcon(size: 64, shadow: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MClean")
                            .font(.title2.weight(.semibold))
                        Text(
                            String(
                                format: String(localized: "Version %@"),
                                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                            )
                        )
                            .foregroundStyle(.secondary)
                        Text("Free, open-source macOS app manager.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section {
                Link("GitHub Repository", destination: URL(string: "https://github.com/PhamHungTien/MClean")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/PhamHungTien/MClean/issues")!)
            }

            Section {
                // Kept compact on purpose: the whole About tab must fit the
                // Settings window without a scroll bar (~150pt QR still scans
                // fine from a phone camera).
                HStack(alignment: .center, spacing: 16) {
                    Image("DonateQR")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Buy me a coffee ☕")
                            .font(.headline)
                        Text("If MClean is useful to you, a small donation keeps it going. Thank you!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Scan with MoMo or your banking app (VietQR · Napas 247)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }

            Section {
                Text("MIT License")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
