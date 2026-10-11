import Sparkle
import XCTest
@testable import MClean

@MainActor
final class UpdateServiceTests: XCTestCase {
    private func updater() -> SPUUpdater {
        SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater
    }

    func testTestsNeverStartSchedulerOrAUserCheck() {
        let service = UpdateService()
        service.start { true }
        service.checkForUpdates()
        XCTAssertFalse(service.hasStarted)
        XCTAssertEqual(service.state, .idle)
    }

    func testNetworkAndSignatureFailuresNeverReportUpToDate() {
        let service = UpdateService()
        for error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
                      NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue))] {
            service.updater(updater(), didAbortWithError: error)
            guard case .failed = service.state else { return XCTFail("Expected an error, not current") }
        }
    }

    func testOnlyConfirmedLatestVersionReportsUpToDate() {
        let service = UpdateService()
        for reason in [SPUNoUpdateFoundReason.onLatestVersion, .onNewerThanLatestVersion] {
            let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                userInfo: [SPUNoUpdateFoundReasonKey: reason.rawValue])
            service.updaterDidNotFindUpdate(updater(), error: error)
            service.updater(updater(), didAbortWithError: error)
            XCTAssertEqual(service.state, .upToDate)
        }
        for reason in [SPUNoUpdateFoundReason.unknown, .systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64] {
            let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                userInfo: [SPUNoUpdateFoundReasonKey: reason.rawValue])
            service.updaterDidNotFindUpdate(updater(), error: error)
            service.updater(updater(), didAbortWithError: error)
            guard case .failed = service.state else { return XCTFail("Empty or incompatible feed is not current") }
        }
    }

    func testPostponedInstallRunsOnceAfterWorkFinishes() async {
        let service = UpdateService()
        var busy = true
        service.start { !busy }
        let installed = expectation(description: "Resume installation")
        var count = 0
        XCTAssertTrue(service.postponeInstallationIfNeeded {
            count += 1
            installed.fulfill()
        })
        XCTAssertTrue(service.isWaitingToInstall)
        await Task.yield()
        XCTAssertEqual(count, 0)
        busy = false
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertFalse(service.isWaitingToInstall)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(service.postponeInstallationIfNeeded { XCTFail("Sparkle handles an immediate install") })
    }

    func testAppStateBlocksRestartWhileScanCleanupAndConfirmationAreActive() {
        let state = AppState()
        XCTAssertTrue(state.canInstallAppUpdate)
        state.showCleanConfirmation = true
        XCTAssertFalse(state.canInstallAppUpdate)
        state.showCleanConfirmation = false
        state.scanState = .cleaning(progress: 0.5)
        XCTAssertFalse(state.canInstallAppUpdate)
        state.scanState = .idle
        state.spaceLens.state = .scanning
        XCTAssertFalse(state.canInstallAppUpdate)
        state.spaceLens.state = .ready
        state.isRemovingAppFiles = true
        XCTAssertFalse(state.canInstallAppUpdate)
        state.isRemovingAppFiles = false
        XCTAssertTrue(state.canInstallAppUpdate)
    }

    func testShippedConfigurationRequiresSignedFeedAndVerifiedArchive() throws {
        let bundle = Bundle.main
        let feed = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        XCTAssertEqual(URL(string: feed)?.scheme, "https")
        XCTAssertEqual(URL(string: feed)?.host, "github.com")
        let key = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool, true)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? Int, 0)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool, true)
    }
}
