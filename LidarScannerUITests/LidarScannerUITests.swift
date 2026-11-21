import XCTest

/// The simulator has no LiDAR, so these cover navigation, the unsupported-device path and the scan library.
final class LidarScannerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetScans"] + arguments
        app.launch()
        return app
    }

    func testHomeShowsBothScanModesAndLibrary() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["LiDAR Scanner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["roomScanButton"].exists)
        XCTAssertTrue(app.buttons["objectScanButton"].exists)
        XCTAssertTrue(app.buttons["myScansLink"].exists)
        XCTAssertEqual(app.staticTexts["scanCount"].label, "0")
    }

    func testRoomScanExplainsMissingLiDAR() {
        let app = launch(["-UITestForceUnsupported"])
        app.buttons["roomScanButton"].tap()
        XCTAssertTrue(app.staticTexts["Room Scan Unavailable"].waitForExistence(timeout: 5))
        app.buttons["closeButton"].tap()
        XCTAssertTrue(app.buttons["roomScanButton"].waitForExistence(timeout: 5))
    }

    func testObjectScanExplainsMissingLiDAR() {
        let app = launch(["-UITestForceUnsupported"])
        app.buttons["objectScanButton"].tap()
        XCTAssertTrue(app.staticTexts["Object Scan Unavailable"].waitForExistence(timeout: 5))
        app.buttons["closeButton"].tap()
        XCTAssertTrue(app.buttons["objectScanButton"].waitForExistence(timeout: 5))
    }

    func testEmptyLibrary() {
        let app = launch()
        app.buttons["myScansLink"].tap()
        XCTAssertTrue(app.staticTexts["No Scans Yet"].waitForExistence(timeout: 5))
    }

    func testLibraryListsAndDeletesScans() {
        let app = launch(["-UITestSeedSampleScans"])
        XCTAssertEqual(app.staticTexts["scanCount"].label, "2")
        app.buttons["myScansLink"].tap()

        XCTAssertTrue(app.staticTexts["Room Scans"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Object Scans"].exists)
        let roomScan = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'scan-Room '")).firstMatch
        XCTAssertTrue(roomScan.exists)

        roomScan.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(roomScan.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Room Scans"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts["scanCount"].label, "1")
    }
}
