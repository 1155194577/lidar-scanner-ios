import RealityKit
import SwiftUI

enum ObjectScanCoaching {
    static func feedbackMessage(_ feedback: Set<ObjectCaptureSession.Feedback>) -> String? {
        if #available(iOS 17.4, *), feedback.contains(.objectNotDetected),
           !feedback.contains(.environmentTooDark), !feedback.contains(.environmentLowLight) {
            return "Point the camera at the object"
        }
        let priorities: [(ObjectCaptureSession.Feedback, String)] = [
            (.environmentTooDark, "Turn on more light"),
            (.environmentLowLight, "Move to brighter, even light"),
            (.outOfFieldOfView, "Keep the whole object in the frame"),
            (.objectTooClose, "Move back a little"),
            (.objectTooFar, "Move closer to the object"),
            (.movingTooFast, "Slow down"),
            (.overCapturing, "This angle has enough photos. Move to a new angle"),
            (.objectNotFlippable, "Keep the object still. Use a high angle instead of flipping it")
        ]
        return priorities.first { feedback.contains($0.0) }?.1
    }

    static func instruction(pass: Int, completed: Bool) -> String {
        if completed {
            switch pass {
            case ...1: return "Pass 1 complete. Next, circle again from a lower angle, near object height."
            case 2: return "Pass 2 complete. Next, flip a rigid object onto its side or scan from high above."
            default: return "Three passes complete. Tap Finish to build your model."
            }
        }
        switch pass {
        case ...1: return "Pass 1: hold the phone at chest height, about 30–60 cm away. Circle slowly as the ring fills. Keep the object centred and still."
        case 2: return "Pass 2: circle from a lower angle, near object height. Keep the object centred and still."
        default: return "Pass 3: flip a rigid object onto its side before starting, or circle from high above. Keep it still during the pass."
        }
    }
}
