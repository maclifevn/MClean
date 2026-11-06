import Foundation

struct AppInstallation: Equatable, Sendable {
    let path: URL
    let bundleIdentifier: String
    let version: String?

    init(_ app: InstalledApp) {
        path = app.id
        bundleIdentifier = app.bundleIdentifier
        version = app.version
    }

    var currentBundleInfo: [String: String]? {
        guard !FileProtection.hasUnexpectedSymlink(in: path.path),
              let info = NSDictionary(contentsOf: path.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              (info["CFBundleIdentifier"] as? String ?? path.deletingPathExtension().lastPathComponent) == bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else { return nil }
        return info.compactMapValues { $0 as? String }
    }
}

struct InstallerReceipt: Hashable, Identifiable, Sendable {
    let id: String
    let version: String
}

struct InstallerPackage: Equatable, Sendable {
    let receipts: [InstallerReceipt]
    let canMoveBundle: Bool
}

enum PackageUninstaller {
    struct Inspection: Sendable {
        let package: InstallerPackage?
        let complete: Bool
    }

    private struct Payload: Sendable {
        let receipt: InstallerReceipt
        let installRoot: URL
        let source: Source

        enum Source: Sendable {
            case bom(URL)
            case registered(URL)
        }
    }

    struct Coverage: Equatable, Sendable {
        let matchesApp: Bool
        let touchesApp: Bool
        let confinedToApp: Bool
    }

    private struct ReceiptFacts: Sendable {
        let owners: [InstallerReceipt]
        let coverage: [(InstallerReceipt, Coverage)]
        let complete: Bool
    }

    private static let pkgutil = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    private static let lsbom = URL(fileURLWithPath: "/usr/bin/lsbom")

    static func inspect(_ app: AppInstallation) async -> Inspection {
        guard let info = app.currentBundleInfo,
              let volumeInfo = try? app.path.resourceValues(forKeys: [.volumeURLKey, .volumeSupportsCaseSensitiveNamesKey]),
              let volume = volumeInfo.volume else {
            return Inspection(package: nil, complete: false)
        }
        let caseSensitive = volumeInfo.volumeSupportsCaseSensitiveNames == true

        let infoPlist = app.path.appendingPathComponent("Contents/Info.plist")
        let anchors: [URL]
        if let name = info["CFBundleExecutable"], !name.isEmpty, name != ".", name != "..", !name.contains("/") {
            anchors = [infoPlist, app.path.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)]
        } else {
            anchors = [infoPlist]
        }

        async let volumeFacts = inspectReceipts(on: volume, app: app.path, anchors: anchors, caseSensitive: caseSensitive)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let facts: [ReceiptFacts]
        if home.path != volume.path, contains(app.path.path, in: home.path, caseSensitive: caseSensitive) {
            async let homeFacts = inspectReceipts(on: home, app: app.path, anchors: anchors, caseSensitive: caseSensitive)
            facts = await [volumeFacts, homeFacts]
        } else {
            facts = await [volumeFacts]
        }
        let complete = facts.allSatisfy(\.complete)
        return Inspection(package: classify(owners: facts.flatMap(\.owners), coverage: facts.flatMap(\.coverage),
                                            complete: complete), complete: complete)
    }

    private static func inspectReceipts(on volume: URL, app: URL, anchors: [URL],
                                        caseSensitive: Bool) async -> ReceiptFacts {
        async let directOwners = lookupOwners(at: [app] + anchors, volume: volume)
        let registered = await registeredReceipts(on: volume)
        var (payloads, coveredIDs) = payloadCatalog(on: volume, intersecting: app, registered: registered,
                                                   caseSensitive: caseSensitive)
        if let registered {
            for id in registered.subtracting(coveredIDs) {
                guard !Task.isCancelled else { break }
                if let payload = await registeredPayload(id: id, volume: volume, caseSensitive: caseSensitive) {
                    coveredIDs.insert(id)
                    if intersects(payload.installRoot, app, caseSensitive: caseSensitive) { payloads.append(payload) }
                }
            }
        }
        let (coverage, checked) = await inspectPayloads(payloads, app: app, anchors: anchors, caseSensitive: caseSensitive)
        let owners = await directOwners
        let complete = registered?.isSubset(of: coveredIDs) == true && checked && owners != nil && !Task.isCancelled

        return ReceiptFacts(owners: owners ?? [], coverage: coverage, complete: complete)
    }

    static func classify(owners: [InstallerReceipt], coverage: [(InstallerReceipt, Coverage)],
                         complete: Bool) -> InstallerPackage? {
        let receipts = Set(owners + coverage.map(\.0)).sorted {
            ($0.id, $0.version) < ($1.id, $1.version)
        }
        guard !receipts.isEmpty else { return nil }
        // A single receipt must describe the selected bundle, and its payload
        // must stay inside that bundle. Preserve suites and overlapping installs.
        let canMoveBundle = complete && receipts.count == 1 && coverage.count == 1
            && coverage[0].1.matchesApp && coverage[0].1.confinedToApp
            && !receipts[0].id.hasPrefix("com.apple.")
        return InstallerPackage(receipts: receipts, canMoveBundle: canMoveBundle)
    }

    private static func lookupOwners(at urls: [URL], volume: URL) async -> [InstallerReceipt]? {
        var owners: [InstallerReceipt] = []
        for url in urls {
            guard !Task.isCancelled,
                  let output = try? await BrewProcessRunner.run(executableURL: pkgutil,
                      arguments: ["--volume", volume.path, "--file-info-plist", url.path], timeout: 4),
                  output.status == 0, let records = parseOwners(output.stdout, for: url) else { return nil }
            owners += records
        }
        return owners
    }

    private static func parseOwners(_ data: Data, for url: URL) -> [InstallerReceipt]? {
        guard let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = record["path"] as? String, path == url.path,
              let entries = record["path-info"] as? [[String: Any]] else { return nil }
        var result: [InstallerReceipt] = []
        for entry in entries {
            guard let id = entry["pkgid"] as? String, !id.isEmpty,
                  let version = entry["pkg-version"] as? String else { return nil }
            result.append(.init(id: id, version: version))
        }
        return result
    }

    private static func registeredReceipts(on volume: URL) async -> Set<String>? {
        guard let output = try? await BrewProcessRunner.run(executableURL: pkgutil,
                arguments: ["--volume", volume.path, "--pkgs-plist"], timeout: 4),
              output.status == 0,
              let ids = try? PropertyListSerialization.propertyList(from: output.stdout, format: nil) as? [String]
        else { return nil }
        return Set(ids)
    }

    private static func registeredPayload(id: String, volume: URL, caseSensitive: Bool) async -> Payload? {
        // This argument is a receipt ID supplied by pkgutil. Reject options.
        guard !id.isEmpty, !id.hasPrefix("-"),
              let output = try? await BrewProcessRunner.run(executableURL: pkgutil,
                  arguments: ["--volume", volume.path, "--pkg-info-plist", id], timeout: 4),
              output.status == 0,
              let metadata = try? PropertyListSerialization.propertyList(from: output.stdout, format: nil) as? [String: Any],
              (metadata["pkgid"] as? String) == id,
              let version = metadata["pkg-version"] as? String,
              let prefix = metadata["install-location"] as? String,
              let root = installRoot(prefix, on: volume, caseSensitive: caseSensitive) else { return nil }
        return Payload(receipt: .init(id: id, version: version), installRoot: root, source: .registered(volume))
    }

    private static func payloadCatalog(on volume: URL, intersecting app: URL,
                                       registered: Set<String>?, caseSensitive: Bool) -> ([Payload], Set<String>) {
        let manager = FileManager.default
        var payloads: [Payload] = []
        var coveredIDs: Set<String> = []
        for relativeRoot in ["private/var/db/receipts", "Library/Apple/System/Library/Receipts", "Library/Receipts"] {
            let directory = volume.appendingPathComponent(relativeRoot, isDirectory: true)
            guard let items = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { continue }
            for bom in items where bom.pathExtension == "bom" {
                let id = bom.deletingPathExtension().lastPathComponent
                if let registered, !registered.contains(id) { continue }
                let plist = bom.deletingPathExtension().appendingPathExtension("plist")
                guard let metadata = NSDictionary(contentsOf: plist),
                      (metadata["PackageIdentifier"] as? String) == id,
                      let version = metadata["PackageVersion"] as? String,
                      let prefix = metadata["InstallPrefixPath"] as? String,
                      let root = installRoot(prefix, on: volume, caseSensitive: caseSensitive) else { continue }
                coveredIDs.insert(id)
                if intersects(root, app, caseSensitive: caseSensitive) {
                    payloads.append(.init(receipt: .init(id: id, version: version), installRoot: root, source: .bom(bom)))
                }
            }
        }
        return (payloads, coveredIDs)
    }

    private static func inspectPayloads(_ payloads: [Payload], app: URL, anchors: [URL],
                                        caseSensitive: Bool) async -> ([(InstallerReceipt, Coverage)], Bool) {
        await withTaskGroup(of: (InstallerReceipt, Coverage?).self) { group in
            var pending = payloads.makeIterator()
            var matches: [(InstallerReceipt, Coverage)] = []
            var complete = true
            func submit(_ payload: Payload) {
                group.addTask {
                    let executable: URL
                    let arguments: [String]
                    switch payload.source {
                    case .bom(let bom):
                        executable = lsbom
                        arguments = ["-s", bom.path]
                    case .registered(let volume):
                        executable = pkgutil
                        arguments = ["--volume", volume.path, "--files", payload.receipt.id]
                    }
                    let output = try? await BrewProcessRunner.run(executableURL: executable, arguments: arguments,
                                                                   timeout: 10, outputLimit: 48 * 1024 * 1024)
                    let coverage = output.flatMap { $0.status == 0 ? Self.coverage($0.stdout, rootedAt: payload.installRoot,
                        app: app, anchors: anchors, caseSensitive: caseSensitive) : nil }
                    return (payload.receipt, coverage)
                }
            }
            for _ in 0..<4 {
                if let payload = pending.next() { submit(payload) }
            }
            for await (receipt, result) in group {
                if let result {
                    if result.touchesApp { matches.append((receipt, result)) }
                } else {
                    complete = false
                }
                if !Task.isCancelled, let payload = pending.next() { submit(payload) }
            }
            return (matches, complete)
        }
    }

    static func coverage(_ data: Data, rootedAt root: URL, app: URL, anchors: [URL],
                         caseSensitive: Bool = true) -> Coverage? {
        guard let paths = String(data: data, encoding: .utf8) else { return nil }
        // Some receipts contain hundreds of thousands of unrelated paths. A
        // missing bundle name rules out a match when the BOM starts above it.
        if !contains(root.path, in: app.path, caseSensitive: caseSensitive),
           data.range(of: Data(app.lastPathComponent.utf8)) == nil,
           paths.range(of: app.lastPathComponent, options: caseSensitive ? [] : .caseInsensitive) == nil {
            return Coverage(matchesApp: false, touchesApp: false, confinedToApp: false)
        }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        let anchorPaths = Set(anchors.map(\.path))
        let appPath = app.path
        var sawBundle = false
        var sawAnchor = false
        var sawDescendant = false
        var sawCaseVariant = false
        var outside = false

        for line in paths.split(separator: "\n") {
            let relative = line.hasPrefix("./") ? line.dropFirst(2) : line[...]
            if relative == "." || relative.isEmpty { continue }
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
            let path = prefix + relative
            if path == appPath {
                sawBundle = true
            } else if path.hasPrefix(appPath + "/") {
                sawDescendant = true
                if anchorPaths.contains(path) { sawAnchor = true }
            } else if !appPath.hasPrefix(path + "/"), !isUnmaterializedAppleDouble(path, for: appPath) {
                // An alternate spelling can refer to this app on a case-insensitive
                // volume. Recognize the receipt but require exact paths for Trash.
                if !caseSensitive, contains(path, in: appPath, caseSensitive: false) { sawCaseVariant = true }
                outside = true
            }
        }
        return Coverage(matchesApp: sawAnchor && (sawBundle || root.path == appPath),
                        touchesApp: sawBundle || sawDescendant || sawCaseVariant, confinedToApp: sawDescendant && !outside)
    }

    private static func isUnmaterializedAppleDouble(_ path: String, for appPath: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard name.hasPrefix("._"), name.count > 2 else { return false }
        let original = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst(2)))
        guard contains(appPath, in: original.path) else { return false }

        // Installer can apply AppleDouble entries as attributes on the bundle
        // or its parent directories instead of creating separate files.
        // lstat also treats a dangling symlink as an actual payload item.
        var metadata = stat()
        return lstat(path, &metadata) != 0 && errno == ENOENT
    }

    private static func contains(_ path: String, in root: String, caseSensitive: Bool = true) -> Bool {
        if root == "/" || path == root || path.hasPrefix(root + "/") { return true }
        guard !caseSensitive else { return false }
        let foldedPath = path.folding(options: .caseInsensitive, locale: nil)
        let foldedRoot = root.folding(options: .caseInsensitive, locale: nil)
        return foldedPath == foldedRoot || foldedPath.hasPrefix(foldedRoot + "/")
    }

    private static func intersects(_ root: URL, _ app: URL, caseSensitive: Bool) -> Bool {
        contains(app.path, in: root.path, caseSensitive: caseSensitive)
            || contains(root.path, in: app.path, caseSensitive: caseSensitive)
    }

    private static func installRoot(_ prefix: String, on volume: URL, caseSensitive: Bool) -> URL? {
        guard !prefix.split(separator: "/").contains("..") else { return nil }
        if volume.path != "/", contains(prefix, in: volume.path, caseSensitive: caseSensitive) {
            return URL(fileURLWithPath: prefix).resolvingSymlinksInPath().standardizedFileURL
        }
        return volume.appendingPathComponent(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .resolvingSymlinksInPath().standardizedFileURL
    }
}
