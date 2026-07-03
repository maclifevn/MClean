import SwiftUI

/// First-launch flow. Four scenes, large typography, plenty of breathing
/// room. Sequence is welcome → mission → folder access → ready. Filesystem
/// access is always explicit and selected through the native macOS picker.
struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var page: Page = .welcome
    /// +1 when navigating forward, -1 going back — drives the slide direction
    /// so Back doesn't slide the wrong way.
    @State private var direction: Int = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var sandboxAccess = SandboxAccessManager.shared

    enum Page: Int, CaseIterable {
        case welcome, mission, permission, ready

        var index: Int { rawValue }
        static var count: Int { allCases.count }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: direction >= 0 ? 48 : -48)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.98)),
            removal: .offset(x: direction >= 0 ? -48 : 48)
                .combined(with: .opacity)
        )
    }

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 36)
                    .padding(.top, 44)
                    .padding(.bottom, 12)
                    .id(page)
                    .transition(pageTransition)

                bottomBar
            }
        }
        .frame(width: 680, height: 560)
        .onAppear {
            guard NSClassFromString("XCTestCase") == nil,
                  !sandboxAccess.hasFullScanAccess else { return }
            DispatchQueue.main.async {
                sandboxAccess.requestFullScanAccessOnLaunch()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: WelcomeScene()
        case .mission: MissionScene()
        case .permission:
            FolderAccessScene(
                hasAccess: sandboxAccess.hasFullScanAccess,
                chooseFolders: { _ = sandboxAccess.requestFullScanAccess() }
            )
        case .ready: ReadyScene(hasFolderAccess: sandboxAccess.hasFullScanAccess)
        }
    }

    // MARK: - Background

    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            // Radial wash that shifts hue per page and drifts opposite the
            // page slide — a slow parallax layer behind the faster foreground
            // spring. Static under Reduce Motion.
            RadialGradient(
                colors: [pageTint.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 60,
                endRadius: 520
            )
            .offset(x: reduceMotion ? 0 : CGFloat(page.index) * -30)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: page)
        }
    }

    private var pageTint: Color {
        switch page {
        case .welcome: return Tint.blue
        case .mission: return Tint.purple
        case .permission: return Tint.orange
        case .ready: return Tint.green
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if page != .welcome {
                Button("Back") { advance(by: -1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Button("Skip") { isComplete = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule()
                        .fill(p == page ? Color.primary.opacity(0.75) : Color.primary.opacity(0.15))
                        .frame(width: p == page ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: page)
                }
            }

            Spacer()

            if page == .ready {
                Button("Start") { isComplete = true }
                    .buttonStyle(GlowProminentButtonStyle(breathes: true))
            } else {
                Button(page == .permission ? "Continue" : "Next") { advance(by: 1) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                Color.clear
            }
        )
    }

    // MARK: - Actions

    private func advance(by delta: Int) {
        let target = max(0, min(Page.count - 1, page.index + delta))
        guard target != page.index else { return }
        Haptics.tap()
        // Direction must be set BEFORE the transaction so the transition
        // resolves with the correct slide edge.
        direction = delta >= 0 ? 1 : -1
        withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85)) {
            page = Page(rawValue: target) ?? page
        }
    }

}

// MARK: - Scenes

private struct WelcomeScene: View {
    @State private var bob = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)

            MCleanAppIcon(size: 120, shadow: true)
                .offset(y: reduceMotion ? 0 : (bob ? -4 : 4))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                        bob = true
                    }
                }
            .staggered(0, baseDelay: 0.07)

            VStack(spacing: 12) {
                Text("Reclaim your Mac")
                    .font(.system(size: 38, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Apple sells you small disks. We help you keep them clean.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .staggered(1, baseDelay: 0.07)

            Text("Free. Open source. MIT licensed.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .tracking(0.3)
                .padding(.top, 4)
                .staggered(2, baseDelay: 0.07)

            Spacer(minLength: 0)
        }
    }
}

private struct MissionScene: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Text("What's inside")
                    .font(.system(size: 30, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Three things, done well.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .staggered(0, baseDelay: 0.07)

            VStack(spacing: 12) {
                FeatureRow(
                    systemImage: "sparkles",
                    tint: Tint.blue,
                    title: "Smart Scan",
                    body: "Find caches, logs, broken installs, and the AI-app history hiding in your library."
                )
                .staggered(1, baseDelay: 0.07)
                FeatureRow(
                    systemImage: "square.grid.2x2.fill",
                    tint: Tint.purple,
                    title: "App Uninstaller",
                    body: "Drag an app, see every file it dropped, remove all of it. No leftovers."
                )
                .staggered(2, baseDelay: 0.07)
                FeatureRow(
                    systemImage: "doc.questionmark.fill",
                    tint: Tint.pink,
                    title: "Orphan Finder",
                    body: "Surfaces files that outlived the apps that created them."
                )
                .staggered(3, baseDelay: 0.07)
            }
            .frame(maxWidth: 460)

            Spacer(minLength: 0)
        }
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let body_: String

    init(systemImage: String, tint: Color, title: String, body: String) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.body_ = body
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemName: systemImage, tint: tint, size: 36, corner: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(body_)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct FolderAccessScene: View {
    let hasAccess: Bool
    let chooseFolders: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(systemName: hasAccess ? "checkmark.shield.fill" : "folder.badge.plus")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(hasAccess ? Tint.green : Tint.blue)

            VStack(spacing: 8) {
                Text(hasAccess ? "Full scan access granted" : "Allow the original scan coverage")
                    .font(.title2.weight(.semibold))
                Text("Select your startup disk once in the native macOS picker. MClean can then scan the same Home, Library, shared and developer locations as the original version.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Button(action: chooseFolders) {
                Label(hasAccess ? "Full Scan Access Granted" : "Allow Full Scan…",
                      systemImage: hasAccess ? "checkmark.circle.fill" : "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(hasAccess)

            Label("Native macOS consent · Access can be revoked anytime",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

private struct ReadyScene: View {
    let hasFolderAccess: Bool
    @State private var bounce = false
    @State private var fireConfetti = false
    @State private var confettiWork: DispatchWorkItem?
    @AppStorage("MClean.HasSeenWelcomeConfetti") private var hasSeenConfetti = false

    var body: some View {
        ZStack {
            // Confetti sits above the content but behind any touch targets;
            // disabling hit-testing keeps the Start button clickable through
            // falling particles.
            if !hasSeenConfetti {
                ConfettiView(trigger: fireConfetti)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 22) {
                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .fill((hasFolderAccess ? Tint.green : Tint.blue).opacity(0.12))
                        .frame(width: 110, height: 110)
                    Image(systemName: hasFolderAccess ? "checkmark" : "hand.wave.fill")
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundStyle(hasFolderAccess ? Tint.green : Tint.blue)
                        .scaleEffect(bounce ? 1.05 : 1.0)
                }
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) {
                        bounce = true
                    }
                    // Fire the welcome confetti exactly once per install.
                    // The work item is cancelled in onDisappear so a fast
                    // user who clicks Start within the 0.35s delay doesn't
                    // burn the once-per-install flag without ever seeing the
                    // celebration.
                    guard !hasSeenConfetti else { return }
                    let work = DispatchWorkItem {
                        fireConfetti = true
                        hasSeenConfetti = true
                        Haptics.success()
                    }
                    confettiWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
                }
                .onDisappear {
                    confettiWork?.cancel()
                    confettiWork = nil
                }

                VStack(spacing: 10) {
                    Text(hasFolderAccess ? "You're ready" : "Ready when you are")
                        .font(.system(size: 30, weight: .semibold))
                    Text(hasFolderAccess
                         ? "Hit Start to run your first Smart Scan."
                         : "Choose folders later from the dashboard or Settings whenever you're ready.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                Spacer(minLength: 0)
            }
        }
    }
}
