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
    /// Column-major camera-to-world matrix (ARKit camera axes: x right, y up, z towards the viewer); world +Y is up.
    var cameraTransform: [Float]
    /// The user's taps on the object (base, then top), in photo pixels.
    var objectPoints: [CGPoint]
    /// How to rotate the photo upright (EXIF orientation 1, 3, 6 or 8).
    var imageOrientation: CGImagePropertyOrientation

    var depthData: Data {
        depth.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
