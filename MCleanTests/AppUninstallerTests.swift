import AppKit
import XCTest
@testable import MClean

final class AppUninstallerTests: XCTestCase {
    func testPhotoshopAliasRequiresMatchingInstalledVersionAndTrustedTarget() throws {
        let root = try fixtureDirectory()
        let app = root.appendingPathComponent("Adobe Photoshop 2025.app")
        try writeInfoPlist(at: app, identifier: "com.adobe.Photoshop", version: "26.11.0")
        let uninstallDirectory = root.appendingPathComponent("Adobe Targets")
        let target = uninstallDirectory.appendingPathComponent("PHSP_26_11_32.app")
        try writeInfoPlist(at: target, identifier: "com.adobe.HDUninstaller", version: "6.10.0")
        try writeAdobeArguments(for: target, product: "PHSP", version: "26.11")
        let alias = root.appendingPathComponent("Uninstall Adobe Photoshop 2025")
        try URL.writeBookmarkData(
            target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
            to: alias
        )

        func resolve(_ version: String, trusted: Bool = true) -> URL? {
            AdobeUninstaller.photoshopUninstaller(for: app, selectedVersion: version,
                uninstallDirectory: uninstallDirectory, isTrusted: { _, _, _, _ in trusted })
        }

        XCTAssertEqual(resolve("26.11.0")?.path, target.resolvingSymlinksInPath().path)
        XCTAssertNil(resolve("26.11.1"))
        XCTAssertNil(resolve("26.11.0", trusted: false))
        XCTAssertNil(AdobeUninstaller.photoshopUninstaller(for: app, selectedVersion: "26.11.0",
                                                           uninstallDirectory: uninstallDirectory))

        try writeAdobeArguments(for: target, product: "ILST", version: "26.11")
        XCTAssertNil(resolve("26.11.0"))
        try writeAdobeArguments(for: target, product: "PHSP", version: "26.11.1")
        XCTAssertNil(resolve("26.11.0"))
        try FileManager.default.removeItem(at: alias)
        XCTAssertNil(resolve("26.11.0"))

        try writeAdobeArguments(for: target, product: "PHSP", version: "26.11")
        for name in ["Uninstall", "Adobe Photoshop 2025 Uninstaller"] {
            let alternateAlias = root.appendingPathComponent(name)
            try URL.writeBookmarkData(
                target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
                to: alternateAlias
            )
            XCTAssertEqual(resolve("26.11.0")?.path, target.resolvingSymlinksInPath().path)
            try FileManager.default.removeItem(at: alternateAlias)
        }
    }

    func testUnsignedLookalikeFailsAdobeSignatureRequirement() throws {
        let root = try fixtureDirectory()
        let app = root.appendingPathComponent("PHSP_26_11_32.app")
        try writeInfoPlist(at: app, identifier: "com.adobe.HDUninstaller", version: "6.10.0")
        XCTAssertFalse(AppCodeSignature.isValid(at: app, requirement:
            #"anchor apple generic and identifier "com.adobe.HDUninstaller" and certificate leaf[subject.OU] = "JQ525L2MZD""#))
    }

    func testScannerKeepsSelectedBundleAndRejectsOtherApplicationPaths() throws {
        let root = try fixtureDirectory()
        let apps = root.appendingPathComponent("Applications")
        let selected = apps.appendingPathComponent("Example 2025/Example 2025.app")
        let other = apps.appendingPathComponent("Example 2026/Example 2026.app")
        for url in [selected, other] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let locations = Locations()
        locations.appSearch.paths = [apps.path]
        let appInfo = AppPathFinder.AppInfo(appName: "Example 2025", bundleIdentifier: "com.example.mclean-fixture",
                                            path: selected, entitlements: nil, teamIdentifier: nil)
        let found = Set(AppPathFinder(appInfo: appInfo, locations: locations).findPaths().map(\.path))
        XCTAssertTrue(found.contains(selected.path))
        XCTAssertFalse(found.contains(selected.deletingLastPathComponent().path))
        XCTAssertFalse(found.contains(other.path))
        XCTAssertFalse(AppUninstaller.isRelatedPath(other.deletingLastPathComponent(), app: selected, otherApps: [other]))
    }

    func testSharedAndFuzzyFilesRequireReview() {
        let home = URL(fileURLWithPath: "/Users/example")
        let app = InstalledApp(appName: "Example", bundleIdentifier: "com.example.mclean-fixture",
                               path: URL(fileURLWithPath: "/Applications/Example.app"),
                               icon: NSImage(size: .zero), size: 0, version: "1.0")
        let library = home.appendingPathComponent("Library")
        let preference = library.appendingPathComponent("Preferences/com.example.mclean-fixture.plist")
        let group = library.appendingPathComponent("Group Containers/com.example.mclean-fixture")
        let fuzzy = library.appendingPathComponent("Application Support/Example Backup")
        XCTAssertTrue(AppUninstaller.isSelectedByDefault(preference, app: app, hasOtherVersion: false, homeDirectory: home))
        XCTAssertFalse(AppUninstaller.isSelectedByDefault(preference, app: app, hasOtherVersion: true, homeDirectory: home))
        XCTAssertFalse(AppUninstaller.isSelectedByDefault(group, app: app, hasOtherVersion: false, homeDirectory: home))
        XCTAssertFalse(AppUninstaller.isSelectedByDefault(fuzzy, app: app, hasOtherVersion: false, homeDirectory: home))
    }

    func testDeepMatchingKeepsPublisherFolderAndOtherProductDataOutOfResults() throws {
        let root = try fixtureDirectory()
        let app = root.appendingPathComponent("Orchid.app")
        let support = root.appendingPathComponent("Support")
        let shared = support.appendingPathComponent("Vendor")
        let specific = support.appendingPathComponent("Vendor Tools for Orchid")
        let other = support.appendingPathComponent("Vendor Lotus")
        for url in [app, shared, specific, other] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let locations = Locations()
        locations.appSearch.paths = [support.path]
        let info = AppPathFinder.AppInfo(appName: "Orchid", bundleIdentifier: "com.vendor.orchid",
                                         path: app, entitlements: nil, teamIdentifier: nil)
        let paths = Set(AppPathFinder(appInfo: info, locations: locations, sensitivity: .deep).findPaths().map(\.path))
        XCTAssertEqual(paths, [app.path, specific.path])
    }

    func testMatchingAnotherInstalledVersionsFolderIsNotEligibleForRemoval() {
        let first = InstalledApp(appName: "Example 2025", bundleIdentifier: "com.example.app",
                                 path: URL(fileURLWithPath: "/Applications/Example 2025.app"),
                                 icon: NSImage(size: .zero), size: 0, version: "1.0")
        let second = InstalledApp(appName: "Example 2026", bundleIdentifier: first.bundleIdentifier,
                                  path: URL(fileURLWithPath: "/Applications/Example 2026.app"),
                                  icon: NSImage(size: .zero), size: 0, version: "2.0")
        let conflicting = AppUninstaller.conflictingNames(for: first, otherApps: [second])
        XCTAssertFalse(AppUninstaller.isRelatedPath(URL(fileURLWithPath: "/Library/Application Support/Example 2026"),
                                                    app: first.path, otherApps: [second.path], conflictingNames: conflicting))
        XCTAssertTrue(AppUninstaller.isRelatedPath(URL(fileURLWithPath: "/Library/Application Support/Example 2025"),
                                                   app: first.path, otherApps: [second.path], conflictingNames: conflicting))
    }

    func testPartialRemovalSeparatesMovedMissingAndPermissionDenied() throws {
        let root = try fixtureDirectory()
        let app = root.appendingPathComponent("Example.app")
        let support = root.appendingPathComponent("Example support")
        let missing = root.appendingPathComponent("missing")
        for url in [app, support] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let trash = root.appendingPathComponent("Test Trash")
        let result = AppUninstaller.moveToTrash([app, support, missing].map(AppRemovalTarget.init),
                                               app: app, otherApps: [], hasFullDiskAccess: false) { url in
            guard url == app else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
            try FileManager.default.moveItem(at: url, to: trash)
        }
        XCTAssertEqual(result.moved, [app])
        XCTAssertEqual(result.missing, [missing])
        XCTAssertEqual(result.failures.map(\.target.url), [support])
        XCTAssertEqual(result.failures.map(\.reason), [.permission])
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
    }

    func testRemovalRejectsReplacementAndFolderContainingAnotherApplication() throws {
        let root = try fixtureDirectory()
        let file = root.appendingPathComponent("Example Cache")
        let original = root.appendingPathComponent("Original Cache")
        let otherFolder = root.appendingPathComponent("Other Folder")
        let otherApp = otherFolder.appendingPathComponent("Other.app")
        try Data([1]).write(to: file)
        try FileManager.default.createDirectory(at: otherApp, withIntermediateDirectories: true)
        let targets = [file, otherFolder].map(AppRemovalTarget.init)
        try FileManager.default.moveItem(at: file, to: original)
        try Data([2]).write(to: file)

        let result = AppUninstaller.moveToTrash(targets, app: root.appendingPathComponent("Example.app"),
                                               otherApps: [otherApp], hasFullDiskAccess: true) { _ in
            XCTFail("An unsafe item reached the trash operation")
        }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.map(\.reason), [.changed, .protected])
        XCTAssertEqual(try Data(contentsOf: file), Data([2]))
    }

    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MClean-AppUninstaller-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeInfoPlist(at url: URL, identifier: String, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func writeAdobeArguments(for target: URL, product: String, version: String) throws {
        let args = """
        --sapCode=\(product)
        --productVersion=\(version)
        --productPlatform=macuniversal
        --productAdobeCode={\(product)-\(version)-32-ADBEADBEADBEADBEADBEAD}
        --mode=2
        """
        try args.write(to: target.deletingPathExtension().appendingPathExtension("adbarg"), atomically: true, encoding: .utf8)
    }
}
