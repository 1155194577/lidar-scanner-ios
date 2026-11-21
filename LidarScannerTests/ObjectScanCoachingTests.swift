import XCTest
import RealityKit
import SwiftUI
@testable import LidarScanner

final class ObjectScanCoachingTests: XCTestCase {
    func testEmptyFeedbackHasNoOverride() {
        XCTAssertNil(ObjectScanCoaching.feedbackMessage([]))
    }

    func testFeedbackPriorityAndMessages() {
        XCTAssertEqual(ObjectScanCoaching.feedbackMessage([.movingTooFast, .environmentTooDark]), "Turn on more light")
        XCTAssertEqual(ObjectScanCoaching.feedbackMessage([.objectTooClose]), "Move back a little")
        XCTAssertEqual(ObjectScanCoaching.feedbackMessage([.objectTooFar]), "Move closer to the object")
        XCTAssertEqual(ObjectScanCoaching.feedbackMessage([.movingTooFast]), "Slow down")
        if #available(iOS 17.4, *) {
            XCTAssertEqual(ObjectScanCoaching.feedbackMessage([.objectNotDetected]), "Point the camera at the object")
        }
        for feedback: ObjectCaptureSession.Feedback in [.environmentLowLight, .outOfFieldOfView, .overCapturing, .objectNotFlippable] {
            XCTAssertNotNil(ObjectScanCoaching.feedbackMessage([feedback]))
        }
    }

    func testPassInstructionsAndRecommendations() {
        XCTAssertTrue(ObjectScanCoaching.instruction(pass: 1, completed: false).contains("chest height"))
        XCTAssertTrue(ObjectScanCoaching.instruction(pass: 2, completed: false).contains("lower angle"))
        XCTAssertTrue(ObjectScanCoaching.instruction(pass: 3, completed: false).contains("high above"))
        XCTAssertTrue(ObjectScanCoaching.instruction(pass: 1, completed: true).contains("lower angle"))
        XCTAssertTrue(ObjectScanCoaching.instruction(pass: 2, completed: true).contains("flip"))
        XCTAssertTrue(ObjectScanCoaching.instruction(pass: 3, completed: true).contains("Finish"))
    }
}
