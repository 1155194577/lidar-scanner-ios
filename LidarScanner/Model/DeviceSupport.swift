import ARKit
import RealityKit
import RoomPlan
import SwiftUI

enum DeviceSupport {
    @MainActor
    static var roomScan: Bool {
        !LaunchArguments.contains(LaunchArguments.forceUnsupported) && RoomCaptureSession.isSupported
    }

    @MainActor
    static var objectScan: Bool {
        !LaunchArguments.contains(LaunchArguments.forceUnsupported)
            && ObjectCaptureSession.isSupported
            && PhotogrammetrySession.isSupported
    }

    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
}
