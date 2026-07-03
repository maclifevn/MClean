import AppKit
import SwiftUI

/// State for the Space Lens disk visualizer. Held as a plain `let` on
/// AppState (deliberately not `@Published`, same isolation rationale as
/// `scanTicker` — issues #119, #120): scan progress updates several times a
/// second and must re-render only the Space Lens surfaces, not the whole
/// AppState-observing view tree. Living on AppState rather than in the view
/// also survives MainWindow's `.id(selectedSection)` teardown, so a running
/// scan keeps going while the user visits other sections.
/// High-frequency scan counters, isolated from SpaceLensViewModel for the
/// same reason ScanProgressTicker exists: they update ~10×/sec during a scan
/// and only the small progress readout should re-render at that rate. This
/// keeps SpaceLensViewModel's own publishes low-frequency, so the sidebar
/// row can observe it safely.
@MainActor
final class SpaceLensScanProgress: ObservableObject {
    @Published var bytes: Int64 = 0
    @Published var items: Int = 0
}

@MainActor
final class SpaceLensViewModel: ObservableObject {
    enum LensState: Equatable {
        case empty
        case scanning
        case ready
        case trashing
    }

    @Published var state: LensState = .empty
    @Published var rootNode: SpaceLensNode?
    /// Breadcrumb trail below the root; the displayed node is `path.last`,
    /// falling back to the root itself.
    @Published var path: [SpaceLensNode] = []
    @Published var selection: Set<UUID> = []
    @Published var lastError: String?
    let ticker = ScanProgressTicker()
    let progress = SpaceLensScanProgress()

    private let engine = SpaceLensEngine()
    private let cleaningEngine = CleaningEngine()
    private var scanTask: Task<Void, Never>?

    var currentNode: SpaceLensNode? { path.last ?? rootNode }

    var selectedNodes: [SpaceLensNode] {
        currentNode?.children.filter { selection.contains($0.id) } ?? []
    }

    var selectedSize: Int64 {
        selectedNodes.reduce(0) { $0 + $1.size }
    }

    // MARK: - Scanning

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = String(localized: "Scan")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }

    func scanHomeFolder() {
        let access = SandboxAccessManager.shared
        guard access.hasFullScanAccess || access.requestFullScanAccess() else { return }
        scan(SandboxAccessManager.homeURL)
    }

    func scan(_ url: URL) {
        scanTask?.cancel()
        state = .scanning
        rootNode = nil
        path = []
        selection = []
        progress.bytes = 0
        progress.items = 0
        lastError = nil
        ticker.path = ""

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let root = try await self.engine.scan(root: url) { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.state == .scanning else { return }
                        self.progress.bytes = update.scannedBytes
                        self.progress.items = update.itemCount
                        if !update.currentPath.isEmpty {
                            self.ticker.path = update.currentPath
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                self.rootNode = root
                self.state = .ready
                Haptics.success()
            } catch is CancellationError {
                // Cancelled scans fall back to whatever state cancelScan set.
            } catch {
                self.lastError = error.localizedDescription
                self.state = .empty
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        state = rootNode == nil ? .empty : .ready
    }

    // MARK: - Navigation

    func drill(into node: SpaceLensNode) {
        guard node.isDirectory, !node.isPackage else { return }
        path.append(node)
        selection = []
    }

    /// Pop back to `node`; nil pops all the way to the scan root.
    func pop(to node: SpaceLensNode?) {
        if let node, let index = path.firstIndex(where: { $0.id == node.id }) {
            path.removeSubrange(path.index(after: index)...)
        } else {
            path = []
        }
        selection = []
    }

    // MARK: - Deletion

    func trashSelection() async {
        guard let parent = currentNode else { return }
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return }

        state = .trashing
        let result = await cleaningEngine.trashItems(nodes.map { ($0.url, $0.size) })

        for node in nodes where result.trashedPaths.contains(node.url.path) {
            parent.removeChild(node)
        }
        selection = []
        state = .ready
        if result.errors.isEmpty {
            Haptics.success()
        } else {
            lastError = result.errors.joined(separator: "\n")
        }
        // Trigger republish of the mutated tree — node mutation alone is
        // invisible to SwiftUI because SpaceLensNode is a reference type.
        objectWillChange.send()
    }
}
