import AppKit
import Darwin
import Foundation
import Security

enum AdobeUninstaller {
    static let photoshopIdentifier = "com.adobe.Photoshop"
    private static let uninstallerIdentifier = "com.adobe.HDUninstaller"
    private static let creativeCloudIdentifier = "com.adobe.acc.AdobeCreativeCloud"
    private static let teamIdentifier = "JQ525L2MZD"
    private static let uninstallDirectory = URL(fileURLWithPath: "/Library/Application Support/Adobe/Uninstall")
    private static let creativeCloudPath = URL(
        fileURLWithPath: "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
    )

    static func supports(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.caseInsensitiveCompare(photoshopIdentifier) == .orderedSame
    }

    @MainActor
    static func open(for appURL: URL, version: String?) async throws {
        let uninstaller = await Task.detached(priority: .userInitiated) {
            photoshopUninstaller(for: appURL, selectedVersion: version)
        }.value

        if let uninstaller {
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                // Adobe uses the same bundle ID for the uninstallers of different products.
                configuration.createsNewApplicationInstance = true
                _ = try await NSWorkspace.shared.openApplication(at: uninstaller, configuration: configuration)
                return
            } catch {
                Logger.shared.log("Could not open the Photoshop uninstaller: \(error.localizedDescription)", level: .warning)
            }
        }

        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: creativeCloudIdentifier)
        let creativeCloud = await Task.detached(priority: .userInitiated) {
            [creativeCloudPath, registered].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL }
                .first { hasAdobeSignature(at: $0, identifier: creativeCloudIdentifier) }
        }.value
        guard let creativeCloud else { throw LaunchError.creativeCloudUnavailable }
        _ = try await NSWorkspace.shared.openApplication(at: creativeCloud, configuration: .init())
    }

    static func photoshopUninstaller(
        for appURL: URL,
        selectedVersion: String?,
        uninstallDirectory: URL = uninstallDirectory,
        isTrusted: (URL, URL, URL, URL) -> Bool = isTrustedUninstaller
    ) -> URL? {
        // Read the plist again at launch time so an update since the scan can't
        // authorize the uninstaller of a different version.
        let appURL = appURL.resolvingSymlinksInPath().standardizedFileURL
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String,
              supports(identifier),
              let selectedVersion,
              let installedVersion = info["CFBundleShortVersionString"] as? String,
              let version = normalizedVersion(installedVersion),
              normalizedVersion(selectedVersion) == version else { return nil }

        let folder = appURL.deletingLastPathComponent()
        let names = Set([appURL.deletingPathExtension().lastPathComponent, folder.lastPathComponent])
        let aliasNames = Set(names.flatMap { ["Uninstall \($0)", "\($0) Uninstaller"] }).union(["Uninstall"])
        let root = uninstallDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var matches: Set<URL> = []

        for name in aliasNames {
            let alias = folder.appendingPathComponent(name)
            guard (try? alias.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
                  let resolved = try? URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
            else { continue }
            let target = resolved.resolvingSymlinksInPath().standardizedFileURL
            guard target.deletingLastPathComponent().path == root, target.pathExtension == "app" else { continue }

            let stem = target.deletingPathExtension().lastPathComponent
            let fields = stem.split(separator: "_", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields.first == "PHSP",
                  let platformCode = fields.last, Int(platformCode) != nil,
                  normalizedVersion(fields.dropFirst().dropLast().joined(separator: ".")) == version else { continue }

            // Adobe's signed uninstaller executable is shared across products. Its
            // sibling .adbarg selects the actual product and version to remove.
            let arguments = target.deletingPathExtension().appendingPathExtension("adbarg")
            guard isTrusted(appURL, alias, target, arguments),
                  let args = readArguments(at: arguments),
                  args["sapCode"] == "PHSP",
                  let platform = args["productPlatform"], ["macarm64", "macuniversal", "osx10"].contains(platform),
                  let productVersion = args["productVersion"], normalizedVersion(productVersion) == version,
                  args["productAdobeCode"]?.hasPrefix("{PHSP-\(productVersion)-\(platformCode)-") == true
            else { continue }
            matches.insert(target)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func normalizedVersion(_ text: String) -> [Int]? {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        guard components.count >= 2, numbers.count == components.count, let major = numbers.first, major > 0
        else { return nil }
        var version = numbers
        while version.count > 1, version.last == 0 { version.removeLast() }
        return version
    }

    private static func readArguments(at url: URL) -> [String: String]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 4_097), data.count <= 4_096,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var arguments: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].hasPrefix("--"), !fields[1].isEmpty else { return nil }
            let key = String(fields[0].dropFirst(2))
            guard arguments.updateValue(String(fields[1]), forKey: key) == nil else { return nil }
        }
        return arguments
    }

    private static func isTrustedUninstaller(_ photoshop: URL, _ alias: URL, _ app: URL, _ arguments: URL) -> Bool {
        let contents = app.appendingPathComponent("Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        var directory = app.deletingLastPathComponent()
        while directory.path != "/" {
            guard isRootManaged(directory, type: S_IFDIR) else { return false }
            directory.deleteLastPathComponent()
        }
        return [photoshop, photoshop.deletingLastPathComponent(), app, contents, binaries].allSatisfy {
            isRootManaged($0, type: S_IFDIR)
        }
            && [alias, arguments, binaries.appendingPathComponent("Uninstaller")].allSatisfy {
                isRootManaged($0, type: S_IFREG)
            }
            && hasAdobeSignature(at: app, identifier: uninstallerIdentifier)
    }

    private static func isRootManaged(_ url: URL, type: mode_t) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == type
            && metadata.st_uid == 0
            && metadata.st_mode & 0o022 == 0
            && !FileManager.default.isWritableFile(atPath: url.path)
    }

    private static func hasAdobeSignature(at url: URL, identifier: String) -> Bool {
        AppCodeSignature.isValid(at: url, requirement:
            "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\"")
    }

    private enum LaunchError: LocalizedError {
        case creativeCloudUnavailable

        var errorDescription: String? {
            String(localized: "A verified copy of Adobe Creative Cloud could not be found.")
        }
    }
}

enum AppCodeSignature {
    static func teamIdentifier(at url: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.utf8.count == 10,
              team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
        return team
    }

    static func isValid(at url: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var constraint: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &constraint) == errSecSuccess,
              let constraint else { return false }
        return SecStaticCodeCheckValidity(code, flags, constraint) == errSecSuccess
    }
}
