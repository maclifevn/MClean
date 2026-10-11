import Foundation

/// Shared SIP/immutability check used by both ScanEngine (so protected
/// entries never surface as cleanable items) and CleaningEngine (so a
/// protected survivor is reported as "skipped, protected by macOS" instead
/// of a scary removal error).
enum FileProtection {
    /// macOS's root aliases are expected; links introduced below them are not.
    static func hasUnexpectedSymlink(in path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var prefix = ""
        for component in url.pathComponents where component != "/" {
            prefix += "/" + component
            var metadata = stat()
            if lstat(prefix, &metadata) == 0,
               metadata.st_mode & S_IFMT == S_IFLNK,
               !["/tmp", "/var", "/etc"].contains(prefix) { return true }
        }
        return false
    }

    /// App matching may discover shared roots; those must never become removal targets.
    static func isProtectedUninstallPath(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if ProviderPaths.isProviderOwned(path) || isProtectedFromDeletion(path: path)
            || isCloudPlaceholder(at: url)
            || hasUnexpectedSymlink(in: url.path)
            || CleanupExclusions.excludes(path, paths: CleanupExclusions.paths()) { return true }
        let roots = ["/", "/Users", "/Volumes", "/Applications", "/Library", home,
                     "/opt", "/opt/homebrew", "/usr/local", "/usr/local/Homebrew",
                     "/opt/homebrew/Cellar", "/opt/homebrew/Caskroom",
                     "/usr/local/Cellar", "/usr/local/Caskroom",
                     home + "/Applications", home + "/Desktop", home + "/Documents", home + "/Downloads",
                     home + "/Library", home + "/Library/Application Support",
                     home + "/Library/Caches", home + "/Library/Containers", home + "/Library/Group Containers",
                     home + "/Library/Preferences", home + "/Library/Logs", home + "/Library/LaunchAgents",
                     "/Library/Application Support", "/Library/Caches", "/Library/Preferences",
                     "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/Logs"]
        if roots.contains(path) { return true }
        let trees = ["/System", "/bin", "/sbin", "/private", "/usr/bin", "/usr/sbin", "/usr/lib",
                     home + "/Library/Keychains", home + "/Library/Accounts", home + "/Library/Mail",
                     home + "/Library/Messages", home + "/Library/Calendars", home + "/Library/Safari"]
            + highRiskHomeDotPaths
        return trees.contains { path == $0 || path.hasPrefix($0 + "/") }
            || (path.hasPrefix("/Users/") && !path.hasPrefix(home + "/"))
    }

    static func isCloudPlaceholder(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "icloud" { return true }
        var metadata = stat()
        if lstat(url.path, &metadata) == 0, metadata.st_flags & 0x4000_0000 != 0 { return true }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return false }
        return values?.ubiquitousItemDownloadingStatus != .current
            && values?.ubiquitousItemDownloadingStatus != .downloaded
    }

    /// True when the entry is SIP-protected or immutable: BSD flags carry
    /// SF_RESTRICTED/SF_IMMUTABLE/UF_IMMUTABLE, or the path has the
    /// com.apple.rootless xattr. Deleting these fails even with admin
    /// privileges.
    static func isProtectedFromDeletion(path: String) -> Bool {
        var sb = stat()
        if lstat(path, &sb) == 0 {
            // SF_RESTRICTED (0x00080000) isn't exported by Darwin's Swift
            // overlay, so spell out the literal; the immutable flags are.
            let protectedFlags: UInt32 = 0x0008_0000 | UInt32(SF_IMMUTABLE) | UInt32(UF_IMMUTABLE)
            if sb.st_flags & protectedFlags != 0 {
                return true
            }
        }

        // SIP also marks paths with the com.apple.rootless xattr, which
        // can be present even when st_flags reads 0.
        let bufSize = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if bufSize > 0 {
            var buffer = [CChar](repeating: 0, count: bufSize)
            let read = listxattr(path, &buffer, bufSize, XATTR_NOFOLLOW)
            if read > 0 {
                let names = Data(bytes: &buffer, count: read)
                    .split(separator: 0)
                    .compactMap { String(data: $0, encoding: .utf8) }
                if names.contains("com.apple.rootless") {
                    return true
                }
            }
        }

        return false
    }
}
