import Foundation

/// One file or directory in the Space Lens size tree.
///
/// A reference type on purpose: the tree can hold hundreds of thousands of
/// nodes and drill-down/deletion mutate it in place (removing a child
/// propagates its size up the parent chain) without copying subtrees.
/// Built off the main thread by SpaceLensEngine, then handed to the main
/// actor and only mutated there — hence @unchecked Sendable.
final class SpaceLensNode: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Packages (.app and friends) size their contents but expose no
    /// children — they drill like a single file, matching Finder semantics.
    let isPackage: Bool
    /// The directory could not be listed (missing Full Disk Access or POSIX
    /// permissions); its size is whatever was reachable, possibly zero.
    var isAccessDenied: Bool = false
    private(set) var size: Int64
    /// All directories are navigable; small files fold into `prunedSize`
    /// until the user requests a detailed scan of this folder.
    private(set) var children: [SpaceLensNode]
    /// Files too small to earn their own node; their bytes are already
    /// included in `size`.
    private(set) var prunedCount: Int
    private(set) var prunedSize: Int64
    private(set) var ownSize: Int64
    private(set) var fileCount: Int
    /// Includes this directory (and directories inside packages).
    private(set) var directoryCount: Int
    private(set) var inaccessibleCount: Int
    private(set) var skippedCount: Int
    var isPartial: Bool { inaccessibleCount > 0 || skippedCount > 0 }
    private(set) weak var parent: SpaceLensNode?

    init(url: URL, name: String? = nil, isDirectory: Bool, isPackage: Bool = false,
         size: Int64 = 0, children: [SpaceLensNode] = [],
         prunedCount: Int = 0, prunedSize: Int64 = 0,
         ownSize: Int64 = 0, fileCount: Int = 0, directoryCount: Int = 0,
         inaccessibleCount: Int = 0, skippedCount: Int = 0) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.children = children
        self.prunedCount = prunedCount
        self.prunedSize = prunedSize
        self.ownSize = ownSize
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.inaccessibleCount = inaccessibleCount
        self.skippedCount = skippedCount
        for child in children { child.parent = self }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Fraction of the parent's size this node accounts for (0 when unknown).
    var shareOfParent: Double {
        guard let parent, parent.size > 0 else { return 0 }
        return Double(size) / Double(parent.size)
    }

    /// Breadcrumb chain from the scan root down to this node (inclusive).
    var pathComponentsFromRoot: [SpaceLensNode] {
        var chain: [SpaceLensNode] = [self]
        var cursor = parent
        while let node = cursor {
            chain.append(node)
            cursor = node.parent
        }
        return chain.reversed()
    }

    /// Detach a child after it was moved to the Trash, subtracting its size
    /// from every ancestor so the bubbles and badges stay truthful.
    func removeChild(_ node: SpaceLensNode) {
        guard let index = children.firstIndex(where: { $0.id == node.id }) else { return }
        children.remove(at: index)
        var cursor: SpaceLensNode? = self
        while let current = cursor {
            current.size -= node.size
            current.fileCount -= node.fileCount
            current.directoryCount -= node.directoryCount
            current.inaccessibleCount -= node.inaccessibleCount
            current.skippedCount -= node.skippedCount
            cursor = current.parent
        }
        node.parent = nil
    }

}
