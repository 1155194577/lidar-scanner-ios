import CoreVideo
import XCTest
import simd
@testable import LidarScanner

final class FaceCaptureTests: XCTestCase {
    func testFaceRequestSendsTheFaceContract() throws {
        var capture = FaceScanModel.sampleCapture(heightMM: 120)
        capture.photo = Data("jpeg".utf8)
        let request = try PrintService(baseURL: "http://localhost:8765").makeRequest(for: .face(capture), boundary: "B")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)

        XCTAssertTrue(body.contains("name=\"mode\"\r\n\r\nface\r\n"))
        XCTAssertTrue(body.contains("name=\"photo\"; filename=\"face.jpg\"\r\nContent-Type: image/jpeg\r\n\r\njpeg\r\n"))
        XCTAssertTrue(body.contains("name=\"image_orientation\"\r\n\r\n1\r\n"))
        XCTAssertTrue(body.contains("name=\"intrinsics\"\r\n\r\n{\"cx\":240,\"cy\":320,\"fx\":500,\"fy\":500,\"height\":640,\"width\":480}\r\n"))
        XCTAssertTrue(body.contains("name=\"camera_transform\"\r\n\r\n[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]\r\n"))
        XCTAssertTrue(body.contains("name=\"face_transform\"\r\n\r\n[1,0,0,0,0,1,0,0,0,0,1,0,0,0,-0.4"))
        XCTAssertTrue(body.contains("name=\"depth\"; filename=\"depth.f32\""))
        XCTAssertTrue(body.contains("name=\"depth_width\"\r\n\r\n64\r\n"))
        XCTAssertTrue(body.contains("name=\"depth_height\"\r\n\r\n48\r\n"))
        XCTAssertTrue(body.contains("name=\"depth_intrinsics\"\r\n\r\n{\"cx\":32,\"cy\":24,"))
        XCTAssertFalse(body.contains("name=\"depth_extrinsics\""))
        XCTAssertTrue(body.contains("name=\"face_vertices\"; filename=\"face_vertices.f32\""))
        XCTAssertTrue(body.contains("name=\"face_vertex_count\"\r\n\r\n4\r\n"))
        XCTAssertTrue(body.contains("name=\"height_mm\"\r\n\r\n120.0\r\n"))
        XCTAssertFalse(body.contains("name=\"mesh\""))
    }

    func testTurnHeadViewsArePrefixedAndCounted() throws {
        var capture = FaceScanModel.sampleCapture(heightMM: 100)
        capture.photo = Data("jpeg".utf8)
        capture.extraViews = [FaceScanModel.sampleView(yaw: 30), FaceScanModel.sampleView(yaw: -60)]
        capture.extraViews[1].depth = nil
        let body = String(decoding: try XCTUnwrap(PrintService(baseURL: "http://localhost:8765").makeRequest(for: .face(capture), boundary: "B").httpBody), as: UTF8.self)

        XCTAssertTrue(body.contains("name=\"view_count\"\r\n\r\n3\r\n"))
        XCTAssertTrue(body.contains("name=\"view_1_photo\"; filename=\"view_1_face.jpg\"\r\nContent-Type: image/jpeg"))
        XCTAssertTrue(body.contains("name=\"view_1_yaw_deg\"\r\n\r\n30.0\r\n"))
        XCTAssertTrue(body.contains("name=\"view_1_depth\"; filename=\"view_1_depth.f32\""))
        XCTAssertTrue(body.contains("name=\"view_1_depth_width\"\r\n\r\n64\r\n"))
        XCTAssertTrue(body.contains("name=\"view_1_face_transform\""))
        XCTAssertTrue(body.contains("name=\"view_2_camera_transform\""))
        XCTAssertTrue(body.contains("name=\"view_2_yaw_deg\"\r\n\r\n-60.0\r\n"))
        XCTAssertFalse(body.contains("name=\"view_2_depth\""))
        XCTAssertFalse(body.contains("name=\"view_3_"))
        XCTAssertEqual(body.components(separatedBy: "name=\"face_vertices\"").count, 2)

        let files = try PrintService(baseURL: "http://localhost:8765").payload(for: .face(capture)).files.map(\.name)
        XCTAssertEqual(files, ["photo", "depth", "face_vertices", "view_1_photo", "view_1_depth", "view_2_photo"])
    }

    func testFrontOnlyCaptureSendsNoViewFields() throws {
        let body = String(decoding: try XCTUnwrap(PrintService(baseURL: "http://localhost:8765").makeRequest(for: .face(FaceScanModel.sampleCapture(heightMM: 100))).httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"view_"))
    }

    func testYawIsPositiveWhenTheHeadTurnsToItsOwnLeft() {
        let camera = matrix_identity_float4x4
        func face(_ degrees: Float) -> simd_float4x4 {
            var m = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
            m.columns.3 = SIMD4(0, 0, -0.4, 1)
            return m
        }
        XCTAssertEqual(FaceCapture.yawDegrees(faceTransform: face(0), cameraTransform: camera), 0, accuracy: 1e-3)
        XCTAssertEqual(FaceCapture.yawDegrees(faceTransform: face(30), cameraTransform: camera), 30, accuracy: 1e-3)
        XCTAssertEqual(FaceCapture.yawDegrees(faceTransform: face(-60), cameraTransform: camera), -60, accuracy: 1e-3)
        // Tilting the head forward is not yaw.
        var nod = simd_float4x4(simd_quatf(angle: 0.3, axis: SIMD3(1, 0, 0)))
        nod.columns.3 = SIMD4(0, 0, -0.4, 1)
        XCTAssertEqual(FaceCapture.yawDegrees(faceTransform: nod, cameraTransform: camera), 0, accuracy: 1e-3)
        // The phone moving to the head's right (-x) shows the head turned to its own left.
        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4(-0.4, 0, 0, 1)
        XCTAssertEqual(FaceCapture.yawDegrees(faceTransform: face(0), cameraTransform: moved), 45, accuracy: 1e-3)
    }

    func testDepthUploadIsLittleEndianFloat32() throws {
        let depth = FaceCapture.Depth(values: [0.5, .nan], width: 2, height: 1)
        let data = depth.data
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual(Array(data.prefix(4)), [0x00, 0x00, 0x00, 0x3F])
    }

    func testFaceWithoutDepthOmitsDepthFields() throws {
        var capture = FaceScanModel.sampleCapture(heightMM: 100)
        capture.depth = nil
        capture.faceVertices = nil
        let body = String(decoding: try XCTUnwrap(PrintService(baseURL: "http://localhost:8765").makeRequest(for: .face(capture)).httpBody), as: UTF8.self)
        for field in ["depth", "depth_width", "depth_intrinsics", "face_vertices", "face_vertex_count"] {
            XCTAssertFalse(body.contains("name=\"\(field)\""), field)
        }
        XCTAssertTrue(body.contains("name=\"camera_transform\""))
    }

    func testIntrinsicsScaleToTheTargetResolution() {
        let matrix = simd_float3x3(SIMD3(2000, 0, 0), SIMD3(0, 2000, 0), SIMD3(1000, 750, 1))
        let scaled = FaceCapture.Intrinsics(matrix: matrix, reference: CGSize(width: 4000, height: 3000), width: 640, height: 480)
        XCTAssertEqual(scaled, FaceCapture.Intrinsics(fx: 320, fy: 320, cx: 160, cy: 120, width: 640, height: 480))
    }

    func testUprightOrientationFollowsWorldUp() {
        func rotation(_ degrees: Float) -> simd_float4x4 {
            simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 0, 1)))
        }
        XCTAssertEqual(FaceCapture.uprightOrientation(cameraTransform: matrix_identity_float4x4), .up)
        XCTAssertEqual(FaceCapture.uprightOrientation(cameraTransform: rotation(180)), .down)
        // Rolled -90° (portrait for a landscape sensor): world up lies along the photo's -x, so it is rotated 90° clockwise to display.
        XCTAssertEqual(FaceCapture.uprightOrientation(cameraTransform: rotation(-90)), .right)
        XCTAssertEqual(FaceCapture.uprightOrientation(cameraTransform: rotation(90)), .left)
    }

    func testExtrinsicsAreNilForIdentityAndMetresOtherwise() {
        XCTAssertNil(FaceCapture.extrinsics(FaceCapture.identity4x3))
        var shifted = FaceCapture.identity4x3
        shifted.columns.3 = SIMD3(12, 0, 0)
        let extrinsics = FaceCapture.extrinsics(shifted)
        XCTAssertEqual(extrinsics?.count, 16)
        XCTAssertEqual(extrinsics?[12] ?? 0, 0.012, accuracy: 1e-6)
        XCTAssertEqual(extrinsics?[15], 1)
    }

    func testDepthValuesReadPaddedRowsAndMarkHoles() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_DepthFloat32, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let rows: [[Float32]] = [[0.3, 0, .infinity], [0.31, -1, 0.32]]
        for (y, row) in rows.enumerated() {
            let pointer = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for (x, value) in row.enumerated() { pointer[x] = value }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        let map = try XCTUnwrap(FaceCapture.depthValues(from: pixels))
        XCTAssertEqual(map.width, 3)
        XCTAssertEqual(map.height, 2)
        XCTAssertEqual(map.values[0], 0.3)
        XCTAssertTrue(map.values[1].isNaN)
        XCTAssertTrue(map.values[2].isNaN)
        XCTAssertEqual(map.values[3], 0.31)
        XCTAssertTrue(map.values[4].isNaN)
        XCTAssertEqual(map.values[5], 0.32)
    }
}
