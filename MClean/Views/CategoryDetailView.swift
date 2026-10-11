import SwiftUI

struct CategoryDetailView: View {
    @EnvironmentObject var appState: AppState
    let category: CleaningCategory

    @State private var sortDescending: Bool = true
    @State private var searchText = ""
    @State private var sizeFilter = CleanupSizeFilter.any
    @State private var ageFilter = CleanupAgeFilter.any
    @State private var showConfirmation = false
    @State private var pendingItems: [CleanableItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("settings.general.confirmBeforeDelete") private var confirmBeforeDelete = true

    private var result: CategoryResult? {
        appState.categoryResults[category]
    }

    private var visibleItems: [CleanableItem] {
        CleanupReviewFilter(query: searchText, size: sizeFilter, age: ageFilter,
                            order: sortDescending ? .largest : .smallest)
            .apply(to: result?.items ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            heroCard
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Group {
                if let result = result {
                    if result.items.isEmpty {
                        EmptyStateView("All Clean", systemImage: "checkmark.circle", description: "No junk files found in this category.", tint: Tint.green)
                    } else {
                        reviewFilters
                        fileList(result)
                    }
                } else {
                    EmptyStateView("Not Scanned", systemImage: category.icon, description: "Run a scan to analyze this category.", action: { appState.scanSingleCategory(category) }, actionLabel: "Scan Now", tint: category.color)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter files")
        .navigationTitle(Text(LocalizedStringKey(category.rawValue)))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    appState.scanSingleCategory(category)
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(appState.scanState.isActive)
            }

            ToolbarItemGroup(placement: .automatic) {
                if let result = result, !result.items.isEmpty {
                    Button("Select All") {
                        appState.setSelection(true, for: visibleItems)
                    }
                    Button("Deselect All") {
                        appState.setSelection(false, for: visibleItems)
                    }
                    Button(action: { sortDescending.toggle() }) {
                        Label {
                            Text(LocalizedStringKey(sortDescending ? "Largest First" : "Smallest First"))
                        } icon: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                    .help(LocalizedStringKey(sortDescending ? "Sorted: Largest First" : "Sorted: Smallest First"))
                }
            }

            ToolbarItem(placement: .automatic) {
                if let _ = result, !appState.scanState.isActive {
                    let selectedSize = appState.selectedSizeInCategory(category)
                    let selectedCount = appState.selectedCountInCategory(category)
                    if selectedSize > 0 {
                        Button {
                            pendingItems = result?.items.filter(appState.isItemSelected) ?? []
                            if confirmBeforeDelete || pendingItems.contains(where: { $0.isActionItem }) {
                                showConfirmation = true
                            } else {
                                appState.cleanCategory(category)
                            }
                        } label: {
                            Label {
                                Text(cleanItemsLabel(count: selectedCount))
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: showConfirmation) { appState.showCleanConfirmation = $0 }
        .onDisappear { appState.showCleanConfirmation = false }
        .confirmationDialog(cleanConfirmationTitle, isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Clean", role: .destructive) {
                appState.cleanCategory(category, itemIDs: Set(pendingItems.map(\.id)))
                pendingItems = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files will be moved to the Trash. Items already in the Trash, simulator runtimes and Docker prune are permanently removed.")
        }
    }

    private func cleanItemsLabel(count: Int) -> String {
        String(format: String(localized: "Clean %lld items"), Int64(count))
    }

    private var cleanConfirmationTitle: String {
        String(
            format: String(localized: "Clean %@?"),
            ByteCountFormatter.string(fromByteCount: appState.selectedSizeInCategory(category), countStyle: .file)
        )
    }

    // MARK: - Hero

    private var heroCard: some View {
        let totalSize = result?.totalSize ?? 0
        let itemCount = result?.itemCount ?? 0
        let isScanning = appState.scanState.isActive

        return CardSurface(padding: 18) {
            HStack(alignment: .center, spacing: 16) {
                IconTile(systemName: category.icon, tint: category.color, size: 56, corner: 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(category.rawValue))
                        .font(.system(size: 22, weight: .semibold))
                    Text(LocalizedStringKey(category.description))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if itemCount > 0 {
                        Text(itemsAndSizeText(itemCount: itemCount, totalSize: totalSize))
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .foregroundStyle(category.color)
                            .padding(.top, 2)
                            .animation(reduceMotion ? nil : MotionTokens.gentle, value: totalSize)
                    }
                }

                Spacer()

                Button {
                    appState.scanSingleCategory(category)
                } label: {
                    Label {
                        Text(scanButtonLabel(isScanning: isScanning, hasResult: result != nil))
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isScanning)
            }
        }
    }

    private func itemsAndSizeText(itemCount: Int, totalSize: Int64) -> String {
        String(
            format: String(localized: "%lld items · %@"),
            Int64(itemCount),
            ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        )
    }

    private func scanButtonLabel(isScanning: Bool, hasResult: Bool) -> LocalizedStringKey {
        if isScanning { return "Scanning…" }
        if hasResult { return "Rescan" }
        return "Scan"
    }

    // MARK: - File List

    private var reviewFilters: some View {
        HStack {
            Picker("Size", selection: $sizeFilter) {
                ForEach(CleanupSizeFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            Picker("Date", selection: $ageFilter) {
                ForEach(CleanupAgeFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            let visibleIDs = Set(visibleItems.map(\.id))
            let hiddenCount = (result?.items ?? []).filter { appState.isItemSelected($0) && !visibleIDs.contains($0.id) }.count
            if hiddenCount > 0 {
                Text(String(format: String(localized: "%lld selected items are hidden by filters"), Int64(hiddenCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .disabled(appState.scanState.isActive)
    }

    private func fileList(_ result: CategoryResult) -> some View {
        let items = visibleItems
        return List {
            Section {
                // No .staggered() here: List is lazy, so a delayed-reveal
                // modifier would blank each row for ~0.45s as it scrolls into
                // view on large scans. The row hover/selection polish carries
                // the motion; the list-level sort/filter animation handles
                // reorders.
                ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                    FileRowView(item: item)
                }
            } header: {
                let selectedCount = appState.selectedCountInCategory(category)
                let totalCount = result.itemCount
                Text(
                    String(
                        format: String(localized: "%lld of %lld selected"),
                        Int64(selectedCount),
                        Int64(totalCount)
                    )
                )
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : MotionTokens.gentle, value: selectedCount)
            }
        }
        // CleanableItem ids are stable, so SwiftUI move-animates re-sorts and
        // fades filtered rows instead of snapping.
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: sortDescending)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: searchText)
    }

    private func sortedItems(_ items: [CleanableItem]) -> [CleanableItem] {
        items.sorted { sortDescending ? $0.size > $1.size : $0.size < $1.size }
    }
}

// MARK: - File Row View

private struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let item: CleanableItem

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool {
        appState.isItemSelected(item)
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isSelected },
            set: { _ in appState.toggleItem(item) }
        )) {
            HStack {
                Image(systemName: fileIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !item.path.isEmpty {
                        Text(item.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if let date = item.lastModified {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.formattedSize)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .toggleStyle(AnimatedCheckboxStyle(tint: item.category.color))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    hovering
                        ? Color.primary.opacity(0.06)
                        : (isSelected ? item.category.color.opacity(0.04) : .clear)
                )
        )
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .onHover { hovering = $0 }
        .contextMenu {
            if !item.isActionItem {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                }
                Button("Always exclude from cleanup") { appState.excludeFromCleanup(item) }
            }
        }
    }

    private var fileIcon: String {
        // Pure string logic — no filesystem access. This is read on every row
        // render (scroll, hover, selection, filter keystroke); the previous
        // fileExists() stat here caused main-thread jank on large scans.
        // A path ending in "/" is the scanner's directory marker; a component
        // with no extension is treated as a folder too.
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "log", "txt": return "doc.text"
        case "zip", "gz", "tar": return "doc.zipper"
        case "dmg", "iso": return "opticaldisc"
        case "app": return "app"
        case "pkg": return "shippingbox"
        case "": return item.path.hasSuffix("/") ? "folder" : "doc"
        default:
            return "doc"
        }
    }
}
