import XCTest

/// The simulator has no LiDAR or camera, so these cover navigation, the unsupported-device path, the scan library and printing (with a stand-in photo).
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
        XCTAssertTrue(app.buttons["photoPrintButton"].exists)
        XCTAssertTrue(app.buttons["faceScanButton"].exists)
        XCTAssertTrue(app.buttons["myScansLink"].exists)
        XCTAssertEqual(app.staticTexts["scanCount"].label, "0")
    }

    func testHomeRowsRemainTappableWithRunningPrint() throws {
        try assertHomeRowsRemainTappableWithPrint(finished: false)
    }

    func testHomeRowsRemainTappableWithFinishedPrint() throws {
        try assertHomeRowsRemainTappableWithPrint(finished: true)
    }

    private func assertHomeRowsRemainTappableWithPrint(finished: Bool) throws {
        try requirePrintStub()
        let app = launch(["-UITestSeedSampleScans", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken,
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXS"])
        app.buttons["myScansLink"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Room '")).firstMatch.tap()
        XCTAssertTrue(app.scrollViews["printJobBanner"].waitForExistence(timeout: 5))
        if finished {
            XCTAssertTrue(app.buttons["printResultButton"].firstMatch.waitForExistence(timeout: 30))
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["LiDAR Scanner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["printJobBanner"].exists)
        if !finished {
            XCTAssertTrue(app.progressIndicators["printProgressBar"].exists)
        }
        saveScreenshot(app, name: finished ? "home-banner-finished" : "home-banner-running")
        for identifier in ["roomScanButton", "objectScanButton", "photoPrintButton", "faceScanButton", "settingsButton", "myScansLink"] {
            XCTAssertTrue(app.buttons[identifier].isHittable, "Home row \(identifier) is blocked by the banner")
        }
        app.buttons["myScansLink"].tap()
        XCTAssertTrue(app.navigationBars["My Scans"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["guideSkipButton"].waitForExistence(timeout: 5))
        app.buttons["guideSkipButton"].tap()
        XCTAssertTrue(app.staticTexts["Object Scan Unavailable"].waitForExistence(timeout: 5))
        app.buttons["closeButton"].tap()
        XCTAssertTrue(app.buttons["objectScanButton"].waitForExistence(timeout: 5))
    }

    func testObjectScanGuideStepsAndStart() throws {
        let app = launch(["-UITestForceUnsupported"])
        app.buttons["objectScanButton"].tap()
        let label = app.staticTexts["guideStepLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        for step in 1...5 {
            XCTAssertEqual(label.label, "Step \(step) of 5")
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "guide-\(step)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["GUIDE_SCREENSHOT_DIR"] {
                try shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("guide-\(step).png"))
            }
            if step < 5 { app.buttons["guideNextButton"].tap() }
        }
        app.buttons["guideBackButton"].tap()
        XCTAssertEqual(label.label, "Step 4 of 5")
        app.buttons["guideNextButton"].tap()
        app.buttons["guideStartButton"].tap()
        XCTAssertTrue(app.staticTexts["Object Scan Unavailable"].waitForExistence(timeout: 5))
    }

    func testObjectScanShowsMissingPartAndRescanFillsIt() throws {
        let bundle = Bundle(for: Self.self)
        let open = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "OpenBox", withExtension: "usdz")))
        let closed = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "ClosedBox", withExtension: "usdz")))
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetScans", "-UITestFakeObjectCapture"]
        app.launchEnvironment["UITestObjectModelFixture"] = open.base64EncodedString()
        app.launchEnvironment["UITestObjectRescanFixture"] = closed.base64EncodedString()
        app.launch()

        app.buttons["objectScanButton"].tap()
        app.buttons["guideSkipButton"].tap()
        let title = app.staticTexts["gapTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "1 part wasn't captured")
        XCTAssertTrue(app.staticTexts["gapSummary"].label.contains("on the side, about 13 cm across"))
        XCTAssertTrue(app.otherElements["gapModelView"].exists || app.descendants(matching: .any)["gapModelView"].exists)
        sleep(2)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "object-gap"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["GAP_SCREENSHOT_DIR"] {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("object-gap.png"))
        }

        app.buttons["rescanGapButton"].tap()
        let result = app.staticTexts["gapCheckResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertEqual(result.label, "No gaps found. Every side was captured.")
        if let directory = ProcessInfo.processInfo.environment["GAP_SCREENSHOT_DIR"] {
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("object-no-gap.png"))
        }
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["objectScanButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["scanCount"].label, "1")
    }

    func testObjectScanGuideCloseReturnsHome() {
        let app = launch()
        app.buttons["objectScanButton"].tap()
        XCTAssertTrue(app.buttons["guideCloseButton"].waitForExistence(timeout: 5))
        app.buttons["guideCloseButton"].tap()
        XCTAssertTrue(app.buttons["objectScanButton"].waitForExistence(timeout: 5))
    }

    func testEmptyLibrary() {
        let app = launch()
        openMyScans(in: app)
        XCTAssertTrue(app.staticTexts["No Scans Yet"].waitForExistence(timeout: 5))
    }

    func testLibraryListsAndDeletesScans() {
        let app = launch(["-UITestSeedSampleScans"])
        XCTAssertEqual(app.staticTexts["scanCount"].label, "2")
        openMyScans(in: app)

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
        openMyScans(in: app)

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
        let app = launch(["-UITestSeedSampleScans"], usdFixture: Data("not a usdz".utf8))
        openMyScans(in: app)
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
        let app = launch(["-UITestSeedSampleScans", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        openMyScans(in: app)

        let printButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Room '")).firstMatch
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        let scanName = String(printButton.identifier.dropFirst("print-".count))
        printButton.tap()

        XCTAssertTrue(app.progressIndicators["printProgressBar"].waitForExistence(timeout: 5))
        let stage = app.staticTexts["printStage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        XCTAssertTrue(stage.label.contains("Processing:"), stage.label)
        savePrintScreenshot("print-progress", app: app)

        tapSharePrintResult(in: app, timeout: 15)

        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15), "STL share sheet did not open")
        let caption = shareSheet.otherElements["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.label, scanName, "Share sheet should be sharing \(scanName).stl")
        XCTAssertFalse(app.alerts["Couldn't print scan"].exists)
    }

    func testPrintSavesSTLWithItsSourceScan() throws {
        try requirePrintStub()
        let app = launch(["-UITestSeedSampleScans", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        openMyScans(in: app)

        let printButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Room '")).firstMatch
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        let scanName = String(printButton.identifier.dropFirst("print-".count))
        printButton.tap()

        openPrintResult(in: app, timeout: 15)
        let save = app.buttons["Save to Scan"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved to My Scans"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        app.terminate()
        app.launchArguments = []
        app.launch()
        openMyScans(in: app)
        app.buttons["scan-\(scanName)"].tap()

        let fileName = app.staticTexts["savedSTLFilename"]
        XCTAssertTrue(fileName.waitForExistence(timeout: 5))
        XCTAssertEqual(fileName.label, "\(scanName).stl")
        XCTAssertTrue(app.buttons["Preview USDZ"].exists)
        XCTAssertTrue(app.buttons["Share STL"].exists)
        attachScreenshot(app, name: "saved-scan-stl")
        app.buttons["Share STL"].tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 5))
        XCTAssertEqual(shareSheet.otherElements["LP.CaptionBar.TopCaption"].label, scanName)
    }

    func testPrintReportsUnreachableServer() {
        let app = launch(["-UITestSeedSampleScans", "-printBaseURL", "http://127.0.0.1:9"])
        openMyScans(in: app)

        let printButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Object '")).firstMatch
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        printButton.tap()

        XCTAssertTrue(app.staticTexts["printError"].waitForExistence(timeout: 15))
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["ActivityListView"].exists)
    }

    func testPhotoPrintExplainsMissingLiDAR() {
        let app = launch(["-UITestForceUnsupported"])
        app.buttons["photoPrintButton"].tap()
        XCTAssertTrue(app.staticTexts["Photo Print Unavailable"].waitForExistence(timeout: 5))
        app.buttons["closeButton"].tap()
        XCTAssertTrue(app.buttons["photoPrintButton"].waitForExistence(timeout: 5))
    }

    func testPrintStreamFailureShowsDetailAndRetry() throws {
        try requirePrintStub()
        let app = launch(["-UITestSeedSampleScans", "-printBaseURL", Self.stubURL + "/fail", "-printAPIToken", Self.stubToken])
        openMyScans(in: app)
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Room '")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let error = app.staticTexts["printError"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertEqual(error.label, "Stub failed during repair")
        XCTAssertTrue(app.buttons["retryPrintButton"].exists)
        savePrintScreenshot("print-failure", app: app)
        app.buttons["retryPrintButton"].tap()
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(button.exists)
    }

    private func savePrintScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["PRINT_SHOTS_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    func testPhotoPrintContinuesOnRoomScreen() throws {
        try requirePrintStub()
        let app = launch(["-UITestFakePhotoCapture", "-UITestFakePitch", "5", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        app.buttons["photoPrintButton"].tap()
        XCTAssertTrue(app.buttons["takePhotoAndPrintButton"].waitForExistence(timeout: 5))
        app.buttons["takePhotoAndPrintButton"].tap()
        XCTAssertTrue(app.staticTexts["printStage"].waitForExistence(timeout: 5))
        app.buttons["closeButton"].tap()
        app.buttons["roomScanButton"].tap()
        XCTAssertTrue(app.staticTexts["Room Scan Unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.progressIndicators["printProgressBar"].exists)
        XCTAssertTrue(app.staticTexts["printStage"].label.contains("Processing:"))
        savePrintScreenshot("print-banner-room", app: app)
        tapSharePrintResult(in: app, timeout: 20)
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5))
    }

    func testPhotoPrintSendsPhotoAndHeightAndOpensSTL() throws {
        try requirePrintStub()
        let app = launch(["-UITestFakePhotoCapture", "-UITestFakePitch", "5", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        app.buttons["photoPrintButton"].tap()

        XCTAssertEqual(app.staticTexts["photoHeight"].waitForExistence(timeout: 5) ? app.staticTexts["photoHeight"].label : nil, "Height: 120 mm")
        app.buttons["takePhotoAndPrintButton"].tap()
        tapSharePrintResult(in: app, timeout: 15)

        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15), "STL share sheet did not open")
        let caption = shareSheet.otherElements["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(caption.label.hasPrefix("Photo "), "Unexpected shared file \(caption.label)")
        XCTAssertFalse(app.alerts["Couldn't print photo"].exists)

        let received = try lastStubRequest()
        XCTAssertEqual(received["fields"] as? [String], ["camera_transform", "depth", "depth_confidence", "depth_height", "depth_width", "height_mm", "image_orientation", "intrinsics", "job_id", "object_points", "photo"])
        XCTAssertEqual(received["depth_width"] as? Int, 48)
        XCTAssertEqual(received["depth_height"] as? Int, 64)
        XCTAssertEqual((received["object_points"] as? [[Double]])?.count, 2)
        XCTAssertEqual(received["uploaded"] as? [String], ["photo", "depth", "depth_confidence"])
    }

    func testPhotoPrintRenewsExpiredUploadURLAndReuploadsMissingFile() throws {
        try requirePrintStub()
        try printPhoto(baseURL: Self.stubURL + "/expire-drop")
        let received = try lastStubRequest()
        XCTAssertEqual(received["uploaded"] as? [String], ["photo", "depth", "depth_confidence"])
        let stats = try XCTUnwrap(received["upload_stats"] as? [String: Int])
        XCTAssertEqual(stats["rejected_puts"], 3, "each file's expired first URL should be refused once")
        XCTAssertEqual(stats["conflicts"], 1)
        XCTAssertEqual(stats["puts"], 4, "three files plus the one the server reported missing")
    }

    func testPhotoPrintFallsBackToMultipartWithoutSignedUploads() throws {
        try requirePrintStub()
        try printPhoto(baseURL: Self.stubURL + "/legacy")
        let received = try lastStubRequest()
        XCTAssertNil(received["uploaded"])
        XCTAssertEqual(received["fields"] as? [String], ["camera_transform", "depth", "depth_confidence", "depth_height", "depth_width", "height_mm", "image_orientation", "intrinsics", "job_id", "object_points", "photo"])
    }

    func testPhotoPrintFallsBackToMultipartWhenStorageDeniesEveryUpload() throws {
        try requirePrintStub()
        try printPhoto(baseURL: Self.stubURL + "/deny")
        let received = try lastStubRequest()
        XCTAssertNil(received["uploaded"])
        XCTAssertTrue((received["fields"] as? [String])?.contains("photo") ?? false, "the photo should go in the multipart POST")
        let stats = try XCTUnwrap(received["upload_stats"] as? [String: Int])
        XCTAssertEqual(stats["puts"], 0)
        XCTAssertGreaterThan(stats["rejected_puts"] ?? 0, 0)
    }

    private func printPhoto(baseURL: String) throws {
        let app = launch(["-UITestFakePhotoCapture", "-UITestFakePitch", "5", "-printBaseURL", baseURL, "-printAPIToken", Self.stubToken])
        app.buttons["photoPrintButton"].tap()
        XCTAssertTrue(app.buttons["takePhotoAndPrintButton"].waitForExistence(timeout: 5))
        app.buttons["takePhotoAndPrintButton"].tap()
        tapSharePrintResult(in: app, timeout: 20)
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15), "STL share sheet did not open")
        XCTAssertFalse(app.alerts["Couldn't print photo"].exists)
    }

    func testPhotoCheckFlagsSteepShotAndCanPrintAnyway() throws {
        try requirePrintStub()
        let app = launch(["-UITestFakePhotoCapture", "-UITestFakePitch", "50", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        app.buttons["photoPrintButton"].tap()
        app.buttons["takePhotoAndPrintButton"].tap()

        let alert = app.alerts["Retake the photo?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "Steep shot was not flagged")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS '50° down'")).firstMatch.exists)
        saveScreenshot(app, name: "photo-check-steep-flagged")

        alert.buttons["Retake"].tap()
        XCTAssertFalse(alert.exists)
        XCTAssertTrue(app.buttons["takePhotoAndPrintButton"].isEnabled)

        app.buttons["takePhotoAndPrintButton"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        alert.buttons["Print Anyway"].tap()
        tapSharePrintResult(in: app, timeout: 15)
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15), "Print anyway did not print")
    }

    func testPhotoCheckPassesLevelShot() throws {
        try requirePrintStub()
        let app = launch(["-UITestFakePhotoCapture", "-UITestFakePitch", "5", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        app.buttons["photoPrintButton"].tap()
        app.buttons["takePhotoAndPrintButton"].tap()

        let result = app.buttons["printResultButton"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Level shot did not go straight to print")
        XCTAssertFalse(app.alerts["Retake the photo?"].exists)
        saveScreenshot(app, name: "photo-check-level-passed")
    }

    /// Attaches a screenshot; with `TEST_RUNNER_SHOT_DIR` set it is also written there as `<name>.png`.
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testFaceScanExplainsMissingTrueDepth() {
        let app = launch(["-UITestForceUnsupported"])
        app.buttons["faceScanButton"].tap()
        XCTAssertTrue(app.staticTexts["Face Scan Unavailable"].waitForExistence(timeout: 5))
        app.buttons["closeButton"].tap()
        XCTAssertTrue(app.buttons["faceScanButton"].waitForExistence(timeout: 5))
    }

    /// Needs the stub server: `python3 scripts/print_stub.py` (port 8765).
    func testFaceScanUploadsFaceDepthAndOpensBustSTL() throws {
        try requirePrintStub()
        let app = launch(["-UITestFakeFaceCapture", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        app.buttons["faceScanButton"].tap()

        let height = app.staticTexts["bustHeight"]
        XCTAssertTrue(height.waitForExistence(timeout: 5))
        XCTAssertEqual(height.label, "Bust height: 100 mm")
        app.steppers["bustHeightStepper"].buttons.element(boundBy: 1).tap()
        XCTAssertEqual(height.label, "Bust height: 110 mm")
        tapCaptureFace(in: app)

        assertShareSheet(in: app, captionPrefix: "Face ", errorAlert: "Couldn't print face", timeout: 15)
        attachScreenshot(app, name: "face-stl")

        let last = try lastStubRequest()
        XCTAssertEqual(last["mode"] as? String, "face")
        XCTAssertEqual(last["depth_width"] as? Int, 64)
        XCTAssertEqual(last["depth_height"] as? Int, 48)
        XCTAssertEqual(last["face_vertex_count"] as? Int, 4)
        XCTAssertEqual(last["height_mm"] as? Double, 110)
        XCTAssertEqual((last["face_transform"] as? [Double])?.count, 16)
        XCTAssertNotNil(last["depth_intrinsics"] as? [String: Any])
    }

    func testFacePrintCanBeSavedToMyScans() throws {
        try requirePrintStub()
        let app = launch(["-UITestResetScans", "-UITestFakeFaceCapture", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        app.buttons["faceScanButton"].tap()
        tapCaptureFace(in: app)

        openPrintResult(in: app, timeout: 15)
        let save = app.buttons["Save to My Scans"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved to My Scans"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["closeButton"].tap()
        openMyScans(in: app)
        XCTAssertTrue(app.staticTexts["Face Prints"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'scan-Face '")).firstMatch.tap()

        let fileName = app.staticTexts["savedSTLFilename"]
        XCTAssertTrue(fileName.waitForExistence(timeout: 5))
        XCTAssertTrue(fileName.label.hasSuffix(".stl"))
        XCTAssertFalse(app.buttons["Preview USDZ"].exists)
    }

    func testPhotoPrintCanBeSavedAsAStandaloneSTL() throws {
        try requirePrintStub()
        let app = launch(["-UITestFakePhotoCapture", "-UITestFakePitch", "5", "-printBaseURL", Self.stubURL, "-printAPIToken", Self.stubToken])
        app.buttons["photoPrintButton"].tap()
        app.buttons["takePhotoAndPrintButton"].tap()

        openPrintResult(in: app, timeout: 15)
        let save = app.buttons["Save to My Scans"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved to My Scans"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["closeButton"].tap()
        openMyScans(in: app)
        XCTAssertTrue(app.staticTexts["Photo Prints"].waitForExistence(timeout: 5))
        let photoPrint = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'scan-Photo '")).firstMatch
        photoPrint.tap()

        let fileName = app.staticTexts["savedSTLFilename"]
        XCTAssertTrue(fileName.waitForExistence(timeout: 5))
        XCTAssertTrue(fileName.label.hasSuffix(".stl"))
        XCTAssertFalse(app.buttons["Preview USDZ"].exists)
        XCTAssertTrue(app.buttons["Share STL"].exists)
    }

    func testPrintWithWrongTokenAsksToCheckSettings() throws {
        try requirePrintStub()
        let app = launch(["-UITestSeedSampleScans", "-printBaseURL", Self.stubURL, "-printAPIToken", "wrong"])
        openMyScans(in: app)
        let printButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Room '")).firstMatch
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        printButton.tap()

        XCTAssertTrue(app.staticTexts["printError"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["printError"].label.contains("print token in Settings"))
    }

    /// Runs against the deployed endpoint only when `TEST_RUNNER_PRINT_LIVE_URL` and `TEST_RUNNER_PRINT_LIVE_TOKEN` are set for `xcodebuild test`.
    func testLivePrintScanAndPhoto() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["PRINT_LIVE_URL"], let token = environment["PRINT_LIVE_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_PRINT_LIVE_URL and TEST_RUNNER_PRINT_LIVE_TOKEN to test the live endpoint")
        }
        let app = launch(["-UITestSeedSampleScans", "-UITestFakePhotoCapture", "-UITestFakePitch", "5", "-printBaseURL", url, "-printAPIToken", token])

        openMyScans(in: app)
        let printButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'print-Object '")).firstMatch
        XCTAssertTrue(printButton.waitForExistence(timeout: 5))
        let scanName = String(printButton.identifier.dropFirst("print-".count))
        printButton.tap()
        assertShareSheet(in: app, captionPrefix: scanName, errorAlert: "Couldn't print scan", timeout: 360)
        attachScreenshot(app, name: "live-scan-stl")
        app.otherElements["ActivityListView"].buttons["header.closeButton"].firstMatch.tapIfExists()
        app.swipeDown(velocity: .fast)
        app.buttons["Done"].tapIfExists()

        app.buttons["Dismiss"].firstMatch.tap()
        XCTAssertFalse(app.buttons["printResultButton"].firstMatch.exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["photoPrintButton"].tap()
        XCTAssertTrue(app.staticTexts["photoHeight"].waitForExistence(timeout: 5))
        app.buttons["takePhotoAndPrintButton"].tap()
        assertShareSheet(in: app, captionPrefix: "Photo ", errorAlert: "Couldn't print photo", timeout: 360)
        attachScreenshot(app, name: "live-photo-stl")
    }

    /// Finished print jobs in the banner can cover the My Scans row, so dismiss them first.
    private func openMyScans(in app: XCUIApplication) {
        for _ in 0..<5 where app.buttons["Dismiss"].firstMatch.exists {
            app.buttons["Dismiss"].firstMatch.tap()
        }
        app.buttons["myScansLink"].tap()
    }

    /// Runs a fake face capture against the deployed endpoint only when `TEST_RUNNER_PRINT_LIVE_URL` and `TEST_RUNNER_PRINT_LIVE_TOKEN` are set.
    func testLiveFacePrint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["PRINT_LIVE_URL"], let token = environment["PRINT_LIVE_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_PRINT_LIVE_URL and TEST_RUNNER_PRINT_LIVE_TOKEN to test the live endpoint")
        }
        let app = launch(["-UITestResetScans", "-UITestFakeFaceCapture", "-printBaseURL", url, "-printAPIToken", token])
        app.buttons["faceScanButton"].tap()
        XCTAssertTrue(app.staticTexts["bustHeight"].waitForExistence(timeout: 5))
        app.buttons["captureFaceButton"].tap()
        openPrintResult(in: app, timeout: 600)
        let save = app.buttons["Save to My Scans"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "live-face-stl")
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved to My Scans"].waitForExistence(timeout: 5))
    }

    /// Waits for a print job in the banner to finish, then opens its Save / Share sheet.
    /// The capture button stays disabled until the (fake) face is detected, and a tap before then does nothing.
    private func tapCaptureFace(in app: XCUIApplication) {
        let capture = app.buttons["captureFaceButton"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: capture)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "No face detected")
        capture.tap()
    }

    private func openPrintResult(in app: XCUIApplication, timeout: TimeInterval) {
        let result = app.buttons["printResultButton"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: timeout), "Print job did not finish")
        result.tap()
    }

    private func tapSharePrintResult(in app: XCUIApplication, timeout: TimeInterval) {
        openPrintResult(in: app, timeout: timeout)
        let share = app.buttons["Share STL"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "Print result did not open")
        share.tap()
    }

    private func assertShareSheet(in app: XCUIApplication, captionPrefix: String, errorAlert: String, timeout: TimeInterval) {
        tapSharePrintResult(in: app, timeout: timeout)
        let shareSheet = app.otherElements["ActivityListView"]
        let alert = app.alerts[errorAlert]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !shareSheet.exists, !alert.exists { _ = shareSheet.waitForExistence(timeout: 2) }
        if alert.exists {
            XCTFail("\(errorAlert): \(alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " "))")
            return
        }
        XCTAssertTrue(shareSheet.exists, "STL share sheet did not open within \(Int(timeout)) s")
        // The link preview fills in its caption after the sheet appears, sometimes several seconds later.
        let caption = shareSheet.descendants(matching: .any)["LP.CaptionBar.TopCaption"]
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", captionPrefix), object: caption)
        let result = XCTWaiter.wait(for: [named], timeout: 15)
        XCTAssertEqual(result, .completed, "Unexpected shared file \(caption.exists ? caption.label : "(no caption)")")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func lastStubRequest() throws -> [String: Any] {
        let done = expectation(description: "stub last request")
        var body = Data()
        URLSession.shared.dataTask(with: URL(string: "\(Self.stubURL)/last")!) { data, _, _ in
            body = data ?? Data()
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any], "GET /last returned no JSON")
    }

    private static let stubURL = "http://127.0.0.1:8765"
    private static let stubToken = "stub-token"

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

private extension XCUIElement {
    func tapIfExists() {
        if exists { tap() }
    }
}
