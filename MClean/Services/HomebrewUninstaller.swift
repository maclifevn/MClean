import Foundation

struct HomebrewCask: Equatable, Sendable {
    let brew: URL
    let token: String
    let version: String
    let canRunInMClean: Bool
    let otherManagedPaths: [String]

    var terminalCommand: String {
        let (executable, arguments) = HomebrewUninstaller.command(for: brew,
            arguments: ["uninstall", "--cask", "--", token])
        // All components are fixed executable paths/options or a validated cask token.
        return (["/usr/bin/env", "-u", "HOMEBREW_CASK_OPTS", executable.path] + arguments).joined(separator: " ")
    }
}

enum AppInstallSource: Equatable, Sendable {
    case standalone
    case homebrew(HomebrewCask)
    case installerPackage(InstallerPackage)
    case unverified

    static func inspect(_ app: AppInstallation) async -> Self {
        async let package = PackageUninstaller.inspect(app)
        async let catalogs = HomebrewUninstaller.installedCatalogs()
        let receiptInspection = await package
        let brewCatalogs = await catalogs
        let matching = brewCatalogs.catalogs.flatMap {
            HomebrewUninstaller.matchingCasks(in: $0.data, from: $0.brew, app: app,
                receipts: receiptInspection.package?.receipts ?? [])
        }
        if matching.count == 1, case .installed(let cask) = matching[0], brewCatalogs.complete {
            return .homebrew(.init(brew: cask.brew, token: cask.token, version: cask.version,
                canRunInMClean: cask.canRunInMClean && receiptInspection.complete, otherManagedPaths: cask.otherManagedPaths))
        }
        if !matching.isEmpty { return .unverified }
        if let package = receiptInspection.package {
            if brewCatalogs.complete { return .installerPackage(package) }
            return .installerPackage(.init(receipts: package.receipts, canMoveBundle: false))
        }
        return receiptInspection.complete && brewCatalogs.complete ? .standalone : .unverified
    }

    func permitsTrash(_ urls: Set<URL>, for app: URL) -> Bool {
        switch self {
        case .standalone:
            return !urls.isEmpty
        case .installerPackage(let package):
            return package.canMoveBundle && urls.count == 1 && urls.first?.path == app.path
        case .homebrew, .unverified:
            return false
        }
    }
}

enum HomebrewUninstaller {
    enum Match: Equatable, Sendable {
        case installed(HomebrewCask)
        case unverified
    }

    static func installedCatalogs() async -> (catalogs: [(brew: URL, data: Data)], complete: Bool) {
        var catalogs: [(URL, Data)] = []
        var complete = true
        for path in ApplicationUpdater.trustedBrewPaths {
            guard !Task.isCancelled else { return ([], false) }
            let brew = URL(fileURLWithPath: path)
            let caskroom = brew.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Caskroom")
            let registered: Set<String>
            do {
                registered = try registeredTokens(in: caskroom)
            } catch {
                complete = false
                continue
            }
            guard !registered.isEmpty else { continue }

            guard FileManager.default.isExecutableFile(atPath: path),
                  let result = try? await run(brew, ["info", "--cask", "--installed", "--json=v2"], timeout: 20),
                  result.status == 0, catalogCovers(registered, in: result.stdout) else {
                complete = false
                continue
            }
            catalogs.append((brew, result.stdout))
        }
        return (catalogs, complete)
    }

    static func registeredTokens(in caskroom: URL) throws -> Set<String> {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(at: caskroom, includingPropertiesForKeys: Array(keys),
                                                       options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        var tokens: Set<String> = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let metadata = entry.appendingPathComponent(".metadata")
            do {
                let versions = try manager.contentsOfDirectory(atPath: metadata.path)
                if versions.contains(where: { !$0.hasPrefix(".") }) {
                    tokens.insert(entry.lastPathComponent)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            }
        }
        return tokens
    }

    static func catalogCovers(_ registered: Set<String>, in data: Data) -> Bool {
        guard let records = caskRecords(in: data) else { return false }
        // Homebrew can omit an installed cask if it cannot load its recipe.
        // An omitted cask must not be mistaken for an unmanaged application.
        let listed = records.compactMap { record in
            installedFields(in: record)?.token.split(separator: "/").last.map(String.init)
        }
        return registered.isSubset(of: Set(listed))
    }

    static func matchingCasks(in data: Data, from brew: URL, app: AppInstallation,
                              receipts: [InstallerReceipt]) -> [Match] {
        let receiptIDs = Set(receipts.map(\.id))
        let appTarget = AppRemovalTarget(app.path)
        return (caskRecords(in: data) ?? []).compactMap { record in
            guard let (token, installed, artifacts) = installedFields(in: record) else { return nil }

            let appArtifacts = artifacts.filter { $0["app"] != nil }
            let appPaths = appArtifacts.compactMap { targetPath(for: $0, kind: "app") }
            let matchingPaths = appPaths.filter { path in
                path == app.path.path || appTarget.matchesItem(at: URL(fileURLWithPath: path))
            }
            let exactApp = !matchingPaths.isEmpty
            let managedSuite = artifacts.contains { artifact in
                guard artifact["suite"] != nil, let target = targetPath(for: artifact, kind: "suite"),
                      !["/", "/Applications", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications"]
                        .contains(target) else { return false }
                return app.path.path.hasPrefix(target + "/")
            }
            let uninstallReceiptIDs = Set(artifacts.flatMap { artifact in
                (artifact["uninstall"] as? [[String: Any]] ?? []).flatMap { strings(from: $0["pkgutil"]) }
            })
            let matchingReceipts = appArtifacts.isEmpty && !receiptIDs.isEmpty
                && receiptIDs.isSubset(of: uninstallReceiptIDs)
            if !exactApp && !managedSuite && !matchingReceipts {
                let unresolved = appArtifacts.contains { artifact in
                    guard targetPath(for: artifact, kind: "app") == nil,
                          let artifactName = (artifact["app"] as? [Any])?.first as? String else { return false }
                    return (artifactName as NSString).lastPathComponent == app.path.lastPathComponent
                }
                let linkedApp = appPaths.contains {
                    appTarget.matchesItem(at: URL(fileURLWithPath: $0).resolvingSymlinksInPath())
                }
                return unresolved || linkedApp ? .unverified : nil
            }

            let bundleVersion = record["bundle_short_version"] as? String ?? ""
            guard (record["version"] as? String) == installed,
                  !exactApp || bundleVersion == app.version || ["", "0", "0.0"].contains(bundleVersion)
            else { return .unverified }
            let sameApplicationOnly = exactApp && receipts.isEmpty && appArtifacts.count == 1
                && !matchingPaths.contains(where: FileProtection.hasUnexpectedSymlink)
                && artifacts.allSatisfy { canRemoveArtifact($0, app: app) }
            let otherTargets = Set(appPaths
                + artifacts.filter { $0["suite"] != nil }.compactMap { targetPath(for: $0, kind: "suite") })
                .subtracting([app.path.path]).sorted()
            return .installed(HomebrewCask(brew: brew, token: token, version: installed,
                                           canRunInMClean: sameApplicationOnly, otherManagedPaths: otherTargets))
        }
    }

    static func uninstall(
        _ cask: HomebrewCask,
        runCommand: (URL, [String], TimeInterval) async throws -> BrewProcessOutput = run
    ) async throws {
        guard cask.canRunInMClean, isValidFullToken(cask.token),
              ApplicationUpdater.trustedBrewPaths.contains(cask.brew.path) else {
            throw RemovalError.changed
        }
        let output = try await runCommand(cask.brew, ["uninstall", "--cask", "--", cask.token], 180)
        guard output.status == 0 else {
            let detail = String(decoding: output.stderr.isEmpty ? output.stdout : output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemovalError.commandFailed(String(detail.prefix(1_200)))
        }
        let remaining = try await runCommand(cask.brew, ["list", "--cask", "--full-name"], 20)
        guard remaining.status == 0, let names = String(data: remaining.stdout, encoding: .utf8),
              !names.split(whereSeparator: \.isNewline).contains(Substring(cask.token)) else {
            throw RemovalError.incomplete
        }
    }

    static func command(for brew: URL, arguments: [String]) -> (URL, [String]) {
        #if arch(arm64)
        if brew.path == "/usr/local/bin/brew" {
            return (URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", brew.path] + arguments)
        }
        #else
        if brew.path == "/opt/homebrew/bin/brew" {
            return (URL(fileURLWithPath: "/usr/bin/arch"), ["-arm64", brew.path] + arguments)
        }
        #endif
        return (brew, arguments)
    }

    private static func run(_ brew: URL, _ arguments: [String], timeout: TimeInterval) async throws -> BrewProcessOutput {
        let (executable, options) = command(for: brew, arguments: arguments)
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment.removeValue(forKey: "HOMEBREW_CASK_OPTS")
        return try await BrewProcessRunner.run(executableURL: executable, arguments: options,
                                               timeout: timeout, environment: environment)
    }

    private static func caskRecords(in data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["casks"] as? [[String: Any]]
    }

    private static func installedFields(in record: [String: Any])
        -> (token: String, version: String, artifacts: [[String: Any]])? {
        guard let token = record["full_token"] as? String ?? record["token"] as? String,
              isValidFullToken(token), let version = record["installed"] as? String, !version.isEmpty,
              let artifacts = record["artifacts"] as? [[String: Any]] else { return nil }
        return (token, version, artifacts)
    }

    static func isValidFullToken(_ token: String) -> Bool {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        return (parts.count == 1 || parts.count == 3)
            && parts.allSatisfy { ApplicationUpdater.isValidCaskIdentifier(String($0)) }
    }

    private static func strings(from value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        return value as? [String] ?? []
    }

    private static func targetPath(for artifact: [String: Any], kind: String) -> String? {
        let options = (artifact[kind] as? [Any])?.compactMap { $0 as? [String: String] }.first
        guard let target = artifact["target"] as? String ?? options?["target"], target.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: target).standardizedFileURL.path
    }

    private static func canRemoveArtifact(_ artifact: [String: Any], app: AppInstallation) -> Bool {
        let ownedArtifacts: Set<String> = [
            "app", "target", "zap", "binary", "manpage", "bash_completion", "zsh_completion", "fish_completion",
        ]
        if Set(artifact.keys).isSubset(of: ownedArtifacts) { return true }
        guard Set(artifact.keys) == ["uninstall"], let directives = artifact["uninstall"] as? [[String: Any]],
              !directives.isEmpty else { return false }
        return directives.allSatisfy {
            Set($0.keys) == ["quit"] && strings(from: $0["quit"]) == [app.bundleIdentifier]
        }
    }

    enum RemovalError: LocalizedError, Equatable {
        case changed
        case commandFailed(String)
        case incomplete

        var errorDescription: String? {
            switch self {
            case .changed:
                return String(localized: "The installed package changed. Refresh before trying again.")
            case .commandFailed(let detail):
                let message = String(localized: "Homebrew could not finish. Try the Homebrew command in Terminal.")
                return detail.isEmpty ? message : message + "\n\n" + detail
            case .incomplete:
                return String(localized: "Homebrew finished, but the app or its cask is still present.")
            }
        }
    }
}
