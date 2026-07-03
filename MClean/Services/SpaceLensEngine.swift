import Foundation

/// Builds the Space Lens size tree: one full recursive pass over a chosen
/// folder, sizing every file and keeping nodes only for directories and
/// files at or above `minNodeSize` (smaller files fold into their parent's
/// pruned tally). Full scan over lazy expansion because top-level folder
/// sizes require walking everything underneath anyway; pruning is what
/// bounds memory, not laziness.
actor SpaceLensEngine {
    struct Progress: Sendable {
        let scannedBytes: Int64
        let itemCount: Int
        let currentPath: String
    }

    /// Byte and item counters shared across the per-directory scan tasks,
    /// plus the ~10 Hz throttle gate for progress callbacks (same cadence as
    /// ScanEngine's path reporter).
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var scannedBytes: Int64 = 0
        private var itemCount = 0
        private var lastReport = Date.distantPast
        private let onProgress: @Sendable (Progress) -> Void
        /// Inodes of multi-link files already counted, so hard links don't
        /// inflate totals. Only files with linkCount > 1 are tracked — the
        /// set stays tiny.
        private var seenHardLinks = Set<NSObject>()

        init(onProgress: @escaping @Sendable (Progress) -> Void) {
            self.onProgress = onProgress
        }

        func add(bytes: Int64, path: @autoclosure () -> String) {
            lock.lock()
            scannedBytes += bytes
            itemCount += 1
            let now = Date()
            let shouldReport = now.timeIntervalSince(lastReport) > 0.1
            if shouldReport { lastReport = now }
            let snapshot = Progress(scannedBytes: scannedBytes, itemCount: itemCount,
                                    currentPath: shouldReport ? path() : "")
            lock.unlock()
            if shouldReport { onProgress(snapshot) }
        }

        /// Returns false when this multi-link inode was already counted.
        func claimHardLink(_ identifier: NSObject) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return seenHardLinks.insert(identifier).inserted
        }
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .linkCountKey, .fileResourceIdentifierKey,
    ]

    /// Scan `root` and return its tree. Hidden files are included — finding
    /// space is the point. Symlinks are counted as the link itself, never
    /// followed. Throws CancellationError when the surrounding task is
    /// cancelled.
    func scan(root: URL,
              minNodeSize: Int64 = 1_048_576,
              onProgress: @escaping @Sendable (Progress) -> Void) async throws -> SpaceLensNode {
        let progress = ProgressBox(onProgress: onProgress)
        let fileManager = FileManager.default

        // Fan out across the root's immediate subdirectories, capped at the
        // core count in flight; loose files at the root are handled inline.
        var subdirectories: [URL] = []
        var looseEntries: [URL] = []
        var rootDenied = false
        do {
            for entry in try fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Self.resourceKeys, options: []
            ) {
                let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                ])
                let isRealDirectory = (values?.isDirectory ?? false)
                    && !(values?.isSymbolicLink ?? false)
                    && !(values?.isPackage ?? false)
                    && entry.pathExtension != "app"
                if isRealDirectory {
                    subdirectories.append(entry)
                } else {
                    looseEntries.append(entry)
                }
            }
        } catch {
            rootDenied = true
        }

        var childNodes: [SpaceLensNode] = []
        var pruned = (count: 0, size: Int64(0))

        try await withThrowingTaskGroup(of: SpaceLensNode.self) { group in
            var pending = subdirectories.makeIterator()
            var inFlight = 0
            let cap = max(2, ProcessInfo.processInfo.activeProcessorCount)

            func submitNext() {
                guard let dir = pending.next() else { return }
                inFlight += 1
                group.addTask {
                    try Self.buildTree(at: dir, minNodeSize: minNodeSize,
                                       progress: progress)
                }
            }
            for _ in 0..<cap { submitNext() }
            while inFlight > 0 {
                guard let node = try await group.next() else { break }
                inFlight -= 1
                childNodes.append(node)
                submitNext()
            }
        }

        for entry in looseEntries {
            try Task.checkCancellation()
            let (bytes, node) = Self.sizeLeaf(at: entry, minNodeSize: minNodeSize,
                                              progress: progress)
            if let node {
                childNodes.append(node)
            } else {
                pruned.count += 1
                pruned.size += bytes
            }
        }

        childNodes.sort { $0.size > $1.size }
        let totalSize = childNodes.reduce(pruned.size) { $0 + $1.size }
        let rootNode = SpaceLensNode(
            url: root, isDirectory: true,
            size: totalSize, children: childNodes,
            prunedCount: pruned.count, prunedSize: pruned.size
        )
        rootNode.isAccessDenied = rootDenied
        return rootNode
    }

    // MARK: - Traversal (runs on task-group threads, no actor hops)

    /// Synchronous depth-first build of one directory subtree.
    private static func buildTree(at url: URL, minNodeSize: Int64,
                                  progress: ProgressBox) throws -> SpaceLensNode {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        var children: [SpaceLensNode] = []
        var prunedCount = 0
        var prunedSize: Int64 = 0
        var denied = false

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: resourceKeys, options: []
            )
        } catch {
            entries = []
            denied = true
        }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(resourceKeys)) else {
                continue
            }
            let isSymlink = values.isSymbolicLink ?? false
            let isPackage = (values.isPackage ?? false) || entry.pathExtension == "app"

            // Symlink check must precede isDirectory: a symlink to a
            // directory reports isDirectory == true and following it would
            // double-count (or loop).
            if !isSymlink, values.isDirectory ?? false, !isPackage {
                children.append(try buildTree(at: entry, minNodeSize: minNodeSize,
                                              progress: progress))
                continue
            }

            let bytes: Int64
            if !isSymlink, isPackage, values.isDirectory ?? false {
                bytes = try packageSize(at: entry, progress: progress)
            } else {
                bytes = fileBytes(values: values, progress: progress)
            }
            progress.add(bytes: bytes, path: entry.path)

            if bytes >= minNodeSize {
                children.append(SpaceLensNode(url: entry, isDirectory: false,
                                              isPackage: isPackage, size: bytes))
            } else {
                prunedCount += 1
                prunedSize += bytes
            }
        }

        children.sort { $0.size > $1.size }
        let node = SpaceLensNode(
            url: url, isDirectory: true,
            size: children.reduce(prunedSize) { $0 + $1.size },
            children: children,
            prunedCount: prunedCount, prunedSize: prunedSize
        )
        node.isAccessDenied = denied
        return node
    }

    /// Recursive size of a package bundle — contents counted, no child nodes.
    private static func packageSize(at url: URL, progress: ProgressBox) throws -> Int64 {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        var total: Int64 = 0
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: resourceKeys, options: []
        ) else { return 0 }
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(resourceKeys)) else {
                continue
            }
            if !(values.isSymbolicLink ?? false), values.isDirectory ?? false {
                total += try packageSize(at: entry, progress: progress)
            } else {
                total += fileBytes(values: values, progress: progress)
            }
        }
        return total
    }

    /// Allocated bytes for one non-directory entry, deduplicating hard links.
    private static func fileBytes(values: URLResourceValues,
                                  progress: ProgressBox) -> Int64 {
        if (values.linkCount ?? 1) > 1,
           let identifier = values.fileResourceIdentifier as? NSObject,
           !progress.claimHardLink(identifier) {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    /// Size a loose root-level entry (file, symlink, or package). Returns the
    /// measured bytes plus a node when the entry clears the size threshold;
    /// below the threshold the caller folds the bytes into the pruned tally.
    private static func sizeLeaf(at url: URL, minNodeSize: Int64,
                                 progress: ProgressBox) -> (bytes: Int64, node: SpaceLensNode?) {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
            return (0, nil)
        }
        let isSymlink = values.isSymbolicLink ?? false
        let isPackage = (values.isPackage ?? false) || url.pathExtension == "app"
        let bytes: Int64
        if !isSymlink, isPackage, values.isDirectory ?? false {
            bytes = (try? packageSize(at: url, progress: progress)) ?? 0
        } else {
            bytes = fileBytes(values: values, progress: progress)
        }
        progress.add(bytes: bytes, path: url.path)
        guard bytes >= minNodeSize else { return (bytes, nil) }
        return (bytes, SpaceLensNode(url: url, isDirectory: false,
                                     isPackage: isPackage, size: bytes))
    }
}
