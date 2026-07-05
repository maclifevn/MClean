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

final class AppInfoFetcher {
    static let shared = AppInfoFetcher()
    private let fileManager = FileManager.default

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
        var apps: [InstalledApp] = []
        var seenBundleIDs: Set<String> = []

        // `/Users/Shared` is where game launchers (Riot Client, some Blizzard
        // and Epic helpers) drop their `.app` bundles instead of /Applications,
        // so it has to be scanned for those to show up in the uninstaller
        // (issue #123). It can also hold multi-gigabyte game data trees, so it
        // is depth-bounded — the launcher bundles live within the first few
        // levels (e.g. /Users/Shared/Riot Games/Riot Client.app at depth 2);
        // the bound is kept generous (6) so a vendor that nests one or two
        // directories deeper is still found, while the multi-gigabyte asset
        // trees below that are not walked.
        let searchRoots: [(path: String, maxDepth: Int)] = [
            ("/Applications", 8),
            ("\(home)/Applications", 8),
            ("/System/Applications", 8),
            ("/Users/Shared", 6),
        ]

        for (searchPath, maxDepth) in searchRoots {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: searchPath),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else {
                    // Stop descending once past the depth bound so a deep data
                    // tree (e.g. a game's assets) doesn't get fully walked.
                    if enumerator.level >= maxDepth {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // Skip subdirectories inside .app bundles
                enumerator.skipDescendants()

                // Skip system/protected apps
                if url.path.hasPrefix("/System") { continue }

                guard let app = loadAppInfo(from: url),
                      !seenBundleIDs.contains(app.bundleIdentifier),
                      !Self.protectedBundleIDs.contains(app.bundleIdentifier) else { continue }

                seenBundleIDs.insert(app.bundleIdentifier)
                apps.append(app)
            }
        }

        return apps.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    /// Build an `InstalledApp` from a single bundle URL. Used by the Finder
    /// Services handler ("Uninstall with MClean") to resolve a right-clicked
    /// .app into the uninstaller without re-scanning every app. Enforces the
    /// same protections as the full scan: no /System apps, and no protected
    /// Apple bundle IDs (Safari, Mail, Xcode, App Store, …) — so a right-click
    /// can never route a system app into the uninstaller.
    func fetchApp(at url: URL) -> InstalledApp? {
        guard url.pathExtension == "app", !url.path.hasPrefix("/System") else { return nil }
        guard let app = loadAppInfo(from: url),
              !Self.protectedBundleIDs.contains(app.bundleIdentifier) else { return nil }
        return app
    }

    private func loadAppInfo(from url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url) else { return nil }

        let bundleID = bundle.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)

        let size = appSize(at: url)

        return InstalledApp(
            id: UUID(),
            appName: appName,
            bundleIdentifier: bundleID,
            path: url,
            icon: icon,
            size: size
        )
    }

    private func appSize(at url: URL) -> Int64 {
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

        let cache = UserDefaults.standard.dictionary(forKey: Self.sizeCacheKey) as? [String: [String: Double]] ?? [:]
        if let entry = cache[url.path],
           entry["mtime"] == modDate,
           let cached = entry["size"] {
            return Int64(cached)
        }

        let size = FileSizeCalculator.size(of: url) ?? 0

        var updated = cache
        updated[url.path] = ["mtime": modDate, "size": Double(size)]
        // Drop entries for apps that no longer exist so the cache can't grow
        // without bound across years of installs/uninstalls.
        if updated.count > 400 {
            updated = updated.filter { FileManager.default.fileExists(atPath: $0.key) }
        }
        UserDefaults.standard.set(updated, forKey: Self.sizeCacheKey)
        return size
    }

    private static let sizeCacheKey = "MClean.AppSizeCache.v1"
}
