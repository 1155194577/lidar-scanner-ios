import CoreVideo
import Foundation
import ImageIO
import simd

/// One TrueDepth frame for a face print (`mode=face`): the front-camera photo in sensor orientation (not rotated or mirrored),
/// the face depth, camera and face poses, and the ARKit face mesh. The server fills in the back of the head and returns a bust STL.
struct FaceCapture: Equatable {
    /// Pinhole intrinsics in pixels of an image `width` × `height`.
    struct Intrinsics: Codable, Equatable {
        var fx: Double
        var fy: Double
        var cx: Double
        var cy: Double
        var width: Int
        var height: Int

        /// From a column-major 3×3 camera matrix defined for `reference` pixels, rescaled to `width` × `height`.
        init(matrix: simd_float3x3, reference: CGSize, width: Int, height: Int) {
            let sx = reference.width > 0 ? Double(width) / Double(reference.width) : 1
            let sy = reference.height > 0 ? Double(height) / Double(reference.height) : 1
            fx = Double(matrix.columns.0.x) * sx
            fy = Double(matrix.columns.1.y) * sy
            cx = Double(matrix.columns.2.x) * sx
            cy = Double(matrix.columns.2.y) * sy
            self.width = width
            self.height = height
        }

        init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
            self.fx = fx
            self.fy = fy
            self.cx = cx
            self.cy = cy
            self.width = width
            self.height = height
        }
    }

    /// TrueDepth depth map, in the same sensor orientation as the photo.
    struct Depth: Equatable {
        /// Metres, row-major; NaN where there is no reading.
        var values: [Float32]
        var width: Int
        var height: Int
        /// In depth-map pixels; nil when the frame had no calibration data (the server then assumes the photo's field of view).
        var intrinsics: Intrinsics?
        /// Column-major 4×4 depth-camera-to-photo-camera transform in metres; nil when it is identity.
        var extrinsics: [Float]?

        var data: Data {
            values.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    static let defaultHeightMM = 100.0

    var photo: Data
    /// Photo pixels.
    var intrinsics: Intrinsics
    /// Column-major ARCamera.transform.
    var cameraTransform: [Float]
    /// How to rotate the photo upright (EXIF 1, 3, 6 or 8).
    var imageOrientation: CGImagePropertyOrientation
    var depth: Depth?
    /// Column-major ARFaceAnchor.transform.
    var faceTransform: [Float]?
    /// ARFaceAnchor.geometry.vertices as xyz triples in face-anchor space (metres).
    var faceVertices: [Float]?
    var heightMM: Double = FaceCapture.defaultHeightMM

    /// The multipart fields of the face contract, in upload order. `photo`, `depth` and `face_vertices` are files.
    func addFields<Form: PrintFormBuilder>(to form: inout Form) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }

        form.addField(name: "mode", value: "face")
        form.addFile(name: "photo", fileName: "face.jpg", contentType: "image/jpeg", data: photo)
        form.addField(name: "image_orientation", value: String(imageOrientation.rawValue))
        form.addField(name: "intrinsics", value: try json(intrinsics))
        form.addField(name: "camera_transform", value: try json(cameraTransform))
        if let faceTransform {
            form.addField(name: "face_transform", value: try json(faceTransform))
        }
        if let depth {
            form.addFile(name: "depth", fileName: "depth.f32", contentType: "application/octet-stream", data: depth.data)
            form.addField(name: "depth_width", value: String(depth.width))
            form.addField(name: "depth_height", value: String(depth.height))
            if let intrinsics = depth.intrinsics {
                form.addField(name: "depth_intrinsics", value: try json(intrinsics))
            }
            if let extrinsics = depth.extrinsics {
                form.addField(name: "depth_extrinsics", value: try json(extrinsics))
            }
        }
        if let faceVertices, faceVertices.count >= 3 {
            let data = faceVertices.withUnsafeBufferPointer { Data(buffer: $0) }
            form.addFile(name: "face_vertices", fileName: "face_vertices.f32", contentType: "application/octet-stream", data: data)
            form.addField(name: "face_vertex_count", value: String(faceVertices.count / 3))
        }
        form.addField(name: "height_mm", value: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), heightMM))
    }

    static func columns(_ matrix: simd_float4x4) -> [Float] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    /// Which EXIF orientation turns the sensor-oriented photo upright, from where world up (+Y, gravity-aligned) points
    /// in the camera's frame (x right and y up along the photo's pixel axes).
    static func uprightOrientation(cameraTransform: simd_float4x4) -> CGImagePropertyOrientation {
        let rotation = simd_float3x3(
            SIMD3(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        let up = rotation.transpose * SIMD3<Float>(0, 1, 0)
        if abs(up.y) >= abs(up.x) {
            return up.y >= 0 ? .up : .down
        }
        return up.x < 0 ? .right : .left
    }

    static let identity4x3 = simd_float4x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 0))

    /// A 4×3 calibration extrinsic (translation in millimetres) as a column-major 4×4 in metres, or nil when it is identity.
    static func extrinsics(_ matrix: simd_float4x3) -> [Float]? {
        let identity = FaceCapture.identity4x3
        let isIdentity = (0..<4).allSatisfy { column in
            let delta = abs(matrix[column] - identity[column])
            return max(delta.x, delta.y, delta.z) < (column == 3 ? 0.5 : 1e-4)
        }
        if isIdentity { return nil }
        let t = matrix.columns.3 / 1000
        return [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, 0,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, 0,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, 0,
            t.x, t.y, t.z, 1,
        ]
    }

    /// Reads a `kCVPixelFormatType_DepthFloat32` buffer row by row; zero, negative and non-finite readings become NaN.
    static func depthValues(from buffer: CVPixelBuffer) -> (values: [Float32], width: Int, height: Int)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float32](repeating: .nan, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let value = row[x]
                if value.isFinite, value > 0 { values[y * width + x] = value }
            }
        }
        return (values, width, height)
    }
}
