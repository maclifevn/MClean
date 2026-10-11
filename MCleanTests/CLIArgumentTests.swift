import XCTest
@testable import MClean

final class CLIArgumentTests: XCTestCase {
    func testScanArgumentsAcceptKnownCategoriesAndJSONInEitherOrder() throws {
        XCTAssertEqual(try CLI.scanOptions(["--category", "usercache", "--json"]),
            CLI.ScanOptions(json: true, category: .userCache))
        XCTAssertEqual(try CLI.scanOptions(["--json", "--category", "Large & Old Files"]),
            CLI.ScanOptions(json: true, category: .largeFiles))
    }

    func testMalformedArgumentsCannotFallBackToScanningEverything() {
        for arguments in [["--category"], ["--category", "--json"], ["--typo"],
                          ["--category", "Purgeable Space"], ["--category", "Language Files"],
                          ["--category", "usercache", "--category", "systemjunk"]] {
            XCTAssertThrowsError(try CLI.scanOptions(arguments))
        }
    }
}
