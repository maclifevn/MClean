import AppKit
import XCTest
@testable import MClean

@MainActor
final class AppStateTests: XCTestCase {
    func testPermissionRetryCooldownCannotOverwriteAStartedScan() async throws {
        let state = AppState(performStartupTasks: false)
        let item = CleanableItem(name: "Protected root", path: "/", size: 4096,
                                 category: .userCache, isSelected: true, lastModified: nil)
        let retry = Task { await state.retryCleanItems([item]) }
        for _ in 0..<100 {
            if case .cleaned = state.scanState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .cleaned = state.scanState else { return XCTFail("Retry did not complete") }
        state.scanState = .scanning(progress: 0, currentCategory: "New scan")
        await retry.value
        guard case .scanning = state.scanState else { return XCTFail("Old retry overwrote the newer scan") }
    }

    func testPermissionRetryCannotInterruptAnActiveScan() async {
        let state = AppState(performStartupTasks: false)
        state.scanState = .scanning(progress: 0.5, currentCategory: "Current scan")
        let item = CleanableItem(name: "Protected root", path: "/", size: 4096,
                                 category: .userCache, isSelected: true, lastModified: nil)
        await state.retryCleanItems([item])
        guard case .scanning = state.scanState else { return XCTFail("Retry interrupted scan") }
        XCTAssertEqual(state.pendingPermissionRetryItems.map(\.id), [item.id])
        XCTAssertNotNil(state.cleanError)
    }

    func testRejectedCleanupReportsFailuresAndRetainsReviewItems() async throws {
        let state = AppState(performStartupTasks: false)
        let item = CleanableItem(name: "Protected root", path: "/", size: 4096,
                                 category: .userCache, isSelected: true, lastModified: nil)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [item], totalSize: item.size)
        state.cleanCategory(.userCache)
        for _ in 0..<100 {
            if case .cleaned = state.scanState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(state.lastCleanupHadFailures)
        XCTAssertNotNil(state.cleanError)
        XCTAssertEqual(state.categoryResults[.userCache]?.items.map(\.id), [item.id])
        XCTAssertEqual(state.totalProcessedSpace, 0)
    }

    func testStaleMissingCleanupItemClearsErrorWithoutClaimingFreedSpace() async throws {
        let state = AppState(performStartupTasks: false)
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MClean-missing-\(UUID())").path
        let item = CleanableItem(name: "Missing cache", path: path, size: 4096,
                                 category: .userCache, isSelected: true, lastModified: nil)
        state.cleanError = "Previous failure"
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [item], totalSize: item.size)
        state.cleanCategory(.userCache)
        for _ in 0..<100 {
            if case .cleaned = state.scanState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.lastCleanupHadFailures)
        XCTAssertNil(state.cleanError)
        XCTAssertNil(state.categoryResults[.userCache])
        XCTAssertEqual(state.totalProcessedSpace, 0)
    }
    func testScanForAppFilesTracksLocationsWhileResultsArePending() throws {
        var completion: ((Set<URL>) -> Void)?
        let expectedLocations = ["/one", "/two", "/three"]
        let appState = AppState(
            performStartupTasks: false,
            locationsProvider: {
                StubLocations(paths: expectedLocations)
            },
            appFileScanner: { _, locations, pendingCompletion in
                XCTAssertEqual(locations.appSearch.paths, expectedLocations)
                completion = pendingCompletion
                return nil
            }
        )

        appState.scanForAppFiles(makeApp())

        XCTAssertTrue(appState.isScanningAppFiles)
        XCTAssertTrue(appState.discoveredFiles.isEmpty)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, expectedLocations.count)

        let pendingCompletion = try XCTUnwrap(completion)
        let urls: Set<URL> = [
            URL(fileURLWithPath: "/tmp/B"),
            URL(fileURLWithPath: "/tmp/A")
        ]

        pendingCompletion(urls)

        XCTAssertFalse(appState.isScanningAppFiles)
        XCTAssertEqual(
            appState.discoveredFiles,
            urls.sorted { $0.path < $1.path }
        )
        XCTAssertEqual(appState.selectedFiles, urls)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, urls.count)
    }

    func testOlderAppFileScanCannotReplaceNewerSelection() throws {
        var completions: [String: (Set<URL>) -> Void] = [:]
        var cancelledApps: [String] = []
        let appState = AppState(
            performStartupTasks: false,
            locationsProvider: { StubLocations(paths: ["/one"]) },
            appFileScanner: { app, _, completion in
                completions[app.appName] = completion
                return { cancelledApps.append(app.appName) }
            }
        )
        let firstApp = makeApp(name: "First", path: "/Applications/First.app")
        let secondApp = makeApp(name: "Second", path: "/Applications/Second.app")
        let firstResult = Set([URL(fileURLWithPath: "/tmp/first-cache")])
        let secondResult = Set([URL(fileURLWithPath: "/tmp/second-cache")])

        appState.scanForAppFiles(firstApp)
        appState.scanForAppFiles(secondApp)
        XCTAssertEqual(cancelledApps, ["First"])

        try XCTUnwrap(completions["Second"])(secondResult)
        XCTAssertEqual(appState.discoveredFiles, Array(secondResult))
        XCTAssertEqual(appState.selectedFiles, secondResult)
        XCTAssertFalse(appState.isScanningAppFiles)

        try XCTUnwrap(completions["First"])(firstResult)
        XCTAssertEqual(appState.discoveredFiles, Array(secondResult))
        XCTAssertEqual(appState.selectedFiles, secondResult)
        XCTAssertFalse(appState.isScanningAppFiles)
    }

    func testCommandRunnerTimeoutStopsChildAfterParentExits() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MClean-command-child-\(UUID()).pid")
        var child: Int32 = 0
        defer {
            if child > 0 { Darwin.kill(child, SIGKILL) }
            try? FileManager.default.removeItem(at: file)
        }
        let output = try CommandRunner.run(executable: "/bin/sh",
            arguments: ["-c", "/bin/sh -c 'trap \"\" TERM; echo $$ > \"$1\"; exec /bin/sleep 120' child \"$1\" >/dev/null 2>&1 & wait", "mclean-fixture", file.path], timeout: 0.2)
        XCTAssertTrue(output.timedOut)
        child = try XCTUnwrap(Int32(String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<50 {
            if Darwin.kill(child, 0) != 0 { break }
            usleep(10_000)
        }
        XCTAssertEqual(Darwin.kill(child, 0), -1)
    }

    func testCommandRunnerTerminatesTimedOutProcess() throws {
        let started = Date()
        let result = try CommandRunner.run(
            executable: "/bin/sleep",
            arguments: ["2"],
            timeout: 0.05
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testOrphanSafetyPolicyAllowsOnlyVolatileChildren() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(OrphanSafetyPolicy.isSafeCandidate(
            URL(fileURLWithPath: "\(home)/Library/Caches/com.example.app")
        ))
        XCTAssertFalse(OrphanSafetyPolicy.isSafeCandidate(
            URL(fileURLWithPath: "\(home)/Library/Caches")
        ))
        XCTAssertFalse(OrphanSafetyPolicy.isSafeCandidate(
            URL(fileURLWithPath: "\(home)/Library/Preferences/com.example.app.plist")
        ))
        XCTAssertFalse(OrphanSafetyPolicy.isSafeCandidate(
            URL(fileURLWithPath: "\(home)/.ssh/id_ed25519")
        ))
        XCTAssertTrue(OrphanSafetyPolicy.shouldScanDirectory(
            URL(fileURLWithPath: "\(home)/Library/Caches")
        ))
        XCTAssertFalse(OrphanSafetyPolicy.shouldScanDirectory(
            URL(fileURLWithPath: "\(home)/Library/Preferences")
        ))
    }

    func testCleanupPolicyAcceptsEveryDedicatedScannerRoot() async {
        let engine = CleaningEngine()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expectedSafePaths = [
            "\(home)/Library/Caches/com.example/cache.db",
            "\(home)/Library/Logs/com.example/app.log",
            "\(home)/Library/Mail Downloads/attachment.dat",
            "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/attachment.dat",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/.ollama/logs/server.log",
            "\(home)/.ollama/history",
            "\(home)/Library/WebKit/com.electron.ollama",
            "\(home)/Library/Saved Application State/com.electron.ollama.savedState",
            "\(home)/.lmstudio/server-logs/server.log",
            "\(home)/.lmstudio/conversations/session.json",
            "\(home)/Library/pnpm/store/v3/index",
            "\(home)/Library/Containers/com.docker.docker/Data/cache",
            "\(home)/Library/Group Containers/group.com.docker/Caches",
            "\(home)/.docker/cli-plugins/.cache/plugin",
            "\(home)/.docker/buildx/cache/item",
            "/Library/Caches/com.example/item",
            "/private/var/log/example.log",
            "/tmp/example.tmp",
            "/opt/homebrew/Library/Caches/Homebrew/downloads/item",
            "/usr/local/Homebrew/Library/Caches/Homebrew/downloads/item",
        ]

        for path in expectedSafePaths {
            let accepted = await engine.isSafeToDelete(resolvedPath: path)
            XCTAssertTrue(accepted, "Expected cleanup policy to accept \(path)")
        }
        let broadRoot = await engine.isSafeToDelete(
            resolvedPath: "\(home)/Library/Application Support"
        )
        XCTAssertFalse(broadRoot)
        let unsafeDotfile = await engine.isSafeToDelete(resolvedPath: "\(home)/.ssh/id_ed25519")
        XCTAssertFalse(unsafeDotfile)

        let systemCache = await engine.isProtectedFromTrashing(resolvedPath: "/Library/Caches/item")
        let credential = await engine.isProtectedFromTrashing(resolvedPath: "\(home)/.ssh/id_ed25519")
        let otherUser = await engine.isProtectedFromTrashing(resolvedPath: "/Users/another-user/file")
        let userDownload = await engine.isProtectedFromTrashing(resolvedPath: "\(home)/Downloads/archive.zip")
        XCTAssertTrue(systemCache)
        XCTAssertTrue(credential)
        XCTAssertTrue(otherUser)
        XCTAssertFalse(userDownload)
    }

    func testCleanupTreatsAlreadyMissingItemAsComplete() async {
        let path = "/tmp/MCleanTests-missing-\(UUID().uuidString)"
        let item = CleanableItem(
            name: "missing",
            path: path,
            size: 1024,
            category: .systemJunk,
            isSelected: true,
            lastModified: nil
        )

        let result = await CleaningEngine().cleanItems([item]) { _ in }

        XCTAssertTrue(result.cleanedPaths.contains(path))
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.itemsCleaned, 0)
    }

    func testCleanupRejectsSymlinkWithoutTouchingTarget() async throws {
        let base = URL(fileURLWithPath: "/tmp/MCleanTests-symlink-\(UUID().uuidString)")
        let target = base.appendingPathExtension("target")
        let link = base.appendingPathExtension("link")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let item = CleanableItem(
            name: link.lastPathComponent,
            path: link.path,
            size: 4,
            category: .systemJunk,
            isSelected: true,
            lastModified: nil
        )

        let result = await CleaningEngine().cleanItems([item]) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertFalse(result.cleanedPaths.contains(link.path))
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testSchedulerKeepsFutureRunWhenRestarted() throws {
        let suiteName = "MCleanTests.Scheduler.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = SchedulerService(defaults: defaults, configKey: "schedule")
        defer { scheduler.stop() }

        scheduler.updateSchedule(interval: .hours3)
        scheduler.toggleEnabled(true)
        let scheduled = try XCTUnwrap(scheduler.config.nextRunDate)
        scheduler.start()

        XCTAssertEqual(
            try XCTUnwrap(scheduler.config.nextRunDate).timeIntervalSince1970,
            scheduled.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(scheduled.timeIntervalSinceNow, 2.9 * 3600)
    }

    func testSchedulerPreservesNearFutureRunLoadedFromDisk() throws {
        let suiteName = "MCleanTests.Scheduler.NearFuture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = Date().addingTimeInterval(30)
        var config = ScheduleConfig()
        config.isEnabled = true
        config.nextRunDate = expected
        defaults.set(try JSONEncoder().encode(config), forKey: "schedule")

        let scheduler = SchedulerService(defaults: defaults, configKey: "schedule")
        defer { scheduler.stop() }

        XCTAssertEqual(
            try XCTUnwrap(scheduler.config.nextRunDate).timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 0.01
        )
    }

    func testVisibleSelectionPreservesHiddenRowsAndManualDefaults() {
        let state = AppState(performStartupTasks: false)
        let visible = cleanupItem(selected: false)
        let hidden = cleanupItem(selected: true)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [visible, hidden], totalSize: 200)
        state.setSelection(true, for: [visible])
        XCTAssertTrue(state.isItemSelected(visible))
        XCTAssertTrue(state.isItemSelected(hidden))
        state.setSelection(false, for: [visible])
        XCTAssertFalse(state.isItemSelected(visible))
        XCTAssertTrue(state.isItemSelected(hidden))
    }

    func testScheduledScanWaitsForReviewToLeaveForeground() {
        let state = AppState(performStartupTasks: false)
        let item = cleanupItem(selected: true)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [item], totalSize: 100)
        state.scanState = .completed
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: true))
        XCTAssertTrue(state.canRunScheduledScan(isAppActive: false))
        state.showCleanConfirmation = true
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        XCTAssertEqual(state.categoryResults[.userCache]?.items.map(\.id), [item.id])
        XCTAssertEqual(state.scanState, .completed)
    }

    func testManagedDerivedDataRequiresManualSelectionEvenForScheduledCleanup() throws {
        let state = AppState(performStartupTasks: false)
        let managedRoot = try XCTUnwrap(XcodeBuildMCPDerivedDataSupport.managedRoots().first)
        let item = CleanableItem(
            name: "XcodeBuildMCP: Fixture",
            path: managedRoot
                .appendingPathComponent("workspaces/Fixture-\(UUID().uuidString)/DerivedData").path,
            size: 4_096,
            category: .xcodeJunk,
            isSelected: false,
            lastModified: .distantPast
        )
        state.categoryResults[.xcodeJunk] = CategoryResult(category: .xcodeJunk, items: [item], totalSize: item.size)
        state.scanState = .completed

        XCTAssertFalse(state.isItemSelected(item))
        XCTAssertEqual(state.totalSelectedSize, 0)
        state.cleanAll()
        XCTAssertEqual(state.scanState, .completed)
        state.cleanAll(scheduled: true)
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertEqual(state.categoryResults[.xcodeJunk]?.items.map(\.id), [item.id])

        state.toggleItem(item)
        XCTAssertTrue(state.isItemSelected(item))
        XCTAssertEqual(state.totalSelectedSize, item.size)
        state.toggleItem(item)
        XCTAssertFalse(state.isItemSelected(item))
    }

    func testScheduledScanWaitsForActiveOperations() {
        let state = AppState(performStartupTasks: false)
        state.scanState = .cleaning(progress: 0.2)
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        state.scanState = .idle
        state.isRemovingAppFiles = true
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        state.isRemovingAppFiles = false
        state.spaceLens.state = .scanning
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        state.spaceLens.state = .trashing
        XCTAssertFalse(state.canRunScheduledScan(isAppActive: false))
        state.spaceLens.state = .ready
        XCTAssertTrue(state.canRunScheduledScan(isAppActive: false))
    }

    func testStopScanPreservesCompletedResultsAndDoesNotStopCleaning() {
        let state = AppState(performStartupTasks: false)
        state.categoryResults[.userCache] = CategoryResult(category: .userCache, items: [cleanupItem(selected: true)], totalSize: 100)
        state.scanState = .scanning(progress: 0.5, currentCategory: "User Cache")
        state.cancelScan()
        XCTAssertTrue(state.scanWasCancelled)
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertEqual(state.totalItemCount, 1)
        state.scanState = .cleaning(progress: 0.5)
        state.cancelScan()
        XCTAssertEqual(state.scanState, .cleaning(progress: 0.5))
    }

    private func cleanupItem(selected: Bool) -> CleanableItem {
        CleanableItem(name: "Fixture", path: "/fixtures/\(UUID().uuidString)", size: 100, category: .userCache, isSelected: selected, lastModified: nil)
    }

    private func makeApp(
        name: String = "MClean",
        path: String = "/Applications/MClean.app"
    ) -> InstalledApp {
        InstalledApp(
            id: UUID(),
            appName: name,
            bundleIdentifier: "com.maclife.mclean",
            path: URL(fileURLWithPath: path),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
    }
}

private final class StubLocations: Locations {
    init(paths: [String]) {
        super.init()
        appSearch = SearchCategory(name: "Apps", paths: paths)
    }
}
