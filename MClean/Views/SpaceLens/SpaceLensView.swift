import AppKit
import SwiftUI

/// Space Lens: scan a folder, see its contents as size-proportional bubbles
/// plus a drillable list, select items, and move them to the Trash.
///
/// Thin wrapper so the @ObservedObject child observes the view model that
/// lives on AppState (it must survive MainWindow's `.id(selectedSection)`
/// teardown — a scan keeps running while the user visits other sections).
struct SpaceLensView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SpaceLensContent(lens: appState.spaceLens)
    }
}

private struct SpaceLensContent: View {
    @ObservedObject var lens: SpaceLensViewModel

    var body: some View {
        Group {
            switch lens.state {
            case .empty:
                emptyState
            case .scanning:
                SpaceLensScanningView(lens: lens)
            case .ready, .trashing:
                SpaceLensResultView(lens: lens)
            }
        }
        .alert("Couldn't move some items to the Trash", isPresented: Binding(
            get: { lens.lastError != nil && lens.state != .empty },
            set: { if !$0 { lens.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { lens.lastError = nil }
        } message: {
            Text(lens.lastError ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            EmptyStateView(
                "Space Lens", systemImage: "circle.hexagongrid.fill",
                description: "See what's taking up space. Scan a folder to map its contents as bubbles you can explore and clean.",
                action: { lens.scanHomeFolder() },
                actionLabel: "Scan Home Folder",
                tint: Tint.cyan
            )
            Button("Choose Folder…") { lens.chooseFolderAndScan() }
                .buttonStyle(.bordered)
                .padding(.bottom, 40)
        }
    }
}

// MARK: - Scanning

private struct SpaceLensScanningView: View {
    @ObservedObject var lens: SpaceLensViewModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Scanning…")
                .font(.title3.bold())
            // Both readouts observe the standalone high-frequency objects so
            // the ~10Hz churn re-renders only these labels (issues #119, #120).
            SpaceLensProgressReadout(progress: lens.progress)
            SpaceLensPathTicker(ticker: lens.ticker)
            Button("Stop Scan") { lens.cancelScan() }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SpaceLensProgressReadout: View {
    @ObservedObject var progress: SpaceLensScanProgress

    var body: some View {
        HStack(spacing: 6) {
            Text(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(String(format: String(localized: "%d items"), progress.items))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct SpaceLensPathTicker: View {
    @ObservedObject var ticker: ScanProgressTicker

    var body: some View {
        Text((ticker.path as NSString).abbreviatingWithTildeInPath)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 420)
    }
}

// MARK: - Results

private struct SpaceLensResultView: View {
    @ObservedObject var lens: SpaceLensViewModel
    @State private var showTrashConfirmation = false
    @State private var pendingNodes: [SpaceLensNode] = []
    @AppStorage("settings.general.confirmBeforeDelete") private var confirmBeforeDelete = true

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            if let root = lens.rootNode, root.isPartial {
                Label(String(format: String(localized: "%lld unavailable items; %lld skipped"),
                             Int64(root.inaccessibleCount), Int64(root.skippedCount)), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            Divider()
            HSplitView {
                BubbleMapView(lens: lens)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                childList
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
            }
            Divider()
            actionBar
        }
        .disabled(lens.state == .trashing)
        .overlay {
            if lens.state == .trashing {
                ProgressView().controlSize(.large)
            }
        }
    }

    // MARK: Breadcrumbs

    private var breadcrumbBar: some View {
        HStack(spacing: 0) {
            Button { lens.goBack() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!lens.canGoBack)
            .help("Back")
            .accessibilityLabel(Text("Back"))
            .padding(.leading, 8)

            SpaceLensBreadcrumbStrip(nodes: lens.rootNode.map { [$0] + lens.path } ?? [],
                                     currentID: lens.currentNode?.id) { node in
                lens.pop(to: node.id == lens.rootNode?.id ? nil : node)
            }
            .frame(height: 38)
        }
        .background(.bar)
    }

    // MARK: Child list

    private var childList: some View {
        List {
            ForEach(lens.visibleChildren) { node in
                SpaceLensRow(node: node,
                             isSelected: lens.selection.contains(node.id),
                             toggle: { toggleSelection(node) },
                             drill: { lens.drill(into: node) })
            }
            if let node = lens.currentNode, node.prunedCount > 0 {
                HStack {
                    Text(String(format: String(localized: "%d smaller items"), node.prunedCount))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: node.prunedSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }

    private func toggleSelection(_ node: SpaceLensNode) {
        if lens.selection.contains(node.id) {
            lens.selection.remove(node.id)
        } else {
            lens.selection.insert(node.id)
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            if lens.selection.isEmpty {
                Text("Nothing selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: String(localized: "Selected: %@"),
                            ByteCountFormatter.string(fromByteCount: lens.selectedSize, countStyle: .file)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            Spacer()
            Picker("Sort by", selection: $lens.sortOrder) {
                ForEach(SpaceLensViewModel.SortOrder.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 170)
            if !lens.includesSmallFiles {
                Button("Show smaller items") { lens.showSmallerItems() }
                    .buttonStyle(.bordered)
            }
            Button("Rescan") {
                lens.rescan()
            }
            .buttonStyle(.bordered)
            Button {
                if confirmBeforeDelete {
                    pendingNodes = lens.selectedNodes
                    showTrashConfirmation = true
                } else {
                    Task { await lens.trashSelection() }
                }
            } label: {
                Label("Move to Trash", systemImage: "trash.fill")
            }
            .buttonStyle(GlowProminentButtonStyle(tint: Tint.red, gradient: TintGradient.destructive))
            .disabled(lens.selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .confirmationDialog(
            String(format: String(localized: "Move %d items (%@) to the Trash?"),
                   lens.selection.count,
                   ByteCountFormatter.string(fromByteCount: lens.selectedSize, countStyle: .file)),
            isPresented: $showTrashConfirmation, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let nodes = pendingNodes
                Task { await lens.trash(nodes) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items can be restored from the Trash.")
        }
    }
}

/// One row in the child list: checkbox, Finder icon, name, size, and a
/// drill-in chevron for folders.
private struct SpaceLensRow: View {
    let node: SpaceLensNode
    let isSelected: Bool
    let toggle: () -> Void
    let drill: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(AnimatedCheckboxStyle(tint: Tint.cyan))
                .labelsHidden()

            Image(nsImage: FileIconCache.icon(forPath: node.url.path))
                .resizable()
                .frame(width: 18, height: 18)

            Text(verbatim: node.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)

            if node.isAccessDenied {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Tint.orange)
                    .help("Access denied")
            }

            Spacer()

            Text(verbatim: node.formattedSize)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if node.isDirectory && !node.isPackage {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory && !node.isPackage {
                drill()
            } else {
                toggle()
            }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }
}
