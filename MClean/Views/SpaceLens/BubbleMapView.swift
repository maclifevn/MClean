import SwiftUI

/// The Space Lens bubble map: the current node's largest children as
/// size-proportional circles. Tapping a folder drills in, tapping a file
/// toggles its selection. Individual Circle views (rather than Canvas) give
/// free hit-testing, hover feedback, and spring re-layout on navigation.
struct BubbleMapView: View {
    @ObservedObject var lens: SpaceLensViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bubbles beyond this rank collapse into one aggregate "Other" bubble —
    /// the packer stays trivially fast and labels stay legible.
    private static let maxBubbles = 24

    var body: some View {
        GeometryReader { geometry in
            let displayed = displayedChildren
            let otherSize = aggregateOtherSize(beyond: displayed)
            let sizes = displayed.map(\.size) + (otherSize > 0 ? [otherSize] : [])
            let placements = BubbleLayout.pack(sizes: sizes, in: geometry.size, padding: 10)

            ZStack {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, node in
                    if index < placements.count {
                        bubble(for: node, placement: placements[index])
                    }
                }
                if otherSize > 0, let last = placements.last {
                    otherBubble(size: otherSize, placement: last)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(reduceMotion ? nil : MotionTokens.gentle,
                       value: lens.currentNode?.id)
        }
    }

    private var displayedChildren: [SpaceLensNode] {
        Array((lens.currentNode?.children ?? []).prefix(Self.maxBubbles))
    }

    /// Bytes of children that didn't make the bubble cut, plus the pruned
    /// small-file remainder — shown as one muted "Other" bubble.
    private func aggregateOtherSize(beyond displayed: [SpaceLensNode]) -> Int64 {
        guard let node = lens.currentNode else { return 0 }
        let displayedBytes = displayed.reduce(0) { $0 + $1.size }
        return max(node.size - displayedBytes, 0)
    }

    private func bubble(for node: SpaceLensNode, placement: BubbleLayout.Placement) -> some View {
        SpaceLensBubble(
            node: node,
            radius: placement.radius,
            tint: tint(for: node, rank: placement.index),
            isSelected: lens.selection.contains(node.id)
        ) {
            if node.isDirectory && !node.isPackage {
                lens.drill(into: node)
            } else {
                toggleSelection(node)
            }
        }
        .position(placement.center)
    }

    private func otherBubble(size: Int64, placement: BubbleLayout.Placement) -> some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
            if placement.radius > 26 {
                VStack(spacing: 1) {
                    Text("Other")
                        .font(.system(size: min(13, placement.radius * 0.28), weight: .semibold))
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: min(11, placement.radius * 0.22)))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: placement.radius * 2, height: placement.radius * 2)
        .position(placement.center)
        .help("Other")
    }

    private func toggleSelection(_ node: SpaceLensNode) {
        if lens.selection.contains(node.id) {
            lens.selection.remove(node.id)
        } else {
            lens.selection.insert(node.id)
        }
    }

    /// Folders ride a blue→cyan ramp by size rank; files stay gray; folders
    /// we couldn't fully read are flagged orange.
    private func tint(for node: SpaceLensNode, rank: Int) -> Color {
        if node.isAccessDenied { return Tint.orange }
        guard node.isDirectory || node.isPackage else { return Color.secondary }
        let fraction = Double(rank) / Double(max(Self.maxBubbles - 1, 1))
        return Color(
            red: 0.04 + (0.30 - 0.04) * fraction,
            green: 0.52 + (0.78 - 0.52) * fraction,
            blue: 1.00 - (1.00 - 0.95) * fraction
        )
    }
}

/// One bubble. Owns its hover state so hovering re-renders only this circle.
private struct SpaceLensBubble: View {
    let node: SpaceLensNode
    let radius: CGFloat
    let tint: Color
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(TintGradient.of(tint.opacity(isSelected ? 0.9 : 0.55)))
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Tint.blue : tint.opacity(hovering ? 0.9 : 0.4),
                        lineWidth: isSelected ? 2.5 : 1
                    )
                )
                .shadow(color: tint.opacity(hovering ? 0.35 : 0.12),
                        radius: hovering ? 10 : 4, y: 2)

            if radius > 28 {
                VStack(spacing: 1) {
                    if node.isAccessDenied {
                        Image(systemName: "lock.fill")
                            .font(.system(size: min(11, radius * 0.2)))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Text(node.name)
                        .font(.system(size: min(13, radius * 0.26), weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(node.formattedSize)
                        .font(.system(size: min(11, radius * 0.2)))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(maxWidth: radius * 1.8)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .scaleEffect(hovering && !reduceMotion ? 1.05 : 1)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(Text(verbatim: "\(node.name) — \(node.formattedSize)"))
        .accessibilityLabel(Text(verbatim: node.name))
        .accessibilityValue(Text(verbatim: node.formattedSize))
        .accessibilityAddTraits(.isButton)
    }
}
