import ImageIO
import CoreGraphics
import Foundation

/// Pinhole intrinsics in pixels of an image `width` × `height`.
struct CameraIntrinsics: Codable, Equatable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var width: Int
    var height: Int
}

/// Where the camera was for the uploaded photo, so the server knows which way is up.
struct CameraPose: Equatable {
    /// Column-major camera-to-world matrix whose camera x/y axes match the uploaded photo's pixel axes
    /// (x right, y up, z towards the viewer); world +Y is up.
    var cameraTransform: [Float]
    /// How to rotate the photo upright (EXIF orientation 1, 3, 6 or 8); 1 when the photo is already upright.
    var imageOrientation: CGImagePropertyOrientation
}

/// LiDAR data from the frame the photo was taken from. Everything is in sensor orientation, like the uploaded photo.
struct DepthCapture: Equatable {
    /// Metres, row-major; NaN where there is no reading.
    var depth: [Float32]
    /// ARKit confidence 0 (low), 1 (medium), 2 (high), same layout as `depth`.
    var confidence: [UInt8]?
    var width: Int
    var height: Int
    /// For the uploaded photo; the depth map shares its field of view.
    var intrinsics: CameraIntrinsics
    /// The measured base and top of the object, projected into the photo's pixels.
    var objectPoints: [CGPoint]

    var depthData: Data {
        depth.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
