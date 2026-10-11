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
    @Published var inaccessibleCount = 0
    @Published var skippedCount = 0
}

@MainActor
final class SpaceLensViewModel: ObservableObject {
    enum LensState: Equatable {
        case empty
        case scanning
        case ready
        case trashing
    }

    enum DisplayMode: String, CaseIterable, Identifiable {
        case map, list, combined
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .map: return "Map"
            case .list: return "List"
            case .combined: return "Combined"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case size, name
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .size ? "Size" : "Name" }
    }

    @Published var displayMode: DisplayMode {
        didSet { preferences.set(displayMode.rawValue, forKey: "MClean.SpaceLens.DisplayMode") }
    }
    @Published var sortOrder: SortOrder = .size
    @Published private(set) var includesSmallFiles = false
    @Published private(set) var scanningURL: URL?
    @Published var state: LensState = .empty
    @Published var rootNode: SpaceLensNode?
    /// Breadcrumb trail below the root; the displayed node is `path.last`,
    /// falling back to the root itself.
    @Published var path: [SpaceLensNode] = []
    @Published var selection: Set<UUID> = []
    @Published var lastError: String?
    let ticker = ScanProgressTicker()
    let progress = SpaceLensScanProgress()

    typealias ScanHandler = @Sendable (URL, Int64, @escaping @Sendable (SpaceLensEngine.Progress) -> Void) async throws -> SpaceLensNode
    private let scanHandler: ScanHandler
    private let cleaningEngine: CleaningEngine
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard, cleaningEngine: CleaningEngine = CleaningEngine(), scanHandler: ScanHandler? = nil) {
        self.preferences = preferences
        self.cleaningEngine = cleaningEngine
        displayMode = DisplayMode(rawValue: preferences.string(forKey: "MClean.SpaceLens.DisplayMode") ?? "") ?? .combined
        let engine = SpaceLensEngine()
        self.scanHandler = scanHandler ?? { url, minimum, progress in
            try await engine.scan(root: url, minNodeSize: minimum, onProgress: progress)
        }
    }
    private var scanGeneration = UUID()
    private var scanTask: Task<Void, Never>?

    var currentNode: SpaceLensNode? { path.last ?? rootNode }

    var canGoBack: Bool { !path.isEmpty && state == .ready }

    var visibleChildren: [SpaceLensNode] {
        let children = currentNode?.children ?? []
        guard sortOrder == .name else { return children }
        return children.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

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
        panel.title = String(localized: "Choose a folder to inspect")
        panel.message = String(localized: "Scan locally, then review items before moving them to the Trash.")
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = String(localized: "Scan")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }

    func scanHomeFolder() {
        scan(FileManager.default.homeDirectoryForCurrentUser)
    }

    func scan(_ url: URL) {
        startScan(url, includeSmallFiles: false, restorePath: [])
    }

    func rescan() {
        guard let rootNode, state == .ready else { return }
        startScan(rootNode.url, includeSmallFiles: includesSmallFiles, restorePath: path.map(\.url))
    }

    func showSmallerItems() {
        guard let rootNode, state == .ready, !includesSmallFiles else { return }
        startScan(rootNode.url, includeSmallFiles: true, restorePath: path.map(\.url))
    }

    private func startScan(_ url: URL, includeSmallFiles: Bool, restorePath: [URL]) {
        guard state != .trashing else { return }
        scanTask?.cancel()
        state = .scanning
        scanningURL = url
        selection = []
        progress.bytes = 0
        progress.items = 0
        progress.inaccessibleCount = 0
        progress.skippedCount = 0
        lastError = nil
        ticker.path = ""

        let generation = UUID()
        scanGeneration = generation
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let root = try await self.scanHandler(url, includeSmallFiles ? 0 : 1_048_576) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanGeneration == generation, self.state == .scanning else { return }
                        self.progress.bytes = update.scannedBytes
                        self.progress.items = update.itemCount
                        self.progress.inaccessibleCount = update.inaccessibleCount
                        self.progress.skippedCount = update.skippedCount
                        if !update.currentPath.isEmpty { self.ticker.path = update.currentPath }
                    }
                }
                guard !Task.isCancelled, self.scanGeneration == generation else { return }
                self.rootNode = root
                self.path = []
                var current = root
                for url in restorePath {
                    guard let child = current.children.first(where: { $0.url == url && $0.isDirectory && !$0.isPackage }) else { break }
                    self.path.append(child)
                    current = child
                }
                self.includesSmallFiles = includeSmallFiles
                self.scanningURL = nil
                self.state = .ready
                Haptics.success()
            } catch is CancellationError {
                // cancelScan restores the previous completed tree.
            } catch {
                guard self.scanGeneration == generation else { return }
                self.lastError = error.localizedDescription
                self.scanningURL = nil
                self.state = self.rootNode == nil ? .empty : .ready
            }
        }
    }

    func cancelScan() {
        guard state == .scanning else { return }
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanningURL = nil
        state = rootNode == nil ? .empty : .ready
    }

    // MARK: - Navigation

    func drill(into node: SpaceLensNode) {
        guard state == .ready, node.isDirectory, !node.isPackage,
              currentNode?.children.contains(where: { $0.id == node.id }) == true else { return }
        path.append(node)
        selection = []
    }

    /// Pop back to `node`; nil pops all the way to the scan root.
    func pop(to node: SpaceLensNode?) {
        guard state == .ready else { return }
        if let node, let index = path.firstIndex(where: { $0.id == node.id }) {
            path.removeSubrange(path.index(after: index)...)
        } else {
            path = []
        }
        selection = []
    }

    func goBack() {
        guard canGoBack else { return }
        path.removeLast()
        selection = []
    }

    func toggleSelection(_ node: SpaceLensNode) {
        guard state == .ready, currentNode?.children.contains(where: { $0.id == node.id }) == true else { return }
        if selection.contains(node.id) { selection.remove(node.id) }
        else { selection.insert(node.id) }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Deletion

    func trashSelection() async {
        await trash(selectedNodes)
    }

    /// The confirmation passes a frozen batch. Navigation cannot substitute
    /// other selected items while that confirmation is open.
    func trash(_ nodes: [SpaceLensNode]) async {
        guard state == .ready, let parent = currentNode, !nodes.isEmpty,
              nodes.allSatisfy({ node in parent.children.contains { $0.id == node.id } }) else { return }

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
