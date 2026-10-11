import AppKit
import SwiftUI
import XCTest
@testable import MClean

@MainActor
final class SpaceLensBreadcrumbTests: XCTestCase {
    func testNativeAncestorAndRootActionsNavigateAndClearSelection() {
        let file = SpaceLensNode(url: URL(fileURLWithPath: "/fixture/parent/child/file"), isDirectory: false)
        let child = SpaceLensNode(url: file.url.deletingLastPathComponent(), isDirectory: true, children: [file])
        let parent = SpaceLensNode(url: child.url.deletingLastPathComponent(), isDirectory: true, children: [child])
        let root = SpaceLensNode(url: parent.url.deletingLastPathComponent(), isDirectory: true, children: [parent])
        let model = SpaceLensViewModel()
        model.rootNode = root
        model.state = .ready
        model.drill(into: parent)
        model.drill(into: child)
        model.toggleSelection(file)

        let button = SpaceLensBreadcrumbButton(frame: .zero)
        button.configure(node: parent, isRoot: false, isCurrent: false) { model.pop(to: parent) }
        button.performClick(nil)
        XCTAssertEqual(model.path.map(\.id), [parent.id])
        XCTAssertTrue(model.selection.isEmpty)

        button.configure(node: root, isRoot: true, isCurrent: false) { model.pop(to: nil) }
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(model.currentNode?.id, root.id)
        XCTAssertTrue(model.path.isEmpty)
    }

    func testCurrentAndDisabledBreadcrumbsCannotActivate() {
        let node = SpaceLensNode(url: URL(fileURLWithPath: "/fixture"), isDirectory: true)
        let button = SpaceLensBreadcrumbButton(frame: .zero)
        var count = 0
        button.configure(node: node, isRoot: true, isCurrent: true) { count += 1 }
        button.performClick(nil)
        _ = button.accessibilityPerformPress()
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(button.acceptsFirstMouse(for: nil))
        XCTAssertEqual(count, 0)

        button.configure(node: node, isRoot: true, isCurrent: false, isEnabled: false) { count += 1 }
        button.performClick(nil)
        XCTAssertEqual(count, 0)
    }

    func testUpdatingReusedButtonReplacesActionAndAccessibilityLabel() {
        let node = SpaceLensNode(url: URL(fileURLWithPath: "/fixture/long folder name"), isDirectory: true)
        let button = SpaceLensBreadcrumbButton(frame: .zero)
        var result = ""
        button.configure(node: node, isRoot: false, isCurrent: false) { result = "old" }
        button.configure(node: node, isRoot: false, isCurrent: false) { result = "new" }
        button.performClick(nil)
        XCTAssertEqual(result, "new")
        XCTAssertTrue(button.accessibilityLabel()?.contains(node.name) == true)
        XCTAssertEqual(button.toolTip, node.url.path)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertGreaterThan(button.intrinsicContentSize.width, 100)
        XCTAssertGreaterThan(button.intrinsicContentSize.height, 16)
    }

    func testLabelAndPaddingHitNativeButtonInsideHorizontalScrollView() async throws {
        let node = SpaceLensNode(url: URL(fileURLWithPath: "/fixture/parent"), isDirectory: true)
        var activated = false
        let host = NSHostingView(rootView: SpaceLensBreadcrumbStrip(nodes: [node], currentID: nil) { _ in
            activated = true
        }.frame(height: 38))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        var found: SpaceLensBreadcrumbButton?
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            found = findButton(in: host)
            if found != nil, found!.bounds.width > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let button = try XCTUnwrap(found)
        for point in [NSPoint(x: button.bounds.midX, y: button.bounds.midY), NSPoint(x: 2, y: 2)] {
            let inHost = button.convert(point, to: host)
            XCTAssertTrue(host.hitTest(inHost) === button, "The label must not absorb the native button's click")
        }
        button.performClick(nil)
        XCTAssertTrue(activated)
    }

    func testLongTrailScrollsToCurrentAndPreservesAncestorActionsAfterResize() throws {
        let nodes = (0..<8).map { index in
            SpaceLensNode(url: URL(fileURLWithPath: "/fixture/long folder name \(index)"), isDirectory: true)
        }
        let scroll = SpaceLensBreadcrumbScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 38))
        var activated: UUID?
        scroll.configure(nodes: nodes, currentID: nodes.last?.id) { activated = $0.id }
        scroll.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.width, scroll.contentSize.width)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        let current = try XCTUnwrap(document.subviews.compactMap { $0 as? SpaceLensBreadcrumbButton }.last)
        XCTAssertTrue(scroll.contentView.bounds.contains(current.frame))
        XCTAssertFalse(current.isEnabled)

        scroll.frame.size.width = 2000
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
        let ancestor = try XCTUnwrap(document.subviews.compactMap { $0 as? SpaceLensBreadcrumbButton }.first)
        ancestor.performClick(nil)
        XCTAssertEqual(activated, nodes.first?.id)
        scroll.configure(nodes: nodes, currentID: nodes.last?.id, isEnabled: false) { activated = $0.id }
        XCTAssertTrue(document.subviews.compactMap { $0 as? SpaceLensBreadcrumbButton }.allSatisfy { !$0.isEnabled })
    }

    private func findButton(in view: NSView) -> SpaceLensBreadcrumbButton? {
        if let button = view as? SpaceLensBreadcrumbButton { return button }
        for child in view.subviews {
            if let result = findButton(in: child) { return result }
        }
        return nil
    }
}
