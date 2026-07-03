import AppKit
import Combine
import Foundation

/// Owns every filesystem location MClean may scan. Access to the startup disk
/// comes only from the native open panel and is persisted as a security-scoped
/// bookmark; MClean never changes privacy settings on the user's behalf.
@MainActor
final class SandboxAccessManager: ObservableObject {
    static let shared = SandboxAccessManager()
    nonisolated static let authorizedPathsKey = "MClean.AuthorizedFolderPaths"

    nonisolated static var authorizedPaths: [String] {
        UserDefaults.standard.stringArray(forKey: authorizedPathsKey) ?? []
    }

    nonisolated static let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    nonisolated static let startupDiskURL = URL(fileURLWithPath: "/", isDirectory: true)

    nonisolated static var hasPersistedFullScanAccess: Bool {
        authorizedPaths.contains { path in
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == startupDiskURL.path
        }
    }

    @Published private(set) var authorizedURLs: [URL] = []

    private let defaultsKey = "MClean.SecurityScopedFolderBookmarks"
    private var activeURLs: [URL] = []
    private var presentedAutomaticFullScanRequest = false

    private init() {
        restoreBookmarks()
    }

    var hasAuthorizedFolders: Bool { !authorizedURLs.isEmpty }

    var hasFullScanAccess: Bool {
        authorizedURLs.contains { root in
            root.resolvingSymlinksInPath().standardizedFileURL.path == Self.startupDiskURL.path
        }
    }

    /// Used by both onboarding and the main window so upgraded installations
    /// receive the same one-time native request without presenting two panels.
    func requestFullScanAccessOnLaunch() {
        guard !hasFullScanAccess, !presentedAutomaticFullScanRequest else { return }
        presentedAutomaticFullScanRequest = true
        let panel = makeFullScanPanel()
        // Automatic consent must be modeless. Calling runModal from a SwiftUI
        // onAppear callback can re-enter AppKit while the window is laying out,
        // which triggers _NSDetectedLayoutRecursion.
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in
                _ = self?.acceptFullScanSelection(panel.url)
            }
        }
    }

    /// Requests the single user-controlled grant needed to preserve the
    /// original scanner's Home, /Library, Homebrew and shared-data coverage.
    /// The startup disk is preselected and macOS remains responsible for the
    /// consent UI.
    @discardableResult
    func requestFullScanAccess() -> Bool {
        guard !hasFullScanAccess else { return true }
        let panel = makeFullScanPanel()
        guard panel.runModal() == .OK else { return false }
        return acceptFullScanSelection(panel.url)
    }

    private func makeFullScanPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.prompt = String(localized: "Allow Full Scan")
        panel.message = String(localized: "Select your startup disk to let MClean scan the same locations as the original version.")
        return panel
    }

    private func acceptFullScanSelection(_ selection: URL?) -> Bool {
        guard let selected = selection?.standardizedFileURL else { return false }
        let resolved = selected.resolvingSymlinksInPath().standardizedFileURL
        guard resolved == Self.startupDiskURL else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "Select your startup disk")
            alert.informativeText = String(localized: "Choose the disk where macOS is installed so every original scan category remains available. No access is granted until you confirm it in the macOS picker.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return false
        }

        // Persist the exact Powerbox URL returned by NSOpenPanel; resolve its
        // symlink only for validation so the bookmark retains the system-issued
        // sandbox extension.
        return persistPanelURLs([selected])
    }

    @discardableResult
    func chooseFolders() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Allow Access")
        panel.message = String(localized: "Choose only the folders you want MClean to scan and clean.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return false }
        return persistPanelURLs(panel.urls.map(\.standardizedFileURL))
    }

    private func persistPanelURLs(_ urls: [URL]) -> Bool {
        var bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        for url in urls where !authorizedURLs.contains(url) {
            do {
                let data = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                bookmarks.append(data)
                retainPanelGrant(url)
            } catch {
                Logger.shared.log("Could not save folder access for \(url.path): \(error.localizedDescription)", level: .error)
            }
        }
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
        authorizedURLs = deduplicated(activeURLs)
        persistPaths()
        return hasAuthorizedFolders
    }

    func revokeAll() {
        activeURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        activeURLs.removeAll()
        authorizedURLs.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.authorizedPathsKey)
    }

    private func restoreBookmarks() {
        let bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var refreshed: [Data] = []
        for data in bookmarks {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ).standardizedFileURL
                activateBookmark(url)
                if stale {
                    refreshed.append(try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ))
                } else {
                    refreshed.append(data)
                }
            } catch {
                Logger.shared.log("Discarding invalid folder bookmark: \(error.localizedDescription)", level: .warning)
            }
        }
        UserDefaults.standard.set(refreshed, forKey: defaultsKey)
        authorizedURLs = deduplicated(activeURLs)
        persistPaths()
    }

    /// NSOpenPanel already starts the security scope for returned URLs. Keep
    /// the URL alive and balance that grant when the user revokes access.
    private func retainPanelGrant(_ url: URL) {
        guard !activeURLs.contains(url) else { return }
        activeURLs.append(url)
    }

    /// Restored bookmarks do not receive an automatic sandbox extension, so
    /// they must explicitly start their security scope.
    private func activateBookmark(_ url: URL) {
        guard !activeURLs.contains(url) else { return }
        guard url.startAccessingSecurityScopedResource() else {
            Logger.shared.log("macOS did not grant access to \(url.path)", level: .warning)
            return
        }
        activeURLs.append(url)
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func persistPaths() {
        UserDefaults.standard.set(authorizedURLs.map(\.path), forKey: Self.authorizedPathsKey)
    }
}
