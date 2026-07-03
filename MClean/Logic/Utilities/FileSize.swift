import Foundation

/// Allocated-size calculation that works for both files and directories.
///
/// `URLResourceValues.totalFileAllocatedSize` does **not** recurse: on a
/// directory URL it returns only the directory inode's own allocation
/// (~96 bytes to a few KB on APFS), not the sum of the bundle's contents.
/// Reading it directly on an `.app` bundle or a support folder is what made
/// items display as a handful of bytes. For directories we enumerate and sum
/// the regular files instead.
enum FileSizeCalculator {
    private static let fileManager = FileManager.default

    /// On-disk allocated size of `url`. Recurses into directories.
    /// Returns `nil` if the item can't be read at all.
    static func size(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // Treat a symlink as a file (size of the link itself), never recursing
        // into its target. `.isDirectoryKey` resolves symlinks, so without this
        // guard a top-level symlink-to-directory would be walked as the target's
        // full tree — inflating the size, escaping the item's real footprint,
        // and mismatching deletion (removeItem deletes only the link). Check
        // isSymbolicLink first so the directory branch only sees real dirs.
        if values?.isSymbolicLink != true, values?.isDirectory == true {
            return directorySize(of: url)
        }
        return fileSize(of: url)
    }

    private static func fileSize(of url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let size = values.totalFileAllocatedSize {
            return Int64(size)
        }
        if let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]),
           let size = values.fileAllocatedSize {
            return Int64(size)
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        return size
    }

    private static func directorySize(of url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            // Skip symlinks so we don't double-count or follow links that
            // escape the directory. Only sum regular-file payload.
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            if let allocated = values.totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let allocated = values.fileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
    }
}
