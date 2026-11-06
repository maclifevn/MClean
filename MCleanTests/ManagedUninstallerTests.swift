import AppKit
import XCTest
@testable import MClean

final class ManagedUninstallerTests: XCTestCase {
    private let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    private let appURL = URL(fileURLWithPath: "/Users/example/Applications/Example.app")

    func testHomebrewRequiresTheInstalledDestinationInsteadOfTheAppName() throws {
        let wrongLocation: [String: Any] = ["app": ["Example.app"], "target": "/Applications/Example.app"]
        let match: [String: Any] = ["app": ["Source.app"], "target": appURL.path]
        let availableOnly: [String: Any] = ["token": "available", "installed": NSNull(), "artifacts": [match]]
        let matches = try casks([
            cask("same-name", artifacts: [wrongLocation]),
            cask("test/tap/example", artifacts: [match]),
            availableOnly,
        ])

        XCTAssertEqual(matches.map(\.token), ["test/tap/example"])
        let selected = try XCTUnwrap(matches.first)
        XCTAssertTrue(selected.canRunInMClean)
        XCTAssertTrue(selected.terminalCommand.hasSuffix("uninstall --cask -- test/tap/example"))
        XCTAssertFalse(AppInstallSource.homebrew(selected).permitsTrash([appURL], for: appURL))
    }

    func testHomebrewCatalogCannotOmitAnInstalledCask() throws {
        let caskroom = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: caskroom) }
        for path in ["example/.metadata/1.0", "omitted/.metadata/1.0", "unfinished"] {
            try FileManager.default.createDirectory(at: caskroom.appendingPathComponent(path),
                                                     withIntermediateDirectories: true)
        }
        let registered = try HomebrewUninstaller.registeredTokens(in: caskroom)
        XCTAssertEqual(registered, ["example", "omitted"])
        let app = ["app": ["Example.app"], "target": appURL.path] as [String: Any]
        let example = cask("test/tap/example", artifacts: [app])
        let incomplete = try JSONSerialization.data(withJSONObject: ["casks": [example]])
        XCTAssertFalse(HomebrewUninstaller.catalogCovers(registered, in: incomplete))
        let complete = try JSONSerialization.data(withJSONObject: [
            "casks": [example, cask("test/tap/omitted", artifacts: [app])],
        ])
        XCTAssertTrue(HomebrewUninstaller.catalogCovers(registered, in: complete))
    }

    func testHomebrewRecognizesAnAliasedDestinationWithoutRunningItsUninstall() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let realDirectory = root.appendingPathComponent("Real")
        let app = realDirectory.appendingPathComponent("Example.app")
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let linkedDirectory = root.appendingPathComponent("Link")
        try manager.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)

        let artifact = ["app": ["Example.app"], "target": linkedDirectory.appendingPathComponent("Example.app").path] as [String: Any]
        let result = try matches([cask("example", artifacts: [artifact])], path: app)
        guard case .installed(let cask) = try XCTUnwrap(result.first) else {
            return XCTFail("The cask owns the selected bundle through the linked directory")
        }
        XCTAssertFalse(cask.canRunInMClean)
    }

    func testCaskWithSeveralAppsOrRemovalHooksRequiresTerminalReview() throws {
        let app: [String: Any] = ["app": ["Example.app"], "target": appURL.path]
        let otherApp: [String: Any] = ["app": ["Other.app"], "target": "/Applications/Other.app"]
        let delete = ["uninstall": [["delete": ["/Library/Application Support/Shared Vendor"]]]]
        let zap = ["zap": [["trash": ["~/Library/Application Support/Shared Vendor"]]]]
        let matches = try casks([
            cask("suite", artifacts: [app, otherApp]),
            cask("with-delete", artifacts: [app, delete]),
            cask("with-zap", artifacts: [app, zap]),
        ])
        XCTAssertEqual(matches.map(\.canRunInMClean), [false, false, true])
        XCTAssertEqual(matches.first?.otherManagedPaths, ["/Applications/Other.app"])
        XCTAssertTrue(matches.allSatisfy { !$0.terminalCommand.contains("--zap") })
    }

    func testHomebrewRunsTheConfirmedCaskAndReportsRemainingRegistration() async throws {
        let app: [String: Any] = ["app": ["Example.app"], "target": appURL.path]
        let cask = try XCTUnwrap(casks([self.cask("test/tap/example", artifacts: [app])]).first)
        var commands: [[String]] = []
        do {
            try await HomebrewUninstaller.uninstall(cask) { executable, arguments, _ in
                XCTAssertEqual(executable, cask.brew)
                commands.append(arguments)
                let installed = arguments.first == "list" ? Data("test/tap/example\n".utf8) : Data()
                return BrewProcessOutput(stdout: installed, stderr: Data(), status: 0)
            }
            XCTFail("A cask still registered by Homebrew cannot be reported as removed")
        } catch let error as HomebrewUninstaller.RemovalError {
            XCTAssertEqual(error, .incomplete)
        }
        XCTAssertEqual(commands.first, ["uninstall", "--cask", "--", "test/tap/example"])
        XCTAssertEqual(commands.count, 2)
    }

    func testCaskCanMatchAPackageReceiptWithoutTreatingItsHooksAsAppOnly() throws {
        let receipt = InstallerReceipt(id: "com.example.pkg", version: "1.0")
        let unrelated = InstallerReceipt(id: "com.example.other.pkg", version: "1.0")
        let record = cask("example-pkg", artifacts: [["uninstall": [["pkgutil": "com.example.pkg"]]]])
        let regexRecord = cask("broad-pattern", artifacts: [["uninstall": [["pkgutil": "com.example.*"]]]])
        let matches = try casks([record, regexRecord], receipts: [receipt])
        XCTAssertEqual(matches.map(\.token), ["example-pkg"])
        XCTAssertEqual(matches.first?.canRunInMClean, false)
        XCTAssertTrue(try casks([record], receipts: [receipt, unrelated]).isEmpty)
    }

    func testCaskWithStaleVersionOrMissingDestinationDoesNotOfferAnUninstallCommand() throws {
        let app: [String: Any] = ["app": ["Example.app"], "target": appURL.path]
        var stale = cask("example", artifacts: [app])
        stale["version"] = "2.0"
        let unknownLocation = cask("legacy-example", artifacts: [["app": ["Example.app"]]])
        XCTAssertEqual(try matches([stale, unknownLocation]), [.unverified, .unverified])
    }

    func testReceiptFallbackUsesTheExactBundleAndItsInstallLocation() throws {
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        let anchor = app.appendingPathComponent("Contents/Info.plist")
        let root = URL(fileURLWithPath: "/Applications")
        let data = Data("""
        .
        ./Example.app
        ./Example.app/Contents
        ./Example.app/Contents/Info.plist
        """.utf8)
        let coverage = try XCTUnwrap(PackageUninstaller.coverage(data, rootedAt: root, app: app, anchors: [anchor]))
        let receipt = InstallerReceipt(id: "com.example.pkg", version: "1.0")
        let identified = try XCTUnwrap(PackageUninstaller.classify(owners: [], coverage: [(receipt, coverage)], complete: true))
        XCTAssertEqual(identified.receipts, [receipt])
        XCTAssertTrue(identified.canMoveBundle)
        let source = AppInstallSource.installerPackage(identified)
        XCTAssertTrue(source.permitsTrash([app], for: app))
        XCTAssertFalse(source.permitsTrash([app, URL(fileURLWithPath: "/Library/Application Support/Shared Vendor")], for: app))

        let other = URL(fileURLWithPath: "/Volumes/Other/Applications")
        XCTAssertFalse(try XCTUnwrap(PackageUninstaller.coverage(data, rootedAt: other, app: app, anchors: [anchor])).touchesApp)
    }

    func testSharedReceiptOrPayloadOutsideBundleBlocksManualPackageRemoval() throws {
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        let anchor = app.appendingPathComponent("Contents/Info.plist")
        let root = URL(fileURLWithPath: "/")
        let own = InstallerReceipt(id: "com.example.pkg", version: "1")
        let shared = InstallerReceipt(id: "com.example.shared", version: "1")
        let inside = Data("./Applications/Example.app\n./Applications/Example.app/Contents/Info.plist\n".utf8)
        let outside = inside + Data("./Library/Application Support/Vendor/helper\n".utf8)
        let plugin = Data("./Applications/Example.app/Contents/PlugIns/Shared.plugin\n".utf8)

        let isolated = try XCTUnwrap(PackageUninstaller.coverage(inside, rootedAt: root, app: app, anchors: [anchor]))
        let overlap = try XCTUnwrap(PackageUninstaller.coverage(plugin, rootedAt: root, app: app, anchors: [anchor]))
        let suite = try XCTUnwrap(PackageUninstaller.coverage(outside, rootedAt: root, app: app, anchors: [anchor]))
        XCTAssertTrue(overlap.touchesApp)
        XCTAssertFalse(overlap.matchesApp)
        XCTAssertFalse(suite.confinedToApp)
        XCTAssertEqual(PackageUninstaller.classify(owners: [], coverage: [(own, isolated), (shared, overlap)],
                                                    complete: true)?.canMoveBundle, false)
        XCTAssertEqual(PackageUninstaller.classify(owners: [], coverage: [(own, suite)],
                                                    complete: true)?.canMoveBundle, false)
        XCTAssertEqual(PackageUninstaller.classify(owners: [shared], coverage: [(own, isolated)],
                                                    complete: true)?.canMoveBundle, false)
        XCTAssertEqual(PackageUninstaller.classify(owners: [], coverage: [(own, isolated)],
                                                    complete: false)?.canMoveBundle, false)
    }

    func testPackageCoverageDistinguishesAppleDoubleMetadataFromInstalledSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Applications/Example.app")
        let anchor = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: anchor.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("""
        .
        ./._Applications
        ./Applications
        ./Applications/._Example.app
        ./Applications/Example.app
        ./Applications/Example.app/Contents/Info.plist
        """.utf8)

        let metadataOnly = try XCTUnwrap(PackageUninstaller.coverage(data, rootedAt: root, app: app, anchors: [anchor]))
        XCTAssertTrue(metadataOnly.matchesApp)
        XCTAssertTrue(metadataOnly.confinedToApp)

        let sidecar = app.deletingLastPathComponent().appendingPathComponent("._Example.app")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: root.appendingPathComponent("missing"))
        let installedSidecar = try XCTUnwrap(PackageUninstaller.coverage(data, rootedAt: root, app: app, anchors: [anchor]))
        XCTAssertFalse(installedSidecar.confinedToApp)
    }

    func testReceiptWithDifferentCaseStillBlocksStandaloneRemovalOnAnInsensitiveVolume() throws {
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        let anchor = app.appendingPathComponent("Contents/Info.plist")
        let data = Data("./applications/EXAMPLE.app\n./applications/EXAMPLE.app/Contents/Info.plist\n".utf8)
        let root = URL(fileURLWithPath: "/")
        let sensitive = try XCTUnwrap(PackageUninstaller.coverage(data, rootedAt: root, app: app, anchors: [anchor]))
        XCTAssertFalse(sensitive.touchesApp)

        let insensitive = try XCTUnwrap(PackageUninstaller.coverage(
            data, rootedAt: root, app: app, anchors: [anchor], caseSensitive: false
        ))
        XCTAssertTrue(insensitive.touchesApp)
        let receipt = InstallerReceipt(id: "com.example.pkg", version: "1")
        let package = PackageUninstaller.classify(owners: [], coverage: [(receipt, insensitive)], complete: true)
        XCTAssertEqual(package?.receipts, [receipt])
        XCTAssertEqual(package?.canMoveBundle, false)
    }

    private func cask(_ token: String, artifacts: [[String: Any]]) -> [String: Any] {
        ["full_token": token, "version": "1.0", "installed": "1.0", "bundle_short_version": "1.0",
         "artifacts": artifacts]
    }

    private func casks(_ records: [[String: Any]], receipts: [InstallerReceipt] = []) throws -> [HomebrewCask] {
        try matches(records, receipts: receipts).compactMap {
            guard case .installed(let cask) = $0 else { return nil }
            return cask
        }
    }

    private func matches(_ records: [[String: Any]], receipts: [InstallerReceipt] = [],
                         path: URL? = nil) throws -> [HomebrewUninstaller.Match] {
        let app = InstalledApp(appName: "Example", bundleIdentifier: "com.example.app", path: path ?? appURL,
                               icon: NSImage(size: .zero), size: 0, version: "1.0")
        let data = try JSONSerialization.data(withJSONObject: ["casks": records])
        return HomebrewUninstaller.matchingCasks(in: data, from: brew, app: AppInstallation(app), receipts: receipts)
    }
}
