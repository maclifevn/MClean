import Foundation

actor CleaningEngine {
    private let fileManager = FileManager.default
    private let trashHandler: @Sendable (URL) throws -> Void
    private let homeDirectory: URL
    private var homePath: String { homeDirectory.path }

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, trashHandler: @escaping @Sendable (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) {
        self.homeDirectory = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(homeDirectory)
        self.trashHandler = trashHandler
    }

    // Broad roots may contain unrelated user data. Items strictly below them
    // are accepted, but the roots themselves are never removable.
    private var cleanupSubtreeRoots: [String] { [
        "\(homePath)/Library/Caches",
        "\(homePath)/Library/Logs",
        "\(homePath)/Library/Mail Downloads",
        "\(homePath)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        "\(homePath)/.Trash",
        "\(homePath)/.cache",
        "/Library/Caches", "/Library/Logs",
        "/private/var/log", "/private/var/tmp",
        "/var/log", "/var/tmp", "/tmp", "/private/tmp",
    ] }

    // Dedicated cache/history locations emitted as whole-directory items by
    // their scanners, so equality is intentional.
    private var removableCleanupRoots: [String] { [
        "\(homePath)/Library/Developer/Xcode/DerivedData",
        "\(homePath)/Library/Developer/Xcode/Archives",
        "\(homePath)/Library/Developer/CoreSimulator/Caches",
        "\(homePath)/Library/Developer/Xcode/iOS DeviceSupport",
        "\(homePath)/Library/Developer/Xcode/watchOS DeviceSupport",
        "\(homePath)/Library/Developer/Xcode/tvOS DeviceSupport",
        "\(homePath)/Library/Developer/Xcode/XCTestDevices",
        "\(homePath)/Library/Developer/Xcode/Previews",
        "\(homePath)/Library/Developer/Xcode/SourcePackages",
        "\(homePath)/Library/Developer/CoreSimulator/XCTestDevices",
        "\(homePath)/.npm",
        "\(homePath)/.ollama/logs",
        "\(homePath)/.ollama/history",
        "\(homePath)/.lmstudio/server-logs",
        "\(homePath)/.lmstudio/conversations",
        "\(homePath)/Library/WebKit/com.electron.ollama",
        "\(homePath)/Library/Saved Application State/com.electron.ollama.savedState",
        "\(homePath)/Library/pnpm/store",
        "\(homePath)/.local/share/pnpm/store",
        "\(homePath)/.pnpm-store",
        "\(homePath)/.orbstack/cache",
        "\(homePath)/.orbstack/log",
        "\(homePath)/Library/HTTPStorages",
        "\(homePath)/Library/Containers/com.docker.docker/Data/cache",
        "\(homePath)/Library/Containers/com.docker.docker/Data/log",
        "\(homePath)/Library/Containers/com.docker.docker/Data/tmp",
        "\(homePath)/Library/Group Containers/group.com.docker/Caches",
        "\(homePath)/.docker/cli-plugins/.cache",
        "\(homePath)/.docker/buildx/cache",
        "/opt/homebrew/Library/Caches",
        "/usr/local/Homebrew/Library/Caches",
    ] }

    private var explicitFileRoots: [String] { [
        "\(homePath)/Downloads/",
        "\(homePath)/Documents/",
        "\(homePath)/Desktop/",
    ] }

    struct CleaningResult {
        var processedSpace: Int64 = 0
        var itemsCleaned: Int = 0
        var errors: [String] = []
        var cleanedPaths: Set<String> = []
        var permissionDeniedPaths: Set<String> = []
        var trashedPaths: Set<String> = []
    }

    // MARK: - Public API

    func cleanItems(_ items: [CleanableItem], progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        let operation = FileOperationTracker.shared.begin()
        defer { FileOperationTracker.shared.end(operation) }
        var result = CleaningResult()
        let total = items.count

        for (index, item) in items.enumerated() {
            let progress = Double(index + 1) / Double(total)
            defer { progressHandler(progress) }
            guard !Task.isCancelled else { break }

            guard CleaningCategory.scannable.contains(item.category) else {
                result.errors.append("Cleanup category is unavailable: \(item.category.rawValue)")
                continue
            }
            guard !CleanupExclusions.excludes(item.path, paths: CleanupExclusions.paths()) else {
                result.errors.append("Excluded from cleanup: \(item.name)")
                continue
            }
            if item.category == .dockerCache, item.path == CleanableItem.dockerPrunePath {
                guard let executable = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
                    .first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
                    result.errors.append("Docker command not found")
                    continue
                }
                do {
                    let command = try await BrewProcessRunner.run(executableURL: URL(fileURLWithPath: executable),
                        arguments: ["system", "prune", "-f"], timeout: 120)
                    if command.status == 0 {
                        result.itemsCleaned += 1
                        result.cleanedPaths.insert(item.path)
                        // The estimate from system df is not proof of freed space.
                    } else {
                        result.errors.append("Docker prune failed: " + (String(data: command.stderr, encoding: .utf8) ?? ""))
                    }
                } catch { result.errors.append("Docker prune failed: " + error.localizedDescription) }
                continue
            }
            if item.isActionItem {
                // Runtime removal cannot be restored from Trash. Only an
                // explicitly selected, valid runtime is accepted here.
                guard item.category == .xcodeJunk,
                      let identifier = item.simctlRuntimeIdentifier,
                      UUID(uuidString: identifier) != nil else {
                    result.errors.append("Unsupported cleanup action: \(item.name)")
                    continue
                }
                let command = SimulatorRuntimeSupport.runXcrun(["simctl", "runtime", "delete", identifier])
                if command.status == 0 {
                    result.processedSpace += item.size
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                } else {
                    result.errors.append("\(item.name): \(command.stderr)")
                }
                continue
            }

            do {
                let itemURL = URL(fileURLWithPath: item.path)
                guard !FileProtection.hasUnexpectedSymlink(in: item.path) else {
                    result.errors.append("Skipped symlink path: \(item.path)")
                    continue
                }
                guard !ProviderPaths.isProviderOwned(item.path, homeDirectory: homeDirectory),
                      !FileProtection.isCloudPlaceholder(at: itemURL),
                      !FileProtection.isProtectedFromDeletion(path: item.path) else {
                    result.errors.append("Protected from cleanup: \(item.path)")
                    continue
                }
                guard fileManager.fileExists(atPath: item.path) else {
                    // The desired end state is already true; remove stale scan
                    // rows without reporting a bogus permission failure.
                    result.cleanedPaths.insert(item.path)
                    continue
                }

                if (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    let msg = "Skipped symbolic link: \(item.path)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }

                // Security: resolve symlinks and validate the real target. The
                // operation still uses the original URL after a second stable
                // resolution check, so legitimate system aliases such as /tmp
                // work without allowing a final-component symlink.
                let resolvedURL = itemURL.resolvingSymlinksInPath()
                let resolved = resolvedURL.path

                // Large files surfaced by scanLargeFiles are per-file items
                // under Downloads/Documents/Desktop; those get a narrower check
                // instead of the whole-subtree allow-list.
                let isManaged = XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(item.path, homeDirectory: homeDirectory)
                let pathAccepted: Bool = {
                    if isManaged {
                        return item.category == .xcodeJunk
                            && (item.path as NSString).standardizingPath == (resolved as NSString).standardizingPath
                            && XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(resolved, homeDirectory: homeDirectory)
                    }
                    if item.category == .largeFiles {
                        return isExplicitSingleFileDeletable(resolvedPath: resolved)
                            && (try? itemURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                    }
                    if item.category == .trashBins {
                        return resolved.hasPrefix(homePath + "/.Trash/")
                    }
                    return isSafeToDelete(resolvedPath: resolved)
                }()
                guard pathAccepted else {
                    let msg = "Skipped symlink or unsafe path: \(item.path) -> \(resolved)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }

                // Narrow the TOCTOU window: re-resolve right before the delete
                // and require the resolved path to still match. Any concurrent
                // swap between check and delete aborts the operation.
                let reResolved = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
                guard reResolved == resolved else {
                    let msg = "Aborting delete: path resolution changed between check and unlink for \(item.path)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }

                var lifecycleLock: XcodeBuildMCPDerivedDataSupport.LifecycleLock?
                if isManaged, XcodeBuildMCPDerivedDataSupport.workspaceKey(forManagedDerivedDataPath: resolved, homeDirectory: homeDirectory) != nil {
                    guard let lock = XcodeBuildMCPDerivedDataSupport.acquireLifecycleLock(forManagedDerivedDataPath: resolved, homeDirectory: homeDirectory, fileManager: fileManager) else {
                        result.errors.append("Skipped XcodeBuildMCP DerivedData: lifecycle lock is unavailable: \(item.path)")
                        continue
                    }
                    lifecycleLock = lock
                }
                defer {
                    if let lock = lifecycleLock {
                        XcodeBuildMCPDerivedDataSupport.releaseLifecycleLock(lock, fileManager: fileManager)
                    }
                }
                if item.category == .trashBins {
                    // Empty Trash is the one intentionally permanent action:
                    // these items are already in Trash, so trashItem cannot move
                    // them anywhere safer. Every other cleanup remains recoverable.
                    try fileManager.removeItem(at: itemURL)
                } else if isManaged {
                    var destination: NSURL?
                    try fileManager.trashItem(at: resolvedURL, resultingItemURL: &destination)
                    if let path = destination?.path { result.trashedPaths.insert(path) }
                } else {
                    try trashHandler(itemURL)
                }
                result.processedSpace += item.size
                result.itemsCleaned += 1
                result.cleanedPaths.insert(item.path)
            } catch {
                let detail = "\(item.name) at \(item.path): \(error.localizedDescription)"
                result.errors.append(detail)
                if Self.isPermissionDenied(error) {
                    result.permissionDeniedPaths.insert(item.path)
                }
                Logger.shared.log("Clean failed: \(detail)", level: .error)
            }
        }

        return result
    }

    // MARK: - Helpers

    /// Validates that a resolved path is safe to delete.
    /// Prevents symlink attacks where a link in ~/Library/Caches points to ~/.ssh.
    /// Downloads, Documents, and Desktop are intentionally NOT whole-subtree
    /// allow-listed - scanLargeFiles emits per-file items instead, so those
    /// deletions can still happen through the explicit per-item flow.
    func isSafeToDelete(resolvedPath: String) -> Bool {
        let normalized = (resolvedPath as NSString).standardizingPath
        guard !ProviderPaths.isProviderOwned(normalized, homeDirectory: homeDirectory),
              !CleanupExclusions.excludes(normalized, paths: CleanupExclusions.paths()) else { return false }
        if isContainerCache(normalized) { return true }
        if removableCleanupRoots.contains(normalized) { return true }
        if cleanupSubtreeRoots.contains(where: { root in
            let rootWithSeparator = root.hasSuffix("/") ? root : root + "/"
            return normalized.hasPrefix(rootWithSeparator)
        }) { return true }
        return removableCleanupRoots.contains { root in
            normalized.hasPrefix(root + "/")
        }
    }

    /// Allow a single-file delete under Downloads/Documents/Desktop when it
    /// was explicitly surfaced by a scanner (e.g. scanLargeFiles). Whole-subtree
    /// deletion of those roots remains blocked.
    func isExplicitSingleFileDeletable(resolvedPath: String) -> Bool {
        let normalized = (resolvedPath as NSString).standardizingPath
        guard !ProviderPaths.isProviderOwned(normalized, homeDirectory: homeDirectory),
              !CleanupExclusions.excludes(normalized, paths: CleanupExclusions.paths()) else { return false }
        return explicitFileRoots.contains { normalized.hasPrefix($0) }
    }

    private func isContainerCache(_ path: String) -> Bool {
        for (root, suffix) in [
            (homePath + "/Library/Containers/", "/Data/Library/Caches"),
            (homePath + "/Library/Group Containers/", "/Library/Caches")
        ] where path.hasPrefix(root) {
            let remainder = String(path.dropFirst(root.count))
            guard let separator = remainder.firstIndex(of: "/") else { continue }
            let subpath = String(remainder[separator...])
            if subpath == suffix || subpath.hasPrefix(suffix + "/") { return true }
        }
        return false
    }

    // MARK: - Space Lens (move to Trash)

    struct TrashResult {
        var processedSpace: Int64 = 0
        var trashedCount = 0
        var trashedPaths: Set<String> = []
        var errors: [String] = []
    }

    /// Moves arbitrary user-chosen items to the Trash for Space Lens and the
    /// orphan finder. Unlike cleanItems, this accepts paths outside the cleanup
    /// scanner's cache/log allow-list because the operation is recoverable. A
    /// narrow deny-list still protects structural roots.
    func trashItems(_ items: [(url: URL, size: Int64)]) async -> TrashResult {
        let operation = FileOperationTracker.shared.begin()
        defer { FileOperationTracker.shared.end(operation) }
        var result = TrashResult()

        for item in items {
            guard !Task.isCancelled else { break }
            guard !FileProtection.hasUnexpectedSymlink(in: item.url.path),
                  !CleanupExclusions.excludes(item.url.path, paths: CleanupExclusions.paths()),
                  !FileProtection.isCloudPlaceholder(at: item.url),
                  !FileProtection.isProtectedFromDeletion(path: item.url.path) else {
                result.errors.append("Refusing to trash excluded or protected path: \(item.url.path)")
                continue
            }
            guard fileManager.fileExists(atPath: item.url.path) else {
                result.trashedPaths.insert(item.url.path)
                continue
            }

            let resolved = item.url.resolvingSymlinksInPath().path
            guard !isProtectedFromTrashing(resolvedPath: resolved) else {
                let msg = "Refusing to trash protected path: \(item.url.path)"
                Logger.shared.log(msg, level: .warning)
                result.errors.append(msg)
                continue
            }
            // Same TOCTOU narrowing as cleanItems: re-resolve right before
            // acting and abort if a concurrent swap changed the target.
            guard item.url.resolvingSymlinksInPath().path == resolved,
                  !FileProtection.hasUnexpectedSymlink(in: item.url.path) else {
                let msg = "Aborting trash: path resolution changed for \(item.url.path)"
                Logger.shared.log(msg, level: .warning)
                result.errors.append(msg)
                continue
            }

            do {
                try trashHandler(item.url)
                result.processedSpace += item.size
                result.trashedCount += 1
                result.trashedPaths.insert(item.url.path)
                // .debug so per-item successes go to os.Logger only, not the
                // in-memory diagnostics ring when trashing many items at once.
                Logger.shared.log("Trashed \(item.url.path)", level: .debug)
            } catch {
                let detail = "\(item.url.lastPathComponent): \(error.localizedDescription)"
                result.errors.append(detail)
                Logger.shared.log("Trash failed: \(detail)", level: .error)
            }
        }

        return result
    }

    /// Structural roots and sensitive trees Space Lens must never trash.
    func isProtectedFromTrashing(resolvedPath: String) -> Bool {
        let home = homePath
        let normalized = (resolvedPath as NSString).standardizingPath
        if ProviderPaths.isProviderOwned(normalized, homeDirectory: homeDirectory) { return true }
        let protectedExactRoots = [
            "/", "/Users", "/Volumes",
            home,
            "\(home)/Library",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Applications",
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Preferences",
            "\(home)/Library/Logs",
            "\(home)/Library/LaunchAgents",
        ]
        if protectedExactRoots.contains(normalized) { return true }

        let protectedTrees = [
            "/System", "/Applications", "/Library", "/private",
            "/usr", "/bin", "/sbin", "/etc", "/var",
            "\(home)/Library/Accounts",
            "\(home)/Library/Calendars",
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Keychains",
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/Safari",
        ] + highRiskHomeDotPaths
        if protectedTrees.contains(where: {
            normalized == $0 || normalized.hasPrefix($0 + "/")
        }) {
            return true
        }

        // Other users' home folders are never valid targets. The current
        // user's descendants remain available subject to the checks above.
        if normalized.hasPrefix("/Users/") && !normalized.hasPrefix(home + "/") {
            return true
        }
        return false
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError)) ||
            (nsError.domain == NSPOSIXErrorDomain &&
             (nsError.code == Int(EACCES) || nsError.code == Int(EPERM))) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }

}
