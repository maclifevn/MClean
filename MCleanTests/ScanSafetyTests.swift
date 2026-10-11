import Foundation
import XCTest
@testable import MClean

final class ScanSafetyTests: XCTestCase {
    func testHuggingFaceDownloadsStayUnselectedAndDoNotIncludeCredentials() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MClean-HF-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let hub = home.appendingPathComponent(".cache/huggingface/hub")
        let token = home.appendingPathComponent(".cache/huggingface/token")
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: hub.appendingPathComponent("download.bin"))
        try Data("credential-fixture".utf8).write(to: token)
        let result = await ScanEngine(homeDirectory: home).scanCategory(.aiApps)
        let item = try XCTUnwrap(result.items.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == hub.resolvingSymlinksInPath() })
        XCTAssertFalse(item.isSelected)
        XCTAssertFalse(result.items.contains { $0.path == token.path || $0.path == token.deletingLastPathComponent().path })
    }
    func testUninstallProtectsStructuralRootsAndCredentialTrees() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home, home + "/Library", home + "/Library/Application Support",
                     "/Applications", "/Library/LaunchAgents", home + "/.ssh/id_ed25519", "/System/Library"] {
            XCTAssertTrue(FileProtection.isProtectedUninstallPath(URL(fileURLWithPath: path)))
        }
        XCTAssertFalse(FileProtection.isProtectedUninstallPath(URL(fileURLWithPath: home + "/Library/Caches/com.example.app")))
        XCTAssertFalse(FileProtection.isProtectedUninstallPath(URL(fileURLWithPath: "/Applications/ThirdParty.app")))
    }

    func testCloudProviderPolicyProtectsStateWithoutBlockingSiblingNames() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let engine = CleaningEngine()
        for root in ProviderPaths.deniedRoots() {
            XCTAssertTrue(ProviderPaths.isProviderOwned(root))
            XCTAssertTrue(ProviderPaths.isProviderOwned(root + "/database"))
            let deletable = await engine.isSafeToDelete(resolvedPath: root + "/database")
            let protected = await engine.isProtectedFromTrashing(resolvedPath: root)
            XCTAssertFalse(deletable)
            XCTAssertTrue(protected)
            XCTAssertFalse(OrphanSafetyPolicy.isSafeCandidate(URL(fileURLWithPath: root)))
        }
        XCTAssertFalse(ProviderPaths.isProviderOwned(home + "/Library/Caches/com.apple.birdwatcher/cache"))
    }

    func testUserCacheScanExcludesCloudStateAndDeduplicatesPip() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MClean-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let cloud = home.appendingPathComponent("Library/Caches/CloudKit")
        let pip = home.appendingPathComponent("Library/Caches/pip")
        for directory in [cloud, pip] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: directory.appendingPathComponent("cache.bin"))
        }
        let result = await ScanEngine(homeDirectory: home).scanCategory(.userCache)
        XCTAssertFalse(result.items.contains { $0.path == cloud.path })
        XCTAssertEqual(result.items.filter { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == pip.resolvingSymlinksInPath() }.count, 1, "Paths: \(result.items.map(\.path))")
        XCTAssertEqual(result.totalSize, result.items.reduce(0) { $0 + $1.size })
    }

    func testLargeFilesCannotFollowSymlinksOrEnterPackages() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MClean-large-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads")
        let package = downloads.appendingPathComponent("Library.photoslibrary")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: 200 * 1024 * 1024)
        try handle.close()
        try FileManager.default.copyItem(at: target, to: package.appendingPathComponent("original.bin"))
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("linked.bin"), withDestinationURL: target)
        let result = await ScanEngine(homeDirectory: home).scanCategory(.largeFiles)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testTrashCategoryCannotPermanentlyDeleteCacheFile() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MClean-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("retained.bin")
        try Data(repeating: 1, count: 4096).write(to: file)
        let item = CleanableItem(name: file.lastPathComponent, path: file.path, size: 4096,
            category: .trashBins, isSelected: true, lastModified: nil)
        let result = await CleaningEngine().cleanItems([item]) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testCommandRunnerDrainsBothVerbosePipesAndBoundsInheritedPipeLifetime() throws {
        let verbose = try CommandRunner.run(executable: "/bin/sh", arguments: ["-c", "yes out | head -c 200000; yes err | head -c 200000 >&2"], timeout: 3)
        XCTAssertTrue(verbose.succeeded)
        XCTAssertEqual(verbose.stdout.count, 200000)
        XCTAssertEqual(verbose.stderr.count, 200000)
        let started = Date()
        let inherited = try CommandRunner.run(executable: "/bin/sh", arguments: ["-c", "sleep 2 & printf done"], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(inherited.stdoutString, "done")
    }
}
