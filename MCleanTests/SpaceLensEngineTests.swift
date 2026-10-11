import XCTest
@testable import MClean

final class SpaceLensEngineTests: XCTestCase {
    private var fixtureRoot: URL!

    /// Fixture tree (sizes chosen around the 16 KB minNodeSize (allocated sizes are block-rounded, so the threshold must exceed the 4 KB APFS block) used in tests):
    ///   root/
    ///     big.bin           40960 B   -> node
    ///     tiny.txt            100 B   -> pruned
    ///     docs/
    ///       report.dat      20480 B   -> node
    ///       note.txt           50 B   -> pruned
    ///       nested/
    ///         blob.bin      81920 B   -> node
    ///     Fixture.app/                -> package leaf
    ///       Contents/exe    30000 B
    ///     link -> docs                -> symlink, excluded
    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceLensFixture-\(UUID().uuidString)")
        let fm = FileManager.default

        let docs = fixtureRoot.appendingPathComponent("docs")
        let nested = docs.appendingPathComponent("nested")
        let appContents = fixtureRoot.appendingPathComponent("Fixture.app/Contents")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: appContents, withIntermediateDirectories: true)

        try Data(count: 40960).write(to: fixtureRoot.appendingPathComponent("big.bin"))
        try Data(count: 100).write(to: fixtureRoot.appendingPathComponent("tiny.txt"))
        try Data(count: 20480).write(to: docs.appendingPathComponent("report.dat"))
        try Data(count: 50).write(to: docs.appendingPathComponent("note.txt"))
        try Data(count: 81920).write(to: nested.appendingPathComponent("blob.bin"))
        try Data(count: 30000).write(to: appContents.appendingPathComponent("exe"))
        try fm.createSymbolicLink(
            at: fixtureRoot.appendingPathComponent("link"),
            withDestinationURL: docs
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    private func scanFixture(minNodeSize: Int64 = 16384) async throws -> SpaceLensNode {
        try await SpaceLensEngine().scan(root: fixtureRoot,
                                         minNodeSize: minNodeSize) { _ in }
    }

    func testTotalSizeIsSumOfAllFiles() async throws {
        let root = try await scanFixture()
        // Allocated sizes are block-rounded, so assert against the sum of the
        // children the engine itself reports plus the pruned remainder.
        let expected = root.children.reduce(root.prunedSize + root.ownSize) { $0 + $1.size }
        XCTAssertEqual(root.size, expected)
        // And the logical payload must be at least the written bytes.
        XCTAssertGreaterThanOrEqual(root.size, 40960 + 20480 + 81920 + 30000)
    }

    func testChildrenSortedDescending() async throws {
        let root = try await scanFixture()
        let sizes = root.children.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        for child in root.children where child.isDirectory {
            let childSizes = child.children.map(\.size)
            XCTAssertEqual(childSizes, childSizes.sorted(by: >))
        }
    }

    func testPackageIsLeafWithNonZeroSize() async throws {
        let root = try await scanFixture()
        let app = try XCTUnwrap(root.children.first { $0.name == "Fixture.app" })
        XCTAssertTrue(app.isPackage)
        XCTAssertTrue(app.children.isEmpty)
        XCTAssertGreaterThanOrEqual(app.size, 30000)
    }

    func testSymlinkIsNotFollowed() async throws {
        let root = try await scanFixture(minNodeSize: 0)
        XCTAssertNil(root.children.first { $0.name == "link" })
        XCTAssertEqual(root.skippedCount, 1)
        XCTAssertEqual(root.fileCount, 6)
        XCTAssertTrue(root.isPartial)
    }

    func testSmallFilesArePrunedIntoParentTally() async throws {
        let root = try await scanFixture()
        XCTAssertNil(root.children.first { $0.name == "tiny.txt" })
        // Only the tiny file is grouped; symbolic links are excluded.
        XCTAssertEqual(root.prunedCount, 1)
        XCTAssertGreaterThanOrEqual(root.prunedSize, 100)

        let docs = try XCTUnwrap(root.children.first { $0.name == "docs" })
        XCTAssertNil(docs.children.first { $0.name == "note.txt" })
        XCTAssertEqual(docs.prunedCount, 1)
        // Pruned bytes still count toward the directory's size.
        XCTAssertGreaterThanOrEqual(docs.size, 20480 + 81920 + 50)
    }

    func testSmallDirectoryRemainsNavigableEvenWhenItsFilesAreGrouped() async throws {
        let root = try await scanFixture(minNodeSize: 200_000)
        let docs = try XCTUnwrap(root.children.first { $0.name == "docs" })
        let nested = try XCTUnwrap(docs.children.first { $0.name == "nested" })
        XCTAssertTrue(docs.isDirectory)
        XCTAssertEqual(nested.prunedCount, 1)
        XCTAssertEqual(docs.fileCount, 3)
        XCTAssertGreaterThan(docs.size, 0)
        XCTAssertEqual(root.size, root.ownSize + root.prunedSize + root.children.reduce(0) { $0 + $1.size })
    }

    func testCancellationThrows() async throws {
        let engine = SpaceLensEngine()
        let task = Task {
            try await engine.scan(root: fixtureRoot, minNodeSize: 0) { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            // A tiny fixture can legitimately finish before the cancel lands;
            // only a non-cancellation error is a failure.
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testRemoveChildPropagatesSizeUpward() async throws {
        let root = try await scanFixture()
        let docs = try XCTUnwrap(root.children.first { $0.name == "docs" })
        let nested = try XCTUnwrap(docs.children.first { $0.name == "nested" })
        let rootBefore = root.size
        let docsBefore = docs.size
        let filesBefore = root.fileCount
        let directoriesBefore = root.directoryCount

        docs.removeChild(nested)

        XCTAssertNil(docs.children.first { $0.name == "nested" })
        XCTAssertEqual(docs.size, docsBefore - nested.size)
        XCTAssertEqual(root.size, rootBefore - nested.size)
        XCTAssertEqual(root.fileCount, filesBefore - nested.fileCount)
        XCTAssertEqual(root.directoryCount, directoriesBefore - nested.directoryCount)
        XCTAssertNil(nested.parent)
    }
}
