import SwiftUI

/// Inline 3-segment toggle (system / light / dark) with an animated active
/// indicator that slides between segments. Replaces the SwiftUI `Menu` which
/// looked like a generic dropdown affordance.
struct AppearancePill: View {
    @Binding var selection: AppearanceMode
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = mode
                    }
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: .semibold))
                        // Icons have different native widths (sun vs moon);
                        // the fixed frame keeps all three segments identical
                        // so the sliding indicator lands evenly on each.
                        .frame(width: 28, height: 22)
                        .foregroundStyle(selection == mode ? Color.primary : .secondary)
                        .background(
                            ZStack {
                                if selection == mode {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.10))
                                        .matchedGeometryEffect(id: "indicator", in: indicator)
                                }
                            }
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey(mode.label))
            }
        }
        // Breathing room between the edge segments' indicator and the
        // toolbar capsule the control sits in — without it the gray
        // indicator on the first/last segment touches the capsule border
        // and the whole pill reads as off-center.
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .fixedSize()
    }
}
