import AppKit
import Darwin
import Foundation

struct AppRemovalTarget: Sendable {
    let url: URL
    fileprivate let identity: Identity?

    init(_ url: URL) {
        self.url = url
        identity = Self.readIdentity(at: url).identity
    }

    var isMissing: Bool {
        let error = Self.readIdentity(at: url).error
        return error == ENOENT || error == ENOTDIR
    }

    var matchesCurrentItem: Bool {
        matchesItem(at: url)
    }

    func matchesItem(at url: URL) -> Bool {
        guard let identity else { return false }
        return Self.readIdentity(at: url).identity == identity
    }

    fileprivate struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let createdSeconds: Int
        let createdNanoseconds: Int
    }

    fileprivate static func readIdentity(at url: URL) -> (identity: Identity?, error: Int32) {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return (nil, errno) }
        return (Identity(device: value.st_dev, inode: value.st_ino,
                         createdSeconds: value.st_birthtimespec.tv_sec,
                         createdNanoseconds: value.st_birthtimespec.tv_nsec), 0)
    }
}

struct AppRemovalFailure: Identifiable, Sendable {
    let target: AppRemovalTarget
    let reason: Reason

    var id: URL { target.url }

    enum Reason: Equatable, Sendable {
        case protected, changed, permission, fullDiskAccess
        case other(String)

        var message: String {
            switch self {
            case .protected: return String(localized: "Protected from removal.")
            case .changed: return String(localized: "This item changed after the scan.")
            case .permission: return String(localized: "macOS denied permission to move this item.")
            case .fullDiskAccess: return String(localized: "This location may need Full Disk Access.")
            case .other(let message): return message
            }
        }

        var canRevealInFinder: Bool { self == .permission || self == .fullDiskAccess }
    }
}

struct AppRemovalResult: Sendable {
    var moved: [URL] = []
    var missing: [URL] = []
    var failures: [AppRemovalFailure] = []
}

struct AppRemovalReport: Identifiable {
    let id = UUID()
    let app: InstalledApp
    let result: AppRemovalResult
    let source: AppInstallSource

    var needsFullDiskAccess: Bool {
        result.failures.contains { $0.reason == .fullDiskAccess }
    }
}

enum AppUninstaller {
    static func isRelatedPath(_ url: URL, app: URL, otherApps: [URL], conflictingNames: Set<String> = []) -> Bool {
        let path = url.standardizedFileURL.path
        let appPath = app.standardizedFileURL.path
        if path == appPath { return true }
        guard !appPath.hasPrefix(path + "/"),
              !url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
              names(for: url).isDisjoint(with: conflictingNames) else { return false }
        return !otherApps.contains { other in
            let otherPath = other.standardizedFileURL.path
            return otherPath == path || otherPath.hasPrefix(path + "/")
        }
    }

    static func isSelectedByDefault(
        _ url: URL,
        app: InstalledApp,
        hasOtherVersion: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        if url.standardizedFileURL.path == app.path.standardizedFileURL.path { return true }
        guard !hasOtherVersion else { return false }

        let path = url.standardizedFileURL.path
        let folders = ["Application Support", "Caches", "Containers", "HTTPStorages", "Logs",
                       "Preferences", "Saved Application State"]
        guard folders.contains(where: { path.hasPrefix(homeDirectory.path + "/Library/" + $0 + "/") })
        else { return false }

        return !names(for: app).isDisjoint(with: names(for: url))
    }

    static func conflictingNames(for app: InstalledApp, otherApps: [InstalledApp]) -> Set<String> {
        Set(otherApps.flatMap { names(for: $0) }).subtracting(names(for: app))
    }

    private static func names(for app: InstalledApp) -> Set<String> {
        Set([app.appName, app.bundleIdentifier, app.path.deletingPathExtension().lastPathComponent]
            .filter { !$0.isEmpty }.map { $0.lowercased() })
    }

    private static func names(for url: URL) -> Set<String> {
        let knownExtensions = ["plist", "log", "savedstate"]
        let filename = url.lastPathComponent
        if knownExtensions.contains(url.pathExtension.lowercased()) {
            return [filename.lowercased(), url.deletingPathExtension().lastPathComponent.lowercased()]
        }
        return [filename.lowercased()]
    }

    static func runningApplication(at url: URL) -> NSRunningApplication? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }
    }

    static func bundledUninstaller(for app: URL) -> URL? {
        guard let team = AppCodeSignature.teamIdentifier(at: app) else { return nil }
        let name = app.deletingPathExtension().lastPathComponent
        let parent = app.deletingLastPathComponent()
        var candidates = [
            parent.appendingPathComponent("Uninstall \(name).app"),
            parent.appendingPathComponent("\(name) Uninstaller.app"),
        ]
        var folders = ["Contents/Resources", "Contents/Helpers", "Contents/SharedSupport"]
            .map { app.appendingPathComponent($0) }
        if parent.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
            folders.append(parent)
        }
        for folder in folders {
            candidates.append(folder.appendingPathComponent("Uninstall.app"))
            candidates.append(folder.appendingPathComponent("Uninstaller.app"))
        }
        return candidates.first { url in
            !FileProtection.hasUnexpectedSymlink(in: url.path)
                && AppCodeSignature.isValid(at: url, requirement: "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }
    }

    static func moveToTrash(
        _ targets: [AppRemovalTarget],
        app: URL,
        otherApps: [URL],
        conflictingNames: Set<String> = [],
        hasFullDiskAccess: Bool,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> AppRemovalResult {
        var result = AppRemovalResult()
        for target in targets {
            let url = target.url
            if !isRelatedPath(url, app: app, otherApps: otherApps, conflictingNames: conflictingNames)
                || FileProtection.isProtectedUninstallPath(url) {
                result.failures.append(.init(target: target, reason: .protected))
                continue
            }

            let current = AppRemovalTarget.readIdentity(at: url)
            if current.error == ENOENT || current.error == ENOTDIR {
                result.missing.append(url)
                continue
            }
            guard let original = target.identity, original == current.identity else {
                let reason: AppRemovalFailure.Reason = current.error == EACCES || current.error == EPERM
                    ? permissionFailure(at: url, hasFullDiskAccess: hasFullDiskAccess) : .changed
                result.failures.append(.init(target: target, reason: reason))
                continue
            }

            do {
                try trash(url)
                result.moved.append(url)
            } catch {
                let error = error as NSError
                if isMissingFile(error), AppRemovalTarget.readIdentity(at: url).error == ENOENT {
                    result.missing.append(url)
                    continue
                }
                let reason: AppRemovalFailure.Reason = CleaningEngine.isPermissionDenied(error)
                    ? permissionFailure(at: url, hasFullDiskAccess: hasFullDiskAccess)
                    : .other(error.localizedDescription)
                result.failures.append(.init(target: target, reason: reason))
                Logger.shared.log("Could not move \(url.path) to the Trash: \(error.localizedDescription)", level: .warning)
            }
        }
        return result
    }

    private static func permissionFailure(at url: URL, hasFullDiskAccess: Bool) -> AppRemovalFailure.Reason {
        let library = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/"
        let privacyProtected = ["Containers/", "Group Containers/", "Application Scripts/"]
        return !hasFullDiskAccess && privacyProtected.contains(where: { url.path.hasPrefix(library + $0) })
            ? .fullDiskAccess : .permission
    }

    private static func isMissingFile(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
