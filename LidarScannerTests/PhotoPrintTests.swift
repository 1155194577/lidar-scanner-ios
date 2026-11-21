import XCTest
@testable import LidarScanner

final class PhotoPrintTests: XCTestCase {
    func testPhotoOrientationFollowsInterfaceOrientation() {
        XCTAssertEqual(PhotoPrintModel.photoOrientation(for: .portrait), .right)
        XCTAssertEqual(PhotoPrintModel.photoOrientation(for: .portraitUpsideDown), .left)
        XCTAssertEqual(PhotoPrintModel.photoOrientation(for: .landscapeRight), .up)
        XCTAssertEqual(PhotoPrintModel.photoOrientation(for: .landscapeLeft), .down)
    }
}
