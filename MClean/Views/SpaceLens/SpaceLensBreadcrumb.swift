import AppKit
import SwiftUI

/// The label keeps MClean's appearance; a native NSButton owns mouse,
/// keyboard and accessibility activation instead of a SwiftUI tap gesture.
struct SpaceLensBreadcrumbStrip: NSViewRepresentable {
    let nodes: [SpaceLensNode]
    let currentID: UUID?
    let action: (SpaceLensNode) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> SpaceLensBreadcrumbScrollView {
        SpaceLensBreadcrumbScrollView(frame: .zero)
    }

    func updateNSView(_ scroll: SpaceLensBreadcrumbScrollView, context: Context) {
        scroll.configure(nodes: nodes, currentID: currentID, isEnabled: isEnabled, action: action)
    }
}

/// Keep the scroll container native as well: on macOS 15 a SwiftUI horizontal
/// ScrollView can intercept clicks even when its children are native buttons.
@MainActor
final class SpaceLensBreadcrumbScrollView: NSScrollView {
    private let strip = NSView()
    private var currentID: UUID?
    private var revealCurrent = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        hasVerticalScroller = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = strip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(nodes: [SpaceLensNode], currentID: UUID?, isEnabled: Bool = true,
                   action: @escaping (SpaceLensNode) -> Void) {
        let existing = Dictionary(uniqueKeysWithValues: strip.subviews.compactMap { view in
            (view as? SpaceLensBreadcrumbButton).map { ($0.nodeID, $0) }
        })
        strip.subviews.forEach { $0.removeFromSuperview() }
        for (index, node) in nodes.enumerated() {
            if index > 0 {
                let separator = NSImageView()
                separator.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
                separator.contentTintColor = .tertiaryLabelColor
                separator.setAccessibilityElement(false)
                strip.addSubview(separator)
            }
            let button = existing[node.id] ?? SpaceLensBreadcrumbButton(frame: .zero)
            button.configure(node: node, isRoot: index == 0, isCurrent: node.id == currentID,
                             isEnabled: isEnabled) { action(node) }
            strip.addSubview(button)
        }
        revealCurrent = self.currentID != currentID
        self.currentID = currentID
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let viewport = contentView.bounds.size
        var x: CGFloat = 8
        for view in strip.subviews {
            let size = view is SpaceLensBreadcrumbButton ? view.intrinsicContentSize : NSSize(width: 5, height: 10)
            view.frame = NSRect(x: x, y: (viewport.height - size.height) / 2,
                                width: size.width, height: size.height)
            x += size.width + 4
        }
        strip.setFrameSize(NSSize(width: max(viewport.width, x + 4), height: viewport.height))
        let maxOffset = max(0, strip.frame.width - viewport.width)
        let offset = revealCurrent ? maxOffset : min(contentView.bounds.minX, maxOffset)
        contentView.scroll(to: NSPoint(x: offset, y: 0))
        reflectScrolledClipView(contentView)
        revealCurrent = false
    }

}

@MainActor
final class SpaceLensBreadcrumbButton: NSButton {
    private(set) var nodeID = UUID()
    private let label = NSHostingView(rootView: SpaceLensBreadcrumbLabel())
    private var tracking: NSTrackingArea?
    private var activate: (() -> Void)?
    private var current = false
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(performNavigation)
        addSubview(label)
        label.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(node: SpaceLensNode, isRoot: Bool, isCurrent: Bool,
                   isEnabled: Bool = true, action: @escaping () -> Void) {
        nodeID = node.id
        current = isCurrent
        self.isEnabled = isEnabled && !isCurrent
        activate = action
        label.rootView = SpaceLensBreadcrumbLabel(name: node.name, size: node.formattedSize,
                                                 isRoot: isRoot, isCurrent: isCurrent,
                                                 hovering: hovering && self.isEnabled)
        toolTip = node.url.path
        setAccessibilityLabel("\(node.name), \(node.formattedSize)")
        setAccessibilityIdentifier("SpaceLens.breadcrumb.\(node.url.path)")
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
    }

    override var intrinsicContentSize: NSSize { label.fittingSize }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    // All of the label, including padding, belongs to this native control.
    // Its embedded NSHostingView must never become the mouse-event target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled && !current }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !current else { return false }
        performClick(nil)
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(true) }
    override func mouseExited(with event: NSEvent) { updateHover(false) }

    private func updateHover(_ value: Bool) {
        hovering = value
        label.rootView.hovering = value && isEnabled
    }

    @objc private func performNavigation() {
        guard isEnabled, !current else { return }
        activate?()
    }
}

private struct SpaceLensBreadcrumbLabel: View {
    var name = ""
    var size = ""
    var isRoot = false
    var isCurrent = false
    var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if isRoot {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 10))
            }
            Text(verbatim: name)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
            Text(verbatim: size)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(isCurrent ? Tint.cyan.opacity(0.14)
                                  : (hovering ? Color.primary.opacity(0.08) : Color.clear)))
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
