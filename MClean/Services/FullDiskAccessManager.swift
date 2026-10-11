import AppKit
import Foundation

/// Detects whether Full Disk Access (FDA) has been granted to MClean.
/// Without FDA, macOS TCC blocks access to ~/Library/Mail, ~/Library/Safari,
/// /Library/Application Support/com.apple.TCC, and other protected locations.
final class FullDiskAccessManager {
    static let shared = FullDiskAccessManager()

    private init() {}

    /// Check if Full Disk Access is granted by attempting a real read of a
    /// TCC-protected file. We use FileHandle/Data — not isReadableFile or
    /// fileExists — because the metadata APIs short-circuit before TCC fires
    /// and so don't register the calling app in the FDA list.
    var hasFullDiskAccess: Bool {
        let probes = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            "/Library/Application Support/com.apple.TCC/TCC.db",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/CloudTabs.db").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mail").path,
        ]

        for path in probes {
            if canActuallyRead(path: path) { return true }
        }
        return false
    }

    /// Real-read probe. Performs the syscall TCC actually evaluates, so
    /// the OS records MClean as the requester and adds it to the FDA pane.
    /// Directories use contentsOfDirectory; files use FileHandle.
    @discardableResult
    private func canActuallyRead(path: String) -> Bool {
        // Attempt the protected operation even when a metadata lookup would
        // say the entry is absent. TCC can hide metadata before registration.
        if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            if (try? handle.read(upToCount: 1)) != nil { return true }
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Force MClean to appear in the Full Disk Access list.
    ///
    /// The OS only registers an app in the FDA pane after that app itself
    /// makes a TCC-gated syscall. Metadata lookups (fileExists, isReadableFile)
    /// don't qualify, and delegating to Finder via AppleScript registers
    /// *Finder* — not MClean. So at launch we touch a small set of paths
    /// gated specifically by the SystemPolicyAllFiles (FDA) service. The reads
    /// will fail until the user grants access — that's fine, the failed
    /// attempts are what register us.
    ///
    /// We intentionally do NOT probe Messages, Contacts, Calendars, or other
    /// paths gated by separate TCC services. Touching those would register
    /// MClean in unrelated permission lists ("Messages", "Contacts", etc.)
    /// even though we never use them — confusing and a privacy regression.
    func triggerRegistration() {
        DispatchQueue.global(qos: .utility).async {
            // Once access is granted the bundle is already registered (and
            // the grant proves it) — skip the probe sweep on every warm
            // launch. hasFullDiskAccess short-circuits on its first
            // successful read, so the granted path costs a single syscall.
            guard !self.hasFullDiskAccess else { return }

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            // FDA-only probes. Each path here is read-gated by
            // SystemPolicyAllFiles, nothing else.
            let probePaths = [
                "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
                "/Library/Application Support/com.apple.TCC/TCC.db",
                "\(home)/Library/Mail",
                "\(home)/Library/Safari/CloudTabs.db",
                "\(home)/Library/Safari/Bookmarks.plist",
                "\(home)/Library/Cookies",
                "\(home)/Library/HTTPStorages",
                "\(home)/Library/Application Support/com.apple.TCC",
            ]
            for path in probePaths {
                _ = self.canActuallyRead(path: path)
            }
        }
    }

    /// FDA probe from a freshly spawned child process.
    ///
    /// macOS applies a Full Disk Access toggle only to processes started
    /// AFTER the grant — the already-running app keeps its old (denied) TCC
    /// verdict until relaunch, so `hasFullDiskAccess` above can never turn
    /// true mid-session. A child process is new, gets a fresh TCC evaluation,
    /// and tccd attributes it to MClean (the responsible process), so this
    /// reflects the *granted* state. In-process false + fresh-process true
    /// therefore means: access granted, relaunch required.
    func hasFullDiskAccessInFreshProcess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/CloudTabs.db",
        ]
        for path in probes {
            do {
                let result = try CommandRunner.run(
                    executable: "/usr/bin/head",
                    arguments: ["-c", "1", path],
                    timeout: 2
                )
                if result.succeeded { return true }
            } catch {
                continue
            }
        }
        return false
    }

    /// Restart MClean so a freshly granted FDA toggle takes effect. A
    /// detached shell waits out our teardown, relaunches the same bundle,
    /// and the current instance terminates immediately.
    func relaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Positional arguments preserve spaces/quotes. Wait for actual exit:
        // quit may be deferred while a filesystem mutation is still running.
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"",
                             "mclean-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try process.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } catch {
            Logger.shared.log("Failed to relaunch MClean: \(error.localizedDescription)", level: .error)
        }
    }

    /// Opens System Settings to the Full Disk Access pane.
    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Reveal the running MClean.app bundle in Finder so the user can drag
    /// it into the Full Disk Access list when the OS hasn't auto-registered
    /// it (common with Homebrew installs that strip the quarantine attribute).
    func revealAppInFinder() {
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    /// Reset MClean's TCC entries so the OS can re-register the bundle.
    /// Useful when the bundle was replaced (Homebrew upgrade, manual move)
    /// and the existing TCC row points at a stale code-signing identity.
    /// Returns true if the reset command exited cleanly.
    @discardableResult
    func resetFullDiskAccess() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.maclife.mclean"
        do {
            return try CommandRunner.run(
                executable: "/usr/bin/tccutil",
                arguments: ["reset", "SystemPolicyAllFiles", bundleID],
                timeout: 5
            ).succeeded
        } catch {
            return false
        }
    }
}
