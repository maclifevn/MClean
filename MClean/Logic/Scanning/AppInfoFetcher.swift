import Foundation
import AppKit

struct InstalledApp: Identifiable, Hashable {
    let id: UUID
    let appName: String
    let bundleIdentifier: String
    let path: URL
    let icon: NSImage
    let size: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.id == rhs.id
    }
}

/// Lightweight identity used by Orphan Finder. It deliberately carries no
/// icon or recursive bundle size, avoiding a full walk of every installed app
/// when all the caller needs is an ownership index.
struct InstalledAppIdentity {
    let appName: String
    let bundleIdentifier: String
}

final class AppInfoFetcher {
    static let shared = AppInfoFetcher()
    private let fileManager = FileManager.default
    private let fetchLock = NSLock()
    private typealias SizeCache = [String: [String: Double]]

    private static let protectedBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.finder", "com.apple.AppStore",
        "com.apple.systempreferences", "com.apple.Terminal",
        "com.apple.ActivityMonitor", "com.apple.dt.Xcode",
        "com.apple.mail", "com.apple.iCal", "com.apple.AddressBook",
        "com.apple.Preview", "com.apple.TextEdit", "com.apple.calculator",
        "com.apple.MobileSMS", "com.apple.FaceTime", "com.apple.Music",
        "com.apple.TV", "com.apple.Podcasts", "com.apple.News",
        "com.apple.Maps", "com.apple.Photos", "com.apple.Notes",
        "com.apple.reminders", "com.apple.Stocks", "com.apple.Home",
        "com.apple.weather", "com.apple.clock", "com.apple.Passwords",
    ]

    private init() {}

    func fetchInstalledApps() -> [InstalledApp] {
        fetchLock.lock()
        defer { fetchLock.unlock() }

        var apps: [InstalledApp] = []
        var seenBundleIDs: Set<String> = []
        var sizeCache = loadSizeCache()

        for url in discoveredAppURLs() {
            guard let app = loadAppInfo(from: url, sizeCache: &sizeCache),
                  !seenBundleIDs.contains(app.bundleIdentifier),
                  !Self.protectedBundleIDs.contains(app.bundleIdentifier) else { continue }

            seenBundleIDs.insert(app.bundleIdentifier)
            apps.append(app)
        }

        pruneAndSaveSizeCache(&sizeCache)

        return apps.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    func fetchInstalledAppIdentities() -> [InstalledAppIdentity] {
        fetchLock.lock()
        defer { fetchLock.unlock() }

        var identities: [InstalledAppIdentity] = []
        var seenBundleIDs: Set<String> = []
        for url in discoveredAppURLs() {
            guard let identity = loadIdentity(from: url),
                  !seenBundleIDs.contains(identity.bundleIdentifier),
                  !Self.protectedBundleIDs.contains(identity.bundleIdentifier) else { continue }
            seenBundleIDs.insert(identity.bundleIdentifier)
            identities.append(identity)
        }
        return identities
    }

    /// Build an `InstalledApp` from a single bundle URL. Used by the Finder
    /// Services handler ("Uninstall with MClean") to resolve a right-clicked
    /// .app into the uninstaller without re-scanning every app. Enforces the
    /// same protections as the full scan: no /System apps, and no protected
    /// Apple bundle IDs (Safari, Mail, Xcode, App Store, …) — so a right-click
    /// can never route a system app into the uninstaller.
    func fetchApp(at url: URL) -> InstalledApp? {
        fetchLock.lock()
        defer { fetchLock.unlock() }
        guard url.pathExtension == "app", !url.path.hasPrefix("/System") else { return nil }
        var sizeCache = loadSizeCache()
        guard let app = loadAppInfo(from: url, sizeCache: &sizeCache),
              !Self.protectedBundleIDs.contains(app.bundleIdentifier) else { return nil }
        pruneAndSaveSizeCache(&sizeCache)
        return app
    }

    private func discoveredAppURLs() -> [URL] {
        // `/Users/Shared` can hold game launchers alongside enormous asset
        // trees, so every root is depth-bounded. System apps are intentionally
        // omitted instead of enumerated and discarded afterward.
        let searchRoots: [(path: String, maxDepth: Int)] = [
            ("/Applications", 8),
            ("\(home)/Applications", 8),
            ("/Users/Shared", 6),
        ]
        var urls: [URL] = []
        for (searchPath, maxDepth) in searchRoots {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: searchPath),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else {
                    if enumerator.level >= maxDepth { enumerator.skipDescendants() }
                    continue
                }
                enumerator.skipDescendants()
                urls.append(url)
            }
        }
        return urls
    }

    private func loadIdentity(from url: URL) -> InstalledAppIdentity? {
        guard let bundle = Bundle(url: url) else { return nil }

        let bundleID = bundle.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledAppIdentity(appName: appName, bundleIdentifier: bundleID)
    }

    private func loadAppInfo(from url: URL, sizeCache: inout SizeCache) -> InstalledApp? {
        guard let identity = loadIdentity(from: url) else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)

        let size = appSize(at: url, cache: &sizeCache)

        return InstalledApp(
            id: UUID(),
            appName: identity.appName,
            bundleIdentifier: identity.bundleIdentifier,
            path: url,
            icon: icon,
            size: size
        )
    }

    private func appSize(at url: URL, cache: inout SizeCache) -> Int64 {
        // Sizing a bundle means enumerating every file inside it. That is
        // brutal for huge apps — Xcode.app alone is hundreds of thousands of
        // files — and this runs for EVERY app on EVERY launch, hammering the
        // disk for minutes and starving any scan the user starts meanwhile
        // (field report: Smart Scan "stuck for 3+ minutes" right after
        // launch, on a machine where the scan itself benches in seconds).
        //
        // Cache the size keyed by the bundle's root modification date: app
        // updates replace the bundle and bump that date, invalidating the
        // entry; unchanged apps cost two stat calls instead of a full walk.
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0

        if let entry = cache[url.path],
           entry["mtime"] == modDate,
           let cached = entry["size"] {
            return Int64(cached)
        }

        let size = FileSizeCalculator.size(of: url) ?? 0

        cache[url.path] = ["mtime": modDate, "size": Double(size)]
        return size
    }

    private func loadSizeCache() -> SizeCache {
        UserDefaults.standard.dictionary(forKey: Self.sizeCacheKey) as? SizeCache ?? [:]
    }

    private func pruneAndSaveSizeCache(_ cache: inout SizeCache) {
        if cache.count > 400 {
            cache = cache.filter { fileManager.fileExists(atPath: $0.key) }
        }
        UserDefaults.standard.set(cache, forKey: Self.sizeCacheKey)
    }

    private static let sizeCacheKey = "MClean.AppSizeCache.v1"
}
