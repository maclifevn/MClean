import AppKit
import SwiftUI
import Combine

/// Captures SwiftUI's `openWindow` action so AppKit surfaces (the menu-bar
/// popover, which lives outside the scene graph and has no working `openWindow`
/// environment) can reopen the main window after it has been closed. The main
/// window records the action on appear; the closure stays valid for the app's
/// lifetime even once the window is gone.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: ((String) -> Void)?
    private init() {}
}

/// Keeps a quick action alive while SwiftUI recreates the main window. A
/// notification handles the already-open case; this flag handles the short
/// gap between `openWindow` and `MainWindow.onAppear`.
@MainActor
enum MenuBarQuickActionBuffer {
    static var smartScanRequested = false
}

/// AppKit-backed menu-bar system monitor. A SwiftUI `MenuBarExtra` was avoided
/// here: a conditional `.window`-style `MenuBarExtra` fails to type-check, and
/// an unconditional one stalls the XCTest host's run loop. An `NSStatusItem`
/// driving an `NSPopover` (which hosts the existing SwiftUI `MenuBarMonitorView`)
/// gives the same UI with full create/destroy control and no test-host impact.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let monitor = SystemMonitor.shared
    private var cancellable: AnyCancellable?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // Persist the user's show/hide choice and ensure the item is requested
        // visible (it defaults hidden when restored from a prior autosave state).
        statusItem.autosaveName = "MCleanSystemMonitor"
        statusItem.isVisible = true

        monitor.start()

        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon") ?? NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: nil
            )
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel("MClean")
            button.target = self
            button.action = #selector(togglePopover)
            updateAccessibilityStatus()
        }

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(
            rootView: MenuBarMonitorView(
                onSmartScan: { [weak self] in self?.startSmartScan() },
                onOpenApp: { [weak self] in self?.openMainWindow() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        popover.contentViewController = host
        popover.contentSize = host.sizeThatFits(in: NSSize(width: 304, height: 600))
        popover.delegate = self

        // Keep VoiceOver and the hover tooltip informative without changing
        // the status item's width every time the CPU percentage changes.
        cancellable = monitor.$cpuUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateAccessibilityStatus() }
    }

    /// Remove the status item and release the monitor observer. Called by
    /// AppDelegate before dropping the controller so teardown runs on the main
    /// actor (a `@MainActor` deinit cannot touch isolated state safely).
    func teardown() {
        cancellable?.cancel()
        cancellable = nil
        if popover.isShown { popover.performClose(nil) }
        NSStatusBar.system.removeStatusItem(statusItem)
        monitor.stop()
    }

    private func updateAccessibilityStatus() {
        guard let button = statusItem.button else { return }
        let percent = Int((monitor.cpuUsage * 100).rounded())
        let status = String(format: String(localized: "CPU %lld%%"), Int64(percent))
        button.toolTip = "MClean · \(status)"
        button.setAccessibilityValue(status)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func startSmartScan() {
        MenuBarQuickActionBuffer.smartScanRequested = true
        closePopover()
        presentMainWindow()
        NotificationCenter.default.post(name: .mCleanSmartScanRequested, object: nil)
    }

    private func openMainWindow() {
        closePopover()
        presentMainWindow()
    }

    private func openSettings() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's OpenSettingsAction starts at macOS 14 while MClean still
        // supports macOS 13. Route through the standard AppKit responder-chain
        // action so the Settings scene works across the deployment range.
        let opened = NSApp.sendAction(
            Selector(("showSettingsWindow:")), to: nil, from: nil
        )
        if !opened {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    private func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: {
            $0.canBecomeMain && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            WindowOpener.shared.open?("main")
        }
    }
}
