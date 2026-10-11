import Darwin
import Foundation

enum SpaceLensScanError: LocalizedError, Equatable {
    case notDirectory(String)
    case symbolicLink(String)
    case package(String)
    case cloudOnly(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let path):
            return String(localized: "The selected item is not a folder: \(path)")
        case .symbolicLink(let path):
            return String(localized: "Symbolic links cannot be scanned: \(path)")
        case .package(let path):
            return String(localized: "App and document packages are excluded: \(path)")
        case .cloudOnly(let path):
            return String(localized: "The selected folder is stored in the cloud and has not been downloaded: \(path)")
        case .unavailable(let path):
            return String(localized: "The selected folder could not be read: \(path)")
        }
    }
}

/// One allocated-size tree powers the map, list and combined view. Directory
/// nodes remain navigable at every size; small files are grouped by default.
/// A full-detail scan can retain them when explicitly requested by the user.
actor SpaceLensEngine {
    struct Progress: Sendable {
        let scannedBytes: Int64
        let itemCount: Int
        let currentPath: String
        let inaccessibleCount: Int
        let skippedCount: Int
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64 = 0
        private var items = 0
        private var inaccessible = 0
        private var skipped = 0
        private var lastReport = Date.distantPast
        private var seenHardLinks: Set<FileIdentity> = []
        private let onProgress: @Sendable (Progress) -> Void

        init(onProgress: @escaping @Sendable (Progress) -> Void) {
            self.onProgress = onProgress
        }

        func record(bytes: Int64 = 0, items: Int = 0, inaccessible: Int = 0,
                    skipped: Int = 0, path: String, force: Bool = false) {
            lock.lock()
            self.bytes += bytes
            self.items += items
            self.inaccessible += inaccessible
            self.skipped += skipped
            let now = Date()
            let report = force || now.timeIntervalSince(lastReport) > 0.1
            if report { lastReport = now }
            let snapshot = Progress(scannedBytes: self.bytes, itemCount: self.items,
                                    currentPath: path, inaccessibleCount: self.inaccessible,
                                    skippedCount: self.skipped)
            lock.unlock()
            if report { onProgress(snapshot) }
        }

        func claim(_ metadata: stat) -> Bool {
            guard metadata.st_nlink > 1 else { return true }
            lock.lock()
            defer { lock.unlock() }
            return seenHardLinks.insert(FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)).inserted
        }
    }

    private struct Measurement {
        var node: SpaceLensNode?
        var skipped = 0
        var inaccessible = 0
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]

    func scan(root selectedURL: URL, minNodeSize: Int64 = 1_048_576,
              onProgress: @escaping @Sendable (Progress) -> Void) async throws -> SpaceLensNode {
        try Task.checkCancellation()
        let root = selectedURL.standardizedFileURL
        guard let metadata = Self.metadata(at: root) else { throw SpaceLensScanError.unavailable(root.path) }
        guard metadata.st_mode & S_IFMT != S_IFLNK else { throw SpaceLensScanError.symbolicLink(root.path) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw SpaceLensScanError.notDirectory(root.path) }
        guard !Self.isDataless(metadata) else { throw SpaceLensScanError.cloudOnly(root.path) }
        guard let values = try? root.resourceValues(forKeys: Self.resourceKeys) else {
            throw SpaceLensScanError.unavailable(root.path)
        }
        guard !Self.isCloudOnly(values) else { throw SpaceLensScanError.cloudOnly(root.path) }
        guard values.isPackage != true, root.pathExtension != "app" else { throw SpaceLensScanError.package(root.path) }

        let progress = ProgressBox(onProgress: onProgress)
        let ownSize = Self.allocatedBytes(metadata: metadata, values: values)
        progress.record(bytes: ownSize, items: 1, path: root.path)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Array(Self.resourceKeys), options: []
            )
        } catch {
            progress.record(inaccessible: 1, path: root.path, force: true)
            let node = SpaceLensNode(url: root, isDirectory: true, size: ownSize,
                                     ownSize: ownSize, directoryCount: 1, inaccessibleCount: 1)
            node.isAccessDenied = true
            return node
        }

        // A single bounded fan-out; recursive traversals do no actor hops.
        var measurements: [Measurement] = []
        try await withThrowingTaskGroup(of: Measurement.self) { group in
            var pending = entries.sorted { $0.path < $1.path }.makeIterator()
            let cap = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount))
            func submitNext() -> Bool {
                guard let entry = pending.next() else { return false }
                group.addTask { try Self.measure(at: entry, minNodeSize: minNodeSize, expand: true, progress: progress) }
                return true
            }
            for _ in 0..<cap { if !submitNext() { break } }
            while let result = try await group.next() {
                measurements.append(result)
                _ = submitNext()
            }
        }
        try Task.checkCancellation()
        let node = Self.makeDirectory(at: root, ownSize: ownSize, measurements: measurements,
                                      minNodeSize: minNodeSize, expand: true, isPackage: false)
        progress.record(path: root.path, force: true)
        return node
    }

    private static func measure(at url: URL, minNodeSize: Int64, expand: Bool,
                                progress: ProgressBox) throws -> Measurement {
        try Task.checkCancellation()
        guard let metadata = metadata(at: url) else {
            progress.record(inaccessible: 1, path: url.path)
            return Measurement(inaccessible: 1)
        }
        let kind = metadata.st_mode & S_IFMT
        guard kind != S_IFLNK, !isDataless(metadata), kind == S_IFDIR || kind == S_IFREG else {
            progress.record(skipped: 1, path: url.path)
            return Measurement(skipped: 1)
        }
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
            progress.record(inaccessible: 1, path: url.path)
            return Measurement(inaccessible: 1)
        }
        guard !isCloudOnly(values) else {
            progress.record(skipped: 1, path: url.path)
            return Measurement(skipped: 1)
        }
        guard kind != S_IFREG || progress.claim(metadata) else {
            progress.record(skipped: 1, path: url.path)
            return Measurement(skipped: 1)
        }
        let ownSize = allocatedBytes(metadata: metadata, values: values)
        progress.record(bytes: ownSize, items: 1, path: url.path)
        if kind == S_IFREG {
            return Measurement(node: SpaceLensNode(url: url, isDirectory: false,
                                                  size: ownSize, ownSize: ownSize, fileCount: 1))
        }
        let isPackage = values.isPackage == true || url.pathExtension == "app"
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(resourceKeys), options: []
            )
        } catch {
            progress.record(inaccessible: 1, path: url.path)
            let node = SpaceLensNode(url: url, isDirectory: true, isPackage: isPackage, size: ownSize,
                                     ownSize: ownSize, directoryCount: 1, inaccessibleCount: 1)
            node.isAccessDenied = true
            return Measurement(node: node)
        }
        var measurements: [Measurement] = []
        for entry in entries {
            measurements.append(try measure(at: entry, minNodeSize: minNodeSize,
                                            expand: expand && !isPackage, progress: progress))
        }
        return Measurement(node: makeDirectory(at: url, ownSize: ownSize, measurements: measurements,
                                              minNodeSize: minNodeSize, expand: expand && !isPackage,
                                              isPackage: isPackage))
    }

    private static func makeDirectory(at url: URL, ownSize: Int64, measurements: [Measurement],
                                      minNodeSize: Int64, expand: Bool, isPackage: Bool) -> SpaceLensNode {
        var children: [SpaceLensNode] = []
        var size = ownSize
        var files = 0
        var directories = 1
        var skipped = 0
        var inaccessible = 0
        var prunedCount = 0
        var prunedSize: Int64 = 0
        for measurement in measurements {
            skipped += measurement.skipped
            inaccessible += measurement.inaccessible
            guard let child = measurement.node else { continue }
            size += child.size
            files += child.fileCount
            directories += child.directoryCount
            skipped += child.skippedCount
            inaccessible += child.inaccessibleCount
            if expand && (child.isDirectory || child.isPackage || child.size >= minNodeSize) {
                children.append(child)
            } else if expand {
                prunedCount += 1
                prunedSize += child.size
            }
        }
        children.sort {
            $0.size == $1.size ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.size > $1.size
        }
        return SpaceLensNode(url: url, isDirectory: true, isPackage: isPackage, size: size, children: children,
                             prunedCount: prunedCount, prunedSize: prunedSize, ownSize: ownSize,
                             fileCount: files, directoryCount: directories,
                             inaccessibleCount: inaccessible, skippedCount: skipped)
    }

    private static func metadata(at url: URL) -> stat? {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        return result == 0 ? metadata : nil
    }

    private static func allocatedBytes(metadata: stat, values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? max(0, Int(metadata.st_blocks)) * 512)
    }

    private static func isDataless(_ metadata: stat) -> Bool { metadata.st_flags & UInt32(SF_DATALESS) != 0 }

    private static func isCloudOnly(_ values: URLResourceValues) -> Bool {
        values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
            && values.ubiquitousItemDownloadingStatus != .downloaded
    }
}
