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
    /// The directory could not be listed because macOS denied access; its size
    /// is whatever was reachable, possibly zero.
    var isAccessDenied: Bool = false
    private(set) var size: Int64
    /// Sorted descending by size. Contains directories and files at or above
    /// the engine's minNodeSize; smaller files are folded into `prunedSize`.
    private(set) var children: [SpaceLensNode]
    /// Files too small to earn their own node; their bytes are already
    /// included in `size`.
    let prunedCount: Int
    let prunedSize: Int64
    private(set) weak var parent: SpaceLensNode?

    init(url: URL, name: String? = nil, isDirectory: Bool, isPackage: Bool = false,
         size: Int64 = 0, children: [SpaceLensNode] = [],
         prunedCount: Int = 0, prunedSize: Int64 = 0) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.children = children
        self.prunedCount = prunedCount
        self.prunedSize = prunedSize
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
            cursor = current.parent
        }
    }
}
