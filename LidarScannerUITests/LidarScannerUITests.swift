import XCTest

/// The simulator has no LiDAR, so these cover navigation, the unsupported-device path and the scan library.
final class LidarScannerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = [], usdFixture: Data? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetScans"] + arguments
        if let usdFixture {
            app.launchEnvironment["UITestUSDZFixture"] = usdFixture.base64EncodedString()
        }
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

    func testRoomAndObjectScansOfferSTLExport() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ExportSample", withExtension: "usdz"))
        let app = launch(["-UITestSeedSampleScans"], usdFixture: try Data(contentsOf: fixture))
        app.buttons["myScansLink"].tap()

        for kind in ["Room", "Object"] {
            let menu = shareMenu(for: kind, in: app)
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            XCTAssertTrue(app.buttons["Share USDZ"].exists)
            app.buttons["Export as STL"].tap()
            let save = app.buttons["Save"]
            XCTAssertTrue(save.waitForExistence(timeout: 15))
            if !save.isEnabled {
                app.buttons["On My iPhone"].firstMatch.tap()
            }
            save.tap()
            XCTAssertTrue(save.waitForNonExistence(timeout: 10))
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
        }
    }

    func testInvalidScanShowsExportErrorAndKeepsOriginal() {
        let app = launch(["-UITestSeedSampleScans"])
        app.buttons["myScansLink"].tap()
        let menu = shareMenu(for: "Room", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["Export as STL"].tap()

        let alert = app.alerts["Couldn't export STL"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["This scan could not be opened as a 3D model."].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(menu.exists)
    }

    private func shareMenu(for kind: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "share-\(kind) ")).firstMatch
    }

    func testSettingsShowsPrintServerURL() {
        let app = launch(["-printBaseURL", "http://192.168.1.5:9000"])
        app.buttons["settingsButton"].tap()
        let field = app.textFields["printBaseURLField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "http://192.168.1.5:9000")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'http://192.168.1.5:9000/print'")).firstMatch.exists)
        app.buttons["settingsDoneButton"].tap()
        XCTAssertTrue(app.buttons["roomScanButton"].waitForExistence(timeout: 5))
    }

    /// Needs the stub server: `python3 scripts/print_stub.py` (port 8765).
    func testPrintUploadsScanAndOpensSTLInShareSheet() throws {
        try requirePrintStub()
        let app = launch(["-UITestSeedSampleScans", "-printBaseURL", Self.stubURL])
        app.buttons["myScansLink"].tap()

        let printButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Room '")).firstMatch
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        let scanName = String(printButton.identifier.dropFirst("print-".count))
        printButton.tap()

        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15), "STL share sheet did not open")
        let caption = shareSheet.otherElements["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.label, scanName, "Share sheet should be sharing \(scanName).stl")
        XCTAssertFalse(app.alerts["Couldn't print scan"].exists)
    }

    func testPrintReportsUnreachableServer() {
        let app = launch(["-UITestSeedSampleScans", "-printBaseURL", "http://127.0.0.1:9"])
        app.buttons["myScansLink"].tap()

        let printButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Object '")).firstMatch
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        printButton.tap()

        let alert = app.alerts["Couldn't print scan"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        alert.buttons["OK"].tap()
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["ActivityListView"].exists)
    }

    private static let stubURL = "http://127.0.0.1:8765"

    private func requirePrintStub() throws {
        let done = expectation(description: "stub health check")
        var reachable = false
        URLSession.shared.dataTask(with: URL(string: "\(Self.stubURL)/health")!) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        guard reachable else {
            XCTFail("Print stub isn't running at \(Self.stubURL); start it with `python3 scripts/print_stub.py`.")
            throw XCTSkip("print stub not running")
        }
    }
}
