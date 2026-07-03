import XCTest
@testable import MClean

final class BubbleLayoutTests: XCTestCase {
    private let canvas = CGSize(width: 600, height: 400)

    func testEmptyInputYieldsEmptyLayout() {
        XCTAssertTrue(BubbleLayout.pack(sizes: [], in: canvas).isEmpty)
    }

    func testSingleItemIsCenteredAndFits() {
        let placements = BubbleLayout.pack(sizes: [1_000_000], in: canvas)
        XCTAssertEqual(placements.count, 1)
        let p = placements[0]
        XCTAssertEqual(p.center.x, canvas.width / 2, accuracy: 0.5)
        XCTAssertEqual(p.center.y, canvas.height / 2, accuracy: 0.5)
        XCTAssertLessThanOrEqual(p.radius * 2, min(canvas.width, canvas.height))
    }

    func testDeterministic() {
        let sizes: [Int64] = [900, 500, 300, 200, 120, 60, 10]
        let first = BubbleLayout.pack(sizes: sizes, in: canvas)
        let second = BubbleLayout.pack(sizes: sizes, in: canvas)
        XCTAssertEqual(first, second)
    }

    func testNoOverlapsBeyondEpsilon() {
        let sizes: [Int64] = (1...24).map { Int64(25 - $0) * 40_000_000 }
        let placements = BubbleLayout.pack(sizes: sizes, in: canvas)
        XCTAssertEqual(placements.count, sizes.count)
        for i in 0..<placements.count {
            for j in (i + 1)..<placements.count {
                let a = placements[i], b = placements[j]
                let distance = hypot(a.center.x - b.center.x, a.center.y - b.center.y)
                XCTAssertGreaterThanOrEqual(
                    distance, a.radius + b.radius - 0.5,
                    "bubbles \(i) and \(j) overlap"
                )
            }
        }
    }

    func testAllCirclesWithinCanvas() {
        let sizes: [Int64] = (1...16).map { Int64($0) * 10_000 }.reversed()
        for placement in BubbleLayout.pack(sizes: sizes, in: canvas) {
            XCTAssertGreaterThanOrEqual(placement.center.x - placement.radius, -0.5)
            XCTAssertGreaterThanOrEqual(placement.center.y - placement.radius, -0.5)
            XCTAssertLessThanOrEqual(placement.center.x + placement.radius, canvas.width + 0.5)
            XCTAssertLessThanOrEqual(placement.center.y + placement.radius, canvas.height + 0.5)
        }
    }

    func testRadiiNonIncreasingForSortedInput() {
        let sizes: [Int64] = [800, 400, 400, 90, 3]
        let radii = BubbleLayout.pack(sizes: sizes, in: canvas).map(\.radius)
        for pair in zip(radii, radii.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0, pair.1 - 0.001)
        }
    }

    func testZeroSizesStillVisible() {
        let placements = BubbleLayout.pack(sizes: [1_000, 0, 0], in: canvas)
        XCTAssertEqual(placements.count, 3)
        for placement in placements {
            XCTAssertGreaterThan(placement.radius, 0)
        }
    }
}
