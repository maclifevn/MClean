import XCTest
@testable import MClean

@MainActor
final class SpaceLensViewModelTests: XCTestCase {
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "MClean.SpaceLensTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        preferences.removePersistentDomain(forName: suite)
    }

    private func tree(at url: URL = URL(fileURLWithPath: "/fixture")) -> SpaceLensNode {
        let large = SpaceLensNode(url: url.appendingPathComponent("z-large.bin"), isDirectory: false, size: 50, fileCount: 1)
        let small = SpaceLensNode(url: url.appendingPathComponent("a-small.bin"), isDirectory: false, size: 10, fileCount: 1)
        let folder = SpaceLensNode(url: url.appendingPathComponent("folder"), isDirectory: true,
                                  size: 60, children: [large, small], fileCount: 2, directoryCount: 1)
        return SpaceLensNode(url: url, isDirectory: true, size: 60, children: [folder], fileCount: 2, directoryCount: 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for Space Lens")
        throw NSError(domain: "SpaceLensTests", code: 1)
    }

    func testModeAndSortKeepCurrentFolderAndSelection() throws {
        let model = SpaceLensViewModel(preferences: preferences)
        let root = tree()
        model.rootNode = root
        model.state = .ready
        let folder = try XCTUnwrap(root.children.first)
        model.drill(into: folder)
        let file = try XCTUnwrap(folder.children.first)
        model.toggleSelection(file)
        model.displayMode = .list
        model.sortOrder = .name
        XCTAssertEqual(model.currentNode?.id, folder.id)
        XCTAssertEqual(model.selection, [file.id])
        XCTAssertEqual(model.selectedSize, 50)
        XCTAssertEqual(model.visibleChildren.map(\.name), ["a-small.bin", "z-large.bin"])
        model.displayMode = .map
        XCTAssertEqual(model.selection, [file.id])
        XCTAssertEqual(SpaceLensViewModel(preferences: preferences).displayMode, .map)
    }

    func testBackClearsSelectionAndForeignFolderCannotBeOpened() throws {
        let model = SpaceLensViewModel(preferences: preferences)
        let root = tree()
        model.rootNode = root
        model.state = .ready
        model.drill(into: tree(at: URL(fileURLWithPath: "/unrelated")))
        XCTAssertTrue(model.path.isEmpty)
        let folder = try XCTUnwrap(root.children.first)
        model.drill(into: folder)
        model.toggleSelection(try XCTUnwrap(folder.children.first))
        XCTAssertTrue(model.canGoBack)
        model.goBack()
        XCTAssertEqual(model.currentNode?.id, root.id)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.canGoBack)
    }

    func testFullDetailRescanRestoresBreadcrumbAndUsesSameTreeForBothModes() async throws {
        let rootURL = URL(fileURLWithPath: "/fixture")
        let gate = LensScanGate()
        let model = SpaceLensViewModel(preferences: preferences, scanHandler: { url, minimum, progress in
            try await gate.scan(url, minimum: minimum, progress: progress)
        })
        model.rootNode = tree(at: rootURL)
        model.state = .ready
        model.drill(into: try XCTUnwrap(model.rootNode?.children.first))
        model.displayMode = .list
        model.showSmallerItems()
        try await waitForRequests(gate, count: 1)
        let request = await gate.requests[0]
        XCTAssertEqual(request.url, rootURL)
        XCTAssertEqual(request.minimum, 0)
        let replacement = tree(at: rootURL)
        await gate.finish(0, node: replacement)
        try await waitUntil { model.state == .ready }
        XCTAssertTrue(model.includesSmallFiles)
        XCTAssertEqual(model.currentNode?.url, rootURL.appendingPathComponent("folder"))
        XCTAssertEqual(model.rootNode?.id, replacement.id)
        XCTAssertEqual(model.displayMode, .list)
        model.rescan()
        try await waitForRequests(gate, count: 2)
        let second = await gate.requests[1]
        XCTAssertEqual(second.minimum, 0)
        await gate.finish(1, node: tree(at: rootURL))
        try await waitUntil { model.state == .ready }
    }

    func testCancelledScanCannotOverwriteNewScanOrProgress() async throws {
        let gate = LensScanGate()
        let model = SpaceLensViewModel(preferences: preferences, scanHandler: { url, minimum, progress in
            try await gate.scan(url, minimum: minimum, progress: progress)
        })
        model.scan(URL(fileURLWithPath: "/old"))
        try await waitForRequests(gate, count: 1)
        model.cancelScan()
        model.scan(URL(fileURLWithPath: "/new"))
        try await waitForRequests(gate, count: 2)
        await gate.emit(0, bytes: 999)
        await gate.finish(0, node: tree(at: URL(fileURLWithPath: "/old")))
        await gate.emit(1, bytes: 123)
        try await waitUntil { model.progress.bytes == 123 }
        await gate.finish(1, node: tree(at: URL(fileURLWithPath: "/new")))
        try await waitUntil { model.state == .ready }
        XCTAssertEqual(model.rootNode?.url.path, "/new")
        XCTAssertEqual(model.progress.bytes, 123)
    }

    func testCancellingRescanRestoresLastCompletedTree() async throws {
        let gate = LensScanGate()
        let model = SpaceLensViewModel(preferences: preferences, scanHandler: { url, minimum, progress in
            try await gate.scan(url, minimum: minimum, progress: progress)
        })
        let root = tree()
        model.rootNode = root
        model.state = .ready
        model.drill(into: try XCTUnwrap(root.children.first))
        model.rescan()
        try await waitForRequests(gate, count: 1)
        model.cancelScan()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.rootNode?.id, root.id)
        XCTAssertEqual(model.currentNode?.url.path, "/fixture/folder")
        await gate.finish(0, node: tree(at: URL(fileURLWithPath: "/discarded")))
        await Task.yield()
        XCTAssertEqual(model.rootNode?.id, root.id)
    }

    private func waitForRequests(_ gate: LensScanGate, count: Int) async throws {
        for _ in 0..<200 {
            if await gate.requests.count >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for scan request")
        throw NSError(domain: "SpaceLensTests", code: 2)
    }
}

private actor LensScanGate {
    struct Request {
        let url: URL
        let minimum: Int64
        let progress: @Sendable (SpaceLensEngine.Progress) -> Void
        let continuation: CheckedContinuation<SpaceLensNode, Error>
    }
    var requests: [Request] = []

    func scan(_ url: URL, minimum: Int64, progress: @escaping @Sendable (SpaceLensEngine.Progress) -> Void) async throws -> SpaceLensNode {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(url: url, minimum: minimum, progress: progress, continuation: continuation))
        }
    }

    func emit(_ index: Int, bytes: Int64) {
        requests[index].progress(.init(scannedBytes: bytes, itemCount: 1, currentPath: requests[index].url.path,
                                      inaccessibleCount: 0, skippedCount: 0))
    }

    func finish(_ index: Int, node: SpaceLensNode) { requests[index].continuation.resume(returning: node) }
}
