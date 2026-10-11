import Foundation

actor ScanEngine {
    private let fileManager = FileManager.default
    private let home: String

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        home = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(homeDirectory).path
    }

    /// Live path reporter for the dashboard's scanning ticker. Throttled so
    /// a directory with thousands of entries doesn't flood the main actor.
    private var onPath: (@Sendable (String) -> Void)?
    private var lastReport = Date.distantPast

    /// `path` is an autoclosure so the String is only materialized after the
    /// throttle gate passes — a deep home-directory walk enumerates hundreds
    /// of thousands of entries and only ~12/sec are ever displayed.
    private func report(_ path: @autoclosure () -> String) {
        guard let onPath else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        onPath(path())
    }

    private struct CleanupTarget {
        let name: String
        let path: String
        let isSelected: Bool
        let minimumSize: Int64

        init(name: String, path: String, isSelected: Bool = true, minimumSize: Int64 = 1024) {
            self.name = name
            self.path = path
            self.isSelected = isSelected
            self.minimumSize = minimumSize
        }
    }

    enum NodeCacheManager: String, CaseIterable {
        case npm
        case yarn
        case pnpm
    }

    // MARK: - Public API

    func scanCategory(
        _ category: CleaningCategory,
        onPath: (@Sendable (String) -> Void)? = nil
    ) async -> CategoryResult {
        self.onPath = onPath
        defer { self.onPath = nil }
        let result: CategoryResult
        switch category {
        case .smartScan:
            result = CategoryResult(category: category, items: [], totalSize: 0)
        case .systemJunk:
            result = scanSystemJunk()
        case .userCache:
            result = scanUserCache()
        case .aiApps:
            result = scanAIApps()
        case .mailAttachments:
            result = scanMailAttachments()
        case .trashBins:
            result = scanTrash()
        case .largeFiles:
            result = scanLargeFiles()
        case .purgeableSpace:
            result = CategoryResult(category: category, items: [], totalSize: 0)
        case .xcodeJunk:
            result = scanXcodeJunk()
        case .brewCache:
            result = await scanBrewCache()
        case .nodeCache:
            result = await scanNodeCache()
        case .dockerCache:
            result = await scanDockerCache()
        case .universalBinaries:
            result = CategoryResult(category: category, items: [], totalSize: 0)
        case .languageFiles:
            result = CategoryResult(category: category, items: [], totalSize: 0)
        }
        let excluded = CleanupExclusions.paths()
        let items = result.items.filter { item in
            !CleanupExclusions.excludes(item.path, paths: excluded)
                && (item.isActionItem || !ProviderPaths.isProviderOwned(item.path, homeDirectory: URL(fileURLWithPath: home, isDirectory: true)))
        }
        return CategoryResult(category: category, items: items, totalSize: items.reduce(0) { $0 + $1.size })
    }

    func getDiskInfo() -> DiskInfo {
        var info = DiskInfo()
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: "/")
            if let total = attrs[.systemSize] as? Int64 {
                info.totalSpace = total
            }
            if let free = attrs[.systemFreeSize] as? Int64 {
                info.freeSpace = free
            }
            info.usedSpace = info.totalSpace - info.freeSpace

            // Use URLResourceValues for accurate purgeable space detection
            let rootURL = URL(fileURLWithPath: "/")
            let values = try rootURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let importantCapacity = values.volumeAvailableCapacityForImportantUsage,
               let freeCapacity = values.volumeAvailableCapacity {
                // Purgeable = important capacity (free + purgeable) minus actual free
                let purgeable = importantCapacity - Int64(freeCapacity)
                if purgeable > 10 * 1024 * 1024 { // Only report if > 10 MB
                    info.purgeableSpace = purgeable
                }
            }
        } catch {
            Logger.shared.log("Disk info unavailable: \(error.localizedDescription)", level: .warning)
        }
        return info
    }

    // MARK: - Scanners

    private func scanSystemJunk() -> CategoryResult {
        var items: [CleanableItem] = []
        var totalSize: Int64 = 0

        let systemPaths = [
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log",
            "\(home)/Library/Logs",
            "/tmp",
            "/private/var/tmp",
        ]

        for path in systemPaths {
            let scanned = scanDirectory(path: path, category: .systemJunk)
            items.append(contentsOf: scanned)
        }

        totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .systemJunk, items: items, totalSize: totalSize)
    }

    private func scanUserCache() -> CategoryResult {
        var items: [CleanableItem] = []
        // Exclude cache roots claimed by dedicated categories to avoid double-counting,
        // plus cloud File Provider state, which lives under Caches but is a live
        // database rather than reclaimable junk (issue #142).
        let excludedRootPaths = Set(([
            "\(home)/Library/Caches/Homebrew",
            "\(home)/Library/Caches/com.electron.ollama",
            "\(home)/Library/Caches/ollama",
            "\(home)/Library/Caches/npm",
            "\(home)/Library/Caches/Yarn",
            "\(home)/Library/Caches/ms-playwright",
            "\(home)/Library/Caches/node-gyp",
            "\(home)/Library/Caches/electron",
            "\(home)/Library/Caches/electron-builder",
            "\(home)/Library/Caches/dev.kdrag0n.MacVirt",
        ] + ProviderPaths.deniedRoots(homeDirectory: URL(fileURLWithPath: home, isDirectory: true))).map(normalizePath))

        // Dynamically enumerate ~/Library/Caches/ so every subdirectory is visible
        let cachePath = "\(home)/Library/Caches"
        let scanned = scanDirectory(
            path: cachePath,
            category: .userCache,
            excluding: excludedRootPaths
        )
        items.append(contentsOf: scanned)

        // Also scan for npm/pip/yarn caches
        let devCaches = [
            "\(home)/.cache/pip",
            "\(home)/Library/Caches/pip",
        ]

        for path in devCaches {
            if let item = makeCleanupItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                category: .userCache
            ) {
                items.append(item)
            }
        }

        // Sandboxed apps keep their caches inside per-app containers, not
        // ~/Library/Caches — on modern macOS this is where most of the
        // "user cache" gigabytes actually live. One item per container,
        // skipping near-empty caches (< 1 MB).
        let containerRoots = [
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
        ]
        for root in containerRoots {
            guard let containers = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            // App containers nest caches under Data/; group containers don't.
            let cacheSubpath = root.hasSuffix("Group Containers")
                ? "Library/Caches"
                : "Data/Library/Caches"
            for container in containers {
                let cachePath = (root as NSString)
                    .appendingPathComponent(container)
                    .appending("/" + cacheSubpath)
                // Same symlink defense as scanDirectory: an app at this UID
                // could plant Data or Data/Library as a symlink into an
                // allow-listed root and have the target sized here and later
                // deleted. Only accept paths that resolve to themselves.
                let resolvedCachePath = URL(fileURLWithPath: cachePath).resolvingSymlinksInPath().path
                guard normalizePath(resolvedCachePath) == normalizePath(cachePath) else { continue }
                if let item = makeCleanupItem(
                    name: "\(container) (sandbox cache)",
                    path: cachePath,
                    category: .userCache,
                    minimumSize: 1024 * 1024
                ) {
                    items.append(item)
                }
            }
        }

        // Per-app HTTP cookie/response storage — one entry per app, same
        // non-recursive shape as the top-level Caches pass above. CFNetwork
        // keeps each native app's cookies and HSTS state here, i.e. live
        // login sessions rather than regenerable cache, so these entries
        // start unselected and the user opts in per app.
        let httpStorages = scanDirectory(
            path: "\(home)/Library/HTTPStorages",
            category: .userCache,
            isSelected: false
        )
        items.append(contentsOf: httpStorages)

        let uniqueItems = deduplicatedItems(items)
        let totalSize = uniqueItems.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .userCache, items: uniqueItems, totalSize: totalSize)
    }

    private func scanAIApps() -> CategoryResult {
        let targets = [
            CleanupTarget(
                name: String(localized: "Ollama Logs"),
                path: "\(home)/.ollama/logs"
            ),
            CleanupTarget(
                name: String(localized: "Ollama Cache"),
                path: "\(home)/Library/Caches/ollama"
            ),
            CleanupTarget(
                name: String(localized: "Ollama Electron Cache"),
                path: "\(home)/Library/Caches/com.electron.ollama"
            ),
            CleanupTarget(
                name: String(localized: "Ollama WebKit Data"),
                path: "\(home)/Library/WebKit/com.electron.ollama"
            ),
            CleanupTarget(
                name: String(localized: "Ollama Saved State"),
                path: "\(home)/Library/Saved Application State/com.electron.ollama.savedState"
            ),
            CleanupTarget(
                name: String(localized: "Ollama CLI Prompt History (Optional)"),
                path: "\(home)/.ollama/history",
                isSelected: false,
                minimumSize: 0
            ),
            CleanupTarget(
                name: String(localized: "LM Studio Server Logs"),
                path: "\(home)/.lmstudio/server-logs"
            ),
            CleanupTarget(
                name: String(localized: "LM Studio Conversations (Optional)"),
                path: "\(home)/.lmstudio/conversations",
                isSelected: false,
                minimumSize: 0
            ),
            CleanupTarget(name: String(localized: "Hugging Face downloads (Optional)"), path: "\(home)/.cache/huggingface/hub", isSelected: false),
            CleanupTarget(name: String(localized: "Hugging Face datasets (Optional)"), path: "\(home)/.cache/huggingface/datasets", isSelected: false),
            CleanupTarget(name: String(localized: "Hugging Face Xet cache (Optional)"), path: "\(home)/.cache/huggingface/xet", isSelected: false),
        ]

        let items = deduplicatedItems(targets.compactMap { target in
            makeCleanupItem(
                name: target.name,
                path: target.path,
                category: .aiApps,
                isSelected: target.isSelected,
                minimumSize: target.minimumSize
            )
        })
        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .aiApps, items: items.sorted { $0.size > $1.size }, totalSize: totalSize)
    }

    private func scanMailAttachments() -> CategoryResult {
        var items: [CleanableItem] = []

        let mailPaths = [
            "\(home)/Library/Mail Downloads",
            "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        ]

        for path in mailPaths {
            let scanned = scanDirectory(path: path, category: .mailAttachments)
            items.append(contentsOf: scanned)
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .mailAttachments, items: items, totalSize: totalSize)
    }

    private func scanTrash() -> CategoryResult {
        var items: [CleanableItem] = []

        let trashPath = "\(home)/.Trash"
        let scanned = scanDirectory(path: trashPath, category: .trashBins)
        items.append(contentsOf: scanned)

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .trashBins, items: items, totalSize: totalSize)
    }

    private func scanLargeFiles() -> CategoryResult {
        var items: [CleanableItem] = []

        // Honor the thresholds the user set in Settings → Cleaning. These keys
        // were previously surfaced in the UI but never read here, so the sliders
        // did nothing; defaults match the old hardcoded 100 MB / 12-month values.
        let defaults = UserDefaults.standard
        let thresholdMB = defaults.object(forKey: "settings.cleaning.largeFileThreshold") as? Int ?? 100
        let oldFileMonths = defaults.object(forKey: "settings.cleaning.oldFileMonths") as? Int ?? 12
        let minSize = Int64(max(1, thresholdMB)) * 1024 * 1024
        let oldCutoff = Calendar.current.date(byAdding: .month, value: -max(1, oldFileMonths), to: Date())
            ?? Date.distantPast

        // Folders the user excluded from the large-file scan (issue #121) —
        // e.g. VM images, media libraries, project assets they never want
        // surfaced. Files anywhere inside an excluded folder are skipped, and
        // the directory subtree is pruned so we don't even walk it.
        let excludedFolders = (defaults.stringArray(forKey: "settings.cleaning.largeFileExcludedFolders") ?? [])
            .map(normalizePath)
            .filter { !$0.isEmpty }

        // Honor the "Skip hidden files during scan" toggle, which was a dead
        // control until now (no scanner read it). Default true preserves the
        // previous always-skip behavior.
        let skipHidden = defaults.object(forKey: "settings.cleaning.skipHiddenFiles") as? Bool ?? true
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if skipHidden { enumerationOptions.insert(.skipsHiddenFiles) }

        func isExcluded(_ path: String) -> Bool {
            let normalized = normalizePath(path)
            return excludedFolders.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
        }

        let searchPaths = [
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
        ]

        for basePath in searchPaths {
            guard !ProviderPaths.isProviderOwned(basePath, homeDirectory: URL(fileURLWithPath: home, isDirectory: true)) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: Self.largeFileKeys,
                options: enumerationOptions
            ) else { continue }

            // No entry cap. A 5k cap was here previously and meant any user
            // with hundreds of thousands of small files (e.g. node_modules
            // checkouts) would never see anything past entry 5k — the
            // scattered 100+ MB files were always past that bound.
            for case let fileURL as URL in enumerator {
                if Task.isCancelled { break }
                if ProviderPaths.isProviderOwned(fileURL.path, homeDirectory: URL(fileURLWithPath: home, isDirectory: true)) || FileProtection.isCloudPlaceholder(at: fileURL) {
                    enumerator.skipDescendants()
                    continue
                }
                // Prune excluded subtrees: hitting the excluded directory itself
                // skips its whole contents; for files the call is a harmless no-op.
                // Skip the path normalization entirely when nothing is excluded.
                if !excludedFolders.isEmpty, isExcluded(fileURL.path) {
                    enumerator.skipDescendants()
                    continue
                }
                report(fileURL.path)
                guard let resourceValues = try? fileURL.resourceValues(forKeys: Self.largeFileKeySet),
                      let isFile = resourceValues.isRegularFile, isFile, resourceValues.isSymbolicLink != true,
                      let fileSize = resourceValues.fileSize
                else { continue }

                let size = Int64(fileSize)
                let modDate = resourceValues.contentModificationDate

                if size > minSize || (modDate != nil && modDate! < oldCutoff && size > 10 * 1024 * 1024) {
                    items.append(CleanableItem(
                        name: fileURL.lastPathComponent,
                        path: fileURL.path,
                        size: size,
                        category: .largeFiles,
                        isSelected: false, // Don't auto-select large files
                        lastModified: modDate
                    ))
                }
            }
        }

        items.sort { $0.size > $1.size }
        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .largeFiles, items: items, totalSize: totalSize)
    }

    private func scanXcodeJunk() -> CategoryResult {
        var items: [CleanableItem] = []

        let xcodePaths = [
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/Library/Caches/com.apple.dt.Xcode",
            // Per-OS symbol caches, regenerated on next device connect.
            // These alone are often tens of GB on active dev machines.
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/tvOS DeviceSupport",
            // Simulator clones spun up by xcodebuild test runs
            "\(home)/Library/Developer/XCTestDevices",
            // SwiftUI preview build products
            "\(home)/Library/Developer/Xcode/UserData/Previews",
            // Swift Package Manager download + build caches
            "\(home)/Library/Caches/org.swift.swiftpm",
            "\(home)/Library/org.swift.swiftpm",
        ]

        for path in xcodePaths {
            if fileManager.fileExists(atPath: path) {
                let size = directorySize(path: path)
                if size > 0 {
                    items.append(CleanableItem(
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        size: size,
                        category: .xcodeJunk,
                        isSelected: true,
                        lastModified: nil
                    ))
                }
            }
        }

        // XcodeBuildMCP DerivedData requires explicit user selection.
        // Scheduled cleanup also applies age and lifecycle-lock guards.
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        for discovered in XcodeBuildMCPDerivedDataSupport.discoverDerivedDataDirectories(
            homeDirectory: homeURL,
            fileManager: fileManager
        ) {
            if let item = makeCleanupItem(
                name: discovered.name,
                path: discovered.url.path,
                category: .xcodeJunk,
                isSelected: false
            ) {
                items.append(item)
            }
        }

        // Downloaded simulator runtimes (often multi-GB each). Listed via
        // `xcrun simctl runtime list -j` and deleted via
        // `xcrun simctl runtime delete <id>` — not a plain filesystem unlink,
        // so paths use the simctl-runtime: prefix (see CleaningEngine).
        // Runtime downloads are always opt-in because restoring one requires
        // downloading multiple gigabytes again.
        items.append(contentsOf: scanSimulatorRuntimes())

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .xcodeJunk, items: items, totalSize: totalSize)
    }

    /// Enumerate installed simulator runtime disk images via simctl.
    /// When `xcrun` is missing (no Xcode / CLT), returns an empty list —
    /// Xcode Junk still surfaces DerivedData and the rest of the filesystem
    /// targets; runtime rows are simply omitted.
    private func scanSimulatorRuntimes() -> [CleanableItem] {
        guard SimulatorRuntimeSupport.isXcrunAvailable() else {
            Logger.shared.log(SimulatorRuntimeSupport.missingXcrunMessage, level: .info)
            return []
        }
        guard let runtimes = listSimulatorRuntimes() else { return [] }
        let items = SimulatorRuntimeSupport.makeCleanableItems(from: runtimes)
        for item in items {
            report(item.name)
        }
        return items
    }

    /// Parse `xcrun simctl runtime list -j` into per-image rows.
    private func listSimulatorRuntimes() -> [SimulatorRuntimeSupport.RuntimeInfo]? {
        let result = SimulatorRuntimeSupport.runXcrun(["simctl", "runtime", "list", "-j"])
        guard result.status == 0, !result.stdout.isEmpty else {
            if !result.stderr.isEmpty {
                Logger.shared.log("simctl runtime list failed: \(result.stderr)", level: .warning)
            }
            return nil
        }
        guard let runtimes = SimulatorRuntimeSupport.parseRuntimeListJSON(result.stdout) else {
            Logger.shared.log("simctl runtime list: could not parse JSON", level: .warning)
            return nil
        }
        return runtimes
    }

    private func scanBrewCache() async -> CategoryResult {
        var items: [CleanableItem] = []

        // Default Homebrew download cache
        var brewCachePaths = [
            "\(home)/Library/Caches/Homebrew",
        ]

        // Known-good Homebrew cache roots. Any path returned by `brew --cache`
        // that is NOT inside one of these is refused - prevents an attacker
        // setting HOMEBREW_CACHE=$HOME/Documents from steering our cleanup.
        let knownBrewRoots = [
            "\(home)/Library/Caches/Homebrew",
            "/opt/homebrew/Library/Caches",
            "/usr/local/Homebrew/Library/Caches",
            "/Library/Caches/Homebrew",
        ]

        // Detect custom HOMEBREW_CACHE via `brew --cache`. Strip HOMEBREW_*
        // from the child env so an attacker can't steer the output via
        // launchctl setenv, then validate the output against knownBrewRoots.
        let brewBinPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        var detectedCustomCache = false
        for brewBin in brewBinPaths {
            guard fileManager.fileExists(atPath: brewBin) else { continue }
            var sanitizedEnv = ProcessInfo.processInfo.environment
            for key in Array(sanitizedEnv.keys) where key.hasPrefix("HOMEBREW_") {
                sanitizedEnv.removeValue(forKey: key)
            }
            do {
                let result = try await BrewProcessRunner.run(
                    executableURL: URL(fileURLWithPath: brewBin),
                    arguments: ["--cache"],
                    timeout: 10,
                    environment: sanitizedEnv
                )
                if result.status == 0,
                   let output = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    let normalized = normalizePath(output)
                    let isKnown = knownBrewRoots.contains { root in
                        normalized == root || normalized.hasPrefix(root + "/")
                    }
                    guard isKnown else {
                        Logger.shared.log("Refusing suspicious brew cache path: \(output)", level: .warning)
                        break
                    }
                    if !brewCachePaths.map(normalizePath).contains(normalized) {
                        brewCachePaths.append(output)
                    }
                    detectedCustomCache = true
                }
            } catch is CancellationError {
                return CategoryResult(category: .brewCache, items: items, totalSize: 0)
            } catch {
                Logger.shared.log("Failed to run \(brewBin) --cache: \(error.localizedDescription)", level: .warning)
            }
            break // Only need the first available brew binary
        }

        if !detectedCustomCache {
            Logger.shared.log("Homebrew not found at standard paths; scanning default cache location only", level: .info)
        }

        for path in brewCachePaths {
            if fileManager.fileExists(atPath: path) {
                let size = directorySize(path: path)
                if size > 0 {
                    items.append(CleanableItem(
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        size: size,
                        category: .brewCache,
                        isSelected: true,
                        lastModified: nil
                    ))
                }
            }
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .brewCache, items: items, totalSize: totalSize)
    }

    private func scanNodeCache() async -> CategoryResult {
        struct ManagerCache {
            let name: String
            let manager: NodeCacheManager
            let detectionCommand: (cli: String, args: [String])?
        }

        let managers: [ManagerCache] = [
            ManagerCache(
                name: String(localized: "npm cache"),
                manager: .npm,
                detectionCommand: (cli: "npm", args: ["config", "get", "cache"])
            ),
            ManagerCache(
                name: String(localized: "yarn classic cache"),
                manager: .yarn,
                detectionCommand: (cli: "yarn", args: ["cache", "dir"])
            ),
            // Yarn Berry / v2+ uses a per-project .yarn/cache. We don't try to
            // chase those — they're inside user projects and shouldn't be
            // touched by a system cleaner. The classic cache above remains the
            // global, safe-to-clean location.
            ManagerCache(
                name: String(localized: "pnpm content-addressable store"),
                manager: .pnpm,
                detectionCommand: (cli: "pnpm", args: ["store", "path"])
            ),
        ]

        var items: [CleanableItem] = []

        // Common $PATH locations on macOS where these CLIs land.
        let cliSearchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.volta/bin",
            "\(home)/.nvm/versions/node",
        ]

        for manager in managers {
            if Task.isCancelled { break }
            var paths = Self.approvedNodeCacheRoots(for: manager.manager, home: home)
                .compactMap {
                    Self.validatedNodeCachePath($0, manager: manager.manager, home: home)
                }

            if let cmd = manager.detectionCommand,
               let cliPath = locateExecutable(named: cmd.cli, searchPaths: cliSearchPaths),
               let detected = await runCommandReadingStdout(executable: cliPath, args: cmd.args) {
                if let validated = Self.validatedNodeCachePath(
                    detected,
                    manager: manager.manager,
                    home: home
                ) {
                    if !paths.contains(validated) {
                        paths.append(validated)
                    }
                } else {
                    Logger.shared.log(
                        "Refusing untrusted \(manager.manager.rawValue) cache path",
                        level: .warning
                    )
                }
            }

            if Task.isCancelled { break }
            paths = Self.prunedNodeCachePaths(paths)

            for path in paths {
                guard fileManager.fileExists(atPath: path) else { continue }
                let size = directorySize(path: path)
                guard size > 0 else { continue }
                items.append(CleanableItem(
                    name: manager.name,
                    path: path,
                    size: size,
                    category: .nodeCache,
                    isSelected: true,
                    lastModified: nil
                ))
            }
        }

        let toolCaches: [(String, String)] = [
            ("Puppeteer", ".cache/puppeteer"),
            ("Playwright", ".cache/ms-playwright"),
            ("Playwright", "Library/Caches/ms-playwright"),
            ("node-gyp", ".cache/node-gyp"),
            ("node-gyp", "Library/Caches/node-gyp"),
            ("Electron", "Library/Caches/electron"),
            ("Electron Builder", "Library/Caches/electron-builder"),
        ]
        items.append(contentsOf: toolCaches.compactMap { name, relativePath in
            makeCleanupItem(name: name, path: "\(home)/\(relativePath)", category: .nodeCache)
        })
        let unique = deduplicatedItems(items)
        return CategoryResult(category: .nodeCache, items: unique, totalSize: unique.reduce(0) { $0 + $1.size })
    }

    nonisolated static func approvedNodeCacheRoots(
        for manager: NodeCacheManager,
        home: String
    ) -> [String] {
        let normalizedHome = (home as NSString).standardizingPath
        switch manager {
        case .npm:
            return [
                "\(normalizedHome)/.npm",
                "\(normalizedHome)/Library/Caches/npm",
            ]
        case .yarn:
            return [
                "\(normalizedHome)/Library/Caches/Yarn",
                "\(normalizedHome)/.cache/yarn",
            ]
        case .pnpm:
            return [
                "\(normalizedHome)/Library/pnpm/store",
                "\(normalizedHome)/.local/share/pnpm/store",
                "\(normalizedHome)/.pnpm-store",
                "\(normalizedHome)/.cache/pnpm",
            ]
        }
    }

    nonisolated static func validatedNodeCachePath(
        _ candidate: String,
        manager: NodeCacheManager,
        home: String
    ) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.hasPrefix("/"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }

        let standardized = (trimmed as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: standardized, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let approvedRoots = approvedNodeCacheRoots(for: manager, home: home)
            .map { ($0 as NSString).standardizingPath }

        guard approvedRoots.contains(where: { root in
            resolved == root || resolved.hasPrefix(root + "/")
        }) else { return nil }

        return resolved
    }

    nonisolated static func prunedNodeCachePaths(_ paths: [String]) -> [String] {
        var kept: [String] = []
        for path in paths.sorted(by: {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }) {
            if kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                continue
            }
            kept.append(path)
        }
        return kept
    }

    // -- Process helpers (used by scanNodeCache) --

    private func locateExecutable(named name: String, searchPaths: [String]) -> String? {
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
            // For nvm: ~/.nvm/versions/node/<version>/bin/<name>
            if dir.hasSuffix("/.nvm/versions/node"),
               let versions = try? fileManager.contentsOfDirectory(atPath: dir) {
                for v in versions {
                    let nested = (dir as NSString).appendingPathComponent("\(v)/bin/\(name)")
                    if fileManager.isExecutableFile(atPath: nested) {
                        return nested
                    }
                }
            }
        }
        return nil
    }

    private func runCommandReadingStdout(executable: String, args: [String]) async -> String? {
        do {
            let result = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: executable),
                arguments: args,
                timeout: 10
            )
            guard result.status == 0 else { return nil }
            return String(data: result.stdout, encoding: .utf8)
        } catch is CancellationError {
            return nil
        } catch {
            Logger.shared.log("\(executable) \(args.joined(separator: " ")) failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    private func scanDockerCache() async -> CategoryResult {
        var items: [CleanableItem] = []

        // Docker Desktop on macOS keeps its VM disk + caches under
        // ~/Library/Containers/com.docker.docker/Data. The caches we
        // surface here are *recoverable* — they will be regenerated by
        // Docker on next pull/build, and `docker system prune` is the
        // CLI equivalent of cleaning them.
        let dockerDataDirs = [
            // Build cache (BuildKit), per-user
            "\(home)/Library/Containers/com.docker.docker/Data/cache",
            // Vmnetd / vpnkit log + telemetry caches
            "\(home)/Library/Containers/com.docker.docker/Data/log",
            "\(home)/Library/Containers/com.docker.docker/Data/tmp",
            // Group containers caches (Docker Desktop helper apps)
            "\(home)/Library/Group Containers/group.com.docker/Caches",
            // CLI plugin download cache
            "\(home)/.docker/cli-plugins/.cache",
            // Buildx / containerd inline cache
            "\(home)/.docker/buildx/cache",
            // OrbStack (Docker Desktop alternative) keeps its daemon logs and
            // caches outside ~/Library/Containers. The VM data disk itself
            // (~/.orbstack/data) is intentionally NOT listed — image/container
            // space inside the VM is only reclaimable via `docker system
            // prune`, surfaced as the virtual entry below.
            "\(home)/.orbstack/log",
            "\(home)/Library/Caches/dev.kdrag0n.MacVirt",
            "\(home)/Library/Logs/OrbStack",
        ]

        for path in dockerDataDirs {
            guard fileManager.fileExists(atPath: path) else { continue }
            let size = directorySize(path: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                size: size,
                category: .dockerCache,
                isSelected: true,
                lastModified: nil
            ))
        }

        // If the `docker` CLI is available and the daemon answers, surface
        // reclaimable space reported by `docker system df` as a single
        // virtual entry. Cleaning it runs `docker system prune -f` (see
        // CleaningEngine.pruneDockerSystem) — stopped containers, dangling
        // images, unused networks, and build cache; running containers and
        // tagged images are untouched. The empty path mirrors the purgeable-
        // space convention: this is an action, not a file unlink, so the UI
        // must not offer reveal-in-Finder or attempt removeItem on it.
        // Works for both Docker Desktop and OrbStack (both ship a docker CLI
        // at these locations).
        let dockerBinPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        for dockerBin in dockerBinPaths where fileManager.fileExists(atPath: dockerBin) {
            if Task.isCancelled { break }
            if let reclaimable = await reclaimableDockerSpace(dockerBin: dockerBin), reclaimable > 0 {
                items.append(CleanableItem(
                    name: String(localized: "Docker prune (stopped containers, dangling images, build cache)"),
                    path: CleanableItem.dockerPrunePath,
                    size: reclaimable,
                    category: .dockerCache,
                    isSelected: false,
                    lastModified: nil
                ))
            }
            break
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .dockerCache, items: items, totalSize: totalSize)
    }

    /// Sum the reclaimable bytes reported by `docker system df --format json`.
    /// Returns nil when Docker isn't running or the command fails — callers
    /// should treat that as "no reclaimable info available", not as an error.
    private func reclaimableDockerSpace(dockerBin: String) async -> Int64? {
        let result: BrewProcessOutput
        do {
            result = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: dockerBin),
                arguments: ["system", "df", "--format", "{{.Reclaimable}}"],
                timeout: 10
            )
        } catch is CancellationError {
            return nil
        } catch {
            Logger.shared.log("docker system df failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
        guard result.status == 0,
              let output = String(data: result.stdout, encoding: .utf8)
        else { return nil }
        // Each line looks like e.g. "1.234GB (45%)" — parse the leading number.
        var total: Int64 = 0
        for line in output.split(separator: "\n") {
            let raw = line.split(separator: " ").first.map(String.init) ?? ""
            if let bytes = parseHumanBytes(raw) {
                total += bytes
            }
        }
        return total
    }

    /// Parse Docker's compact size format ("1.23GB", "456MB", "789kB") into bytes.
    private func parseHumanBytes(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("kB", 1_000),
            ("KB", 1_000),
            ("B", 1),
        ]
        for (suffix, multiplier) in units {
            if trimmed.hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(suffix.count))
                if let value = Double(numberPart) {
                    return Int64(value * multiplier)
                }
            }
        }
        return nil
    }
    // MARK: - Helpers

    private func scanDirectory(
        path: String,
        category: CleaningCategory,
        isSelected: Bool = true,
        excluding excludedPaths: Set<String> = []
    ) -> [CleanableItem] {
        var items: [CleanableItem] = []

        guard fileManager.fileExists(atPath: path),
              fileManager.isReadableFile(atPath: path) else { return [] }

        do {
            // One listing with prefetched attributes replaces the previous
            // per-entry fileExists + attributesOfItem(x2) + fileModDate chain
            // (3-4 stat-class syscalls per entry down to the single prefetch).
            let contents = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: Self.scanEntryKeys,
                options: []
            )
            for entryURL in contents {
                if Task.isCancelled { break }
                let fullPath = entryURL.path
                report(fullPath)
                if ProviderPaths.isProviderOwned(fullPath, homeDirectory: URL(fileURLWithPath: home, isDirectory: true)) || excludedPaths.contains(normalizePath(fullPath)) {
                    continue
                }

                guard let values = try? entryURL.resourceValues(forKeys: Self.scanEntryKeySet) else {
                    continue
                }
                // Security: skip symlinks to prevent symlink-following attacks
                if values.isSymbolicLink ?? false { continue }

                let name = entryURL.lastPathComponent
                if FileProtection.isProtectedFromDeletion(path: fullPath) { continue }
                if values.isDirectory ?? false {
                    let size = directorySize(path: fullPath)
                    if size > 1024 { // Skip tiny entries
                        items.append(CleanableItem(
                            name: name,
                            path: fullPath,
                            size: size,
                            category: category,
                            isSelected: isSelected,
                            lastModified: values.contentModificationDate
                        ))
                    }
                } else {
                    let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize
                    if let size, size > 1024 {
                        items.append(CleanableItem(
                            name: name,
                            path: fullPath,
                            size: Int64(size),
                            category: category,
                            isSelected: isSelected,
                            lastModified: values.contentModificationDate
                        ))
                    }
                }
            }
        } catch {
            Logger.shared.log("Cannot enumerate \(path): \(error.localizedDescription)", level: .warning)
        }

        return items
    }

    /// Prefetch keys for scanDirectory — declared once so neither the array
    /// nor the Set is rebuilt per directory or per entry.
    private static let scanEntryKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey,
    ]
    private static let scanEntryKeySet = Set(scanEntryKeys)

    private static let largeFileKeys: [URLResourceKey] = [
        .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]
    private static let largeFileKeySet = Set(largeFileKeys)

    private func makeCleanupItem(
        name: String,
        path: String,
        category: CleaningCategory,
        isSelected: Bool = true,
        minimumSize: Int64 = 1024
    ) -> CleanableItem? {
        report(path)
        guard !ProviderPaths.isProviderOwned(path, homeDirectory: URL(fileURLWithPath: home, isDirectory: true)),
              !FileProtection.isProtectedFromDeletion(path: path),
              (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              fileManager.isReadableFile(atPath: path) else { return nil }

        if isDirectory.boolValue {
            let size = directorySize(path: path)
            guard size > minimumSize else { return nil }
            return CleanableItem(
                name: name,
                path: path,
                size: size,
                category: category,
                isSelected: isSelected,
                lastModified: fileModDate(path: path)
            )
        }

        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              size > minimumSize else { return nil }

        return CleanableItem(
            name: name,
            path: path,
            size: size,
            category: category,
            isSelected: isSelected,
            lastModified: attrs[.modificationDate] as? Date
        )
    }

    private func deduplicatedItems(_ items: [CleanableItem]) -> [CleanableItem] {
        var seenPaths: Set<String> = []
        var uniqueItems: [CleanableItem] = []

        for item in items {
            let normalizedPath = normalizePath(item.path)
            if seenPaths.insert(normalizedPath).inserted {
                uniqueItems.append(item)
            }
        }

        return uniqueItems
    }

    private func normalizePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func directorySize(path: String) -> Int64 {
        var totalSize: Int64 = 0
        var count = 0

        // errorHandler returns true so unreadable entries are skipped
        // instead of aborting the walk partway through the tree.
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: Self.directorySizeKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        // No entry cap. A 10k cap was here previously and made huge trees
        // like Xcode DerivedData (millions of files) report a fraction of
        // their real size. report() is throttled, so display stays cheap.
        // A DerivedData/DeviceSupport walk can hold this loop for minutes,
        // so honor task cancellation to let an aborted scan stop promptly.
        for case let fileURL as URL in enumerator {
            count += 1
            if count.isMultiple(of: 256),
               withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
                break
            }

            report(fileURL.path)
            // Same key set as the enumerator prefetch, resolved from the URL
            // cache; the static Set avoids a per-file allocation.
            guard let values = try? fileURL.resourceValues(forKeys: Self.directorySizeKeySet),
                  let isFile = values.isRegularFile, isFile, values.isSymbolicLink != true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            totalSize += Int64(size)
        }

        return totalSize
    }

    private static let directorySizeKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]
    private static let directorySizeKeySet = Set(directorySizeKeys)

    private func fileModDate(path: String) -> Date? {
        try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

}
