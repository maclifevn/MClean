import CoreGraphics
import Foundation

/// Deterministic circle packing for the Space Lens bubble map.
///
/// Radius grows with the square root of the item size (area ∝ bytes). The
/// largest circle sits at the canvas center; each subsequent circle walks an
/// Archimedean spiral outward from the center and takes the first position
/// that doesn't overlap anything placed before it. The packed cloud is then
/// uniformly scaled and translated to fit the canvas. No randomness — the
/// same input always yields the same layout, which keeps navigation
/// animations stable and the function unit-testable.
enum BubbleLayout {
    struct Placement: Equatable {
        let index: Int
        let center: CGPoint
        let radius: CGFloat
    }

    /// `sizes` must be sorted descending (the caller displays children in
    /// that order anyway). Zero/negative sizes get a small floor so every
    /// item stays visible and tappable.
    static func pack(sizes: [Int64], in canvas: CGSize, padding: CGFloat = 4) -> [Placement] {
        guard !sizes.isEmpty, canvas.width > 0, canvas.height > 0 else { return [] }

        // Unit radii: sqrt keeps area proportional to bytes; floor at 12% of
        // the largest so tiny files never vanish.
        let maxSize = max(sizes[0], 1)
        let unitRadii: [CGFloat] = sizes.map { size in
            let fraction = Double(max(size, 0)) / Double(maxSize)
            return CGFloat(max(fraction.squareRoot(), 0.12)) * 100
        }

        // Spiral placement in unit space.
        var placed: [(center: CGPoint, radius: CGFloat)] = []
        placed.reserveCapacity(unitRadii.count)
        for radius in unitRadii {
            if placed.isEmpty {
                placed.append((.zero, radius))
                continue
            }
            var theta: CGFloat = 0
            let step: CGFloat = 0.35
            // r = g·θ with a small pitch relative to the largest circle so
            // candidates sweep densely; advance until nothing overlaps.
            let pitch = unitRadii[0] / 40
            while true {
                let candidate = CGPoint(x: pitch * theta * cos(theta),
                                        y: pitch * theta * sin(theta))
                let overlaps = placed.contains { other in
                    let dx = candidate.x - other.center.x
                    let dy = candidate.y - other.center.y
                    let minDistance = radius + other.radius + 1 // unit-space gap
                    return dx * dx + dy * dy < minDistance * minDistance
                }
                if !overlaps {
                    placed.append((candidate, radius))
                    break
                }
                theta += step
            }
        }

        // Fit the bounding box of the packed cloud into the canvas.
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for item in placed {
            minX = min(minX, item.center.x - item.radius)
            minY = min(minY, item.center.y - item.radius)
            maxX = max(maxX, item.center.x + item.radius)
            maxY = max(maxY, item.center.y + item.radius)
        }
        let cloudWidth = max(maxX - minX, 1)
        let cloudHeight = max(maxY - minY, 1)
        let scale = min((canvas.width - padding * 2) / cloudWidth,
                        (canvas.height - padding * 2) / cloudHeight)
        let cloudCenter = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let canvasCenter = CGPoint(x: canvas.width / 2, y: canvas.height / 2)

        return placed.enumerated().map { index, item in
            Placement(
                index: index,
                center: CGPoint(
                    x: canvasCenter.x + (item.center.x - cloudCenter.x) * scale,
                    y: canvasCenter.y + (item.center.y - cloudCenter.y) * scale
                ),
                radius: item.radius * scale
            )
        }
    }
}
