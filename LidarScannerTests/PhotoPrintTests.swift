import XCTest
@testable import LidarScanner

final class PhotoPrintTests: XCTestCase {
    func testPhotoOrientationFollowsInterfaceOrientation() {
        XCTAssertEqual(PhotoPrintModel.photoOrientation(for: .portrait), .right)
        XCTAssertEqual(PhotoPrintModel.photoOrientation(for: .portraitUpsideDown), .left)
        XCTAssertEqual(PhotoPrintModel.photoOrientation(for: .landscapeRight), .up)
        XCTAssertEqual(PhotoPrintModel.photoOrientation(for: .landscapeLeft), .down)
    }

    @MainActor
    func testModelVerdictSurvivesJobPersistenceAndResultPresentation() throws {
        let check = PrintModelCheck(ok: false, sides: [.init(side: "back", ok: false, message: "Snap the back.")],
                                    retakeSide: "back", suggestScan: false)
        var job = PrintJob(id: UUID().uuidString, name: "Photo", kind: "photo", baseURL: "http://print.test")
        job.modelCheck = check
        job.result = PrintJobManager.directory.appendingPathComponent("result.stl")
        let restored = try JSONDecoder().decode(PrintJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.modelCheck, check)
        let suite = "PhotoPrintTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PrintJobManager(defaults: defaults, notifications: false)
        XCTAssertEqual(manager.printedModel(for: restored)?.modelCheck, check)
        XCTAssertNil(manager.printedModel(for: restored)?.retakeContext)
    }

    @MainActor
    func testRetakeUsesOriginalPrimaryAndOnlyAllowsOneExtraShot() throws {
        let model = PhotoPrintModel(fake: true)
        let primary = PhotoPrintModel.Shot(photo: Data("original-photo".utf8),
            pose: PhotoPrintModel.samplePose(pitchDegrees: 5), depth: PhotoPrintModel.sampleDepth,
            checkPhoto: Data(), checkPose: PhotoPrintModel.samplePose(pitchDegrees: 5))
        let context = PhotoRetakeContext(model: model, primary: primary, heightMM: 120)
        let suite = "PhotoRetakeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in
            throw PrintError.lostContact
        })
        XCTAssertTrue(context.submit(side: "back", using: manager))
        XCTAssertTrue(context.used)
        XCTAssertFalse(context.submit(side: "back", using: manager))
        let job = try XCTUnwrap(manager.jobs.first)
        defer { manager.dismiss(job) }
        let payload = try PrintPayload.load(from: PrintJobManager.directory.appendingPathComponent(job.id).appendingPathComponent("payload"))
        XCTAssertEqual(payload.files.first(where: { $0.name == "photo" })?.data, primary.photo)
        XCTAssertEqual(payload.fields.first(where: { $0.name == "view_1_side" })?.value, "back")
        XCTAssertTrue(payload.files.contains { $0.name == "view_1_depth" })
        XCTAssertEqual(manager.jobs.count, 1)
    }
}
