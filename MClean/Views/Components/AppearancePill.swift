import SwiftUI

/// Inline 3-segment toggle (system / light / dark) with an animated active
/// indicator that slides between segments. Replaces the SwiftUI `Menu` which
/// looked like a generic dropdown affordance.
struct AppearancePill: View {
    @Binding var selection: AppearanceMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            // Keep one indicator alive and move it between fixed-width
            // segments. Conditional matched-geometry sources can briefly
            // overlap during toolbar reconstruction and flicker.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .frame(width: 28, height: 22)
                .offset(x: CGFloat(selectionIndex) * 30)

            HStack(spacing: 2) {
                ForEach(AppearanceMode.allCases) { mode in
                    Button {
                        selection = mode
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.system(size: 12, weight: .semibold))
                            // Icons have different native widths (sun vs moon);
                            // the fixed frame keeps all three segments identical
                            // so the sliding indicator lands evenly on each.
                            .frame(width: 28, height: 22)
                            .foregroundStyle(selection == mode ? Color.primary : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey(mode.label))
                }
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78),
            value: selection
        )
        // Breathing room between the edge segments' indicator and the
        // toolbar capsule the control sits in — without it the gray
        // indicator on the first/last segment touches the capsule border
        // and the whole pill reads as off-center.
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .fixedSize()
    }

    private var selectionIndex: Int {
        AppearanceMode.allCases.firstIndex(of: selection) ?? 0
    }
}
