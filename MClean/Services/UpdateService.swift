import AppKit
import Combine
import Sparkle

/// One updater for the GUI lifetime. Sparkle owns download verification,
/// installation, relaunch and persisted user preferences.
@MainActor
final class UpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateService()
    nonisolated static let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    nonisolated static let installedBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    nonisolated static let releasesURL = URL(string: "https://github.com/maclifevn/MClean/releases")!

    enum State: Equatable {
        case idle, checking
        case available(String)
        case upToDate
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isWaitingToInstall = false
    @Published private(set) var hasStarted = false
    private var controller: SPUStandardUpdaterController!
    private var installationAllowed: () -> Bool = { true }
    private var installTask: Task<Void, Never>?

    var isChecking: Bool { state == .checking }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
    }

    /// Called after onboarding, never from the CLI or XCTest host.
    func start(installationAllowed: @escaping () -> Bool) {
        self.installationAllowed = installationAllowed
        guard !hasStarted, NSClassFromString("XCTestCase") == nil else { return }
        do {
            try controller.updater.start()
            hasStarted = true
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func checkForUpdates() {
        guard hasStarted, canCheckForUpdates else { return }
        state = .checking
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let code = reason?.intValue ?? -1
        if code == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
            || code == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
            state = .upToDate
        } else {
            // An empty feed or incompatible OS is not proof we are up to date.
            state = .failed(error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain, failure.code == SUError.noUpdateError.rawValue { return }
        if failure.domain == SUSparkleErrorDomain, failure.code == SUError.installationCanceledError.rawValue {
            state = .idle
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfNeeded(installHandler)
    }

    /// Avoid restarting while a scan, cleanup, uninstall or confirmation is active.
    /// Also reused by the regression test without starting Sparkle's scheduler.
    func postponeInstallationIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard !installationAllowed() || NSApp.modalWindow != nil else { return false }
        isWaitingToInstall = true
        installTask?.cancel()
        installTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.installationAllowed(), NSApp.modalWindow == nil {
                    self.isWaitingToInstall = false
                    installHandler()
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return true
    }
}
