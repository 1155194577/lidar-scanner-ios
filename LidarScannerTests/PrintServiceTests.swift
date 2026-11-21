import XCTest
@testable import LidarScanner

final class PrintServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        StubProtocol.handler = nil
    }

    func testEndpointAppendsPrintToBaseURL() throws {
        XCTAssertEqual(try PrintService(baseURL: "http://192.168.1.5:8765").endpoint.absoluteString, "http://192.168.1.5:8765/print")
        XCTAssertEqual(try PrintService(baseURL: " https://example.com/api/ ").endpoint.absoluteString, "https://example.com/api/print")
    }

    func testRejectsInvalidBaseURL() {
        for value in ["", "localhost:8765", "ftp://example.com", "http://"] {
            XCTAssertThrowsError(try PrintService(baseURL: value), value) { error in
                XCTAssertEqual(error as? PrintError, .invalidBaseURL(value))
            }
        }
    }

    func testMeshRequestIsMultipartWithMeshFile() throws {
        let mesh = directory.appendingPathComponent("Room 1.usdz")
        try Data("usdz-bytes".utf8).write(to: mesh)

        let request = try PrintService(baseURL: "http://localhost:8765").makeRequest(for: .mesh(mesh), boundary: "B")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8765/print")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body, """
        --B\r
        Content-Disposition: form-data; name="mesh"; filename="Room 1.usdz"\r
        Content-Type: model/vnd.usdz+zip\r
        \r
        usdz-bytes\r
        --B--\r

        """)
    }

    func testPhotoRequestSendsPhotoAndHeight() throws {
        let request = try PrintService(baseURL: "http://localhost:8765")
            .makeRequest(for: .photo(Data("jpeg".utf8), heightMM: 123.4), boundary: "B")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"photo\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\njpeg\r\n"))
        XCTAssertTrue(body.contains("name=\"height_mm\"\r\n\r\n123.4\r\n"))
        XCTAssertFalse(body.contains("name=\"mesh\""))
    }

    func testPhotoWithDepthSendsFusionFields() throws {
        let depth = DepthCapture(
            depth: [0.5, .nan],
            confidence: [2, 0],
            width: 2,
            height: 1,
            intrinsics: CameraIntrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720, width: 1920, height: 1440),
            objectPoints: [CGPoint(x: 960.04, y: 1000), CGPoint(x: 955.5, y: 400)]
        )
        let pose = CameraPose(cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.1, 1.2, -0.3, 1], imageOrientation: .right)
        let request = try PrintService(baseURL: "http://localhost:8765")
            .makeRequest(for: .photo(Data("jpeg".utf8), heightMM: 120, pose: pose, depth: depth), boundary: "B")
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)

        var floats = Data()
        for value: Float32 in [0.5, .nan] { withUnsafeBytes(of: value.bitPattern.littleEndian) { floats.append(contentsOf: $0) } }
        XCTAssertNotNil(body.range(of: Data("name=\"depth\"; filename=\"depth.f32\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8) + floats + Data("\r\n".utf8)))
        XCTAssertNotNil(body.range(of: Data("filename=\"confidence.u8\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8) + Data([2, 0, 13, 10])))
        XCTAssertTrue(text.contains("name=\"depth_width\"\r\n\r\n2\r\n"))
        XCTAssertTrue(text.contains("name=\"depth_height\"\r\n\r\n1\r\n"))
        XCTAssertTrue(text.contains("name=\"image_orientation\"\r\n\r\n6\r\n"))
        XCTAssertTrue(text.contains("name=\"intrinsics\"\r\n\r\n{\"cx\":960,\"cy\":720,\"fx\":1400,\"fy\":1400,\"height\":1440,\"width\":1920}\r\n"))
        XCTAssertTrue(text.contains("name=\"camera_transform\"\r\n\r\n[1,0,0,0,0,1,0,0,0,0,1,0,0.1"))
        XCTAssertTrue(text.contains("name=\"object_points\"\r\n\r\n[[960,1000],[955.5,400]]\r\n"))
        XCTAssertTrue(text.contains("name=\"height_mm\"\r\n\r\n120.0\r\n"))
    }

    func testPhotoWithoutDepthStillSendsPose() throws {
        let pose = CameraPose(cameraTransform: [1, 0, 0, 0, 0, 0.5, -0.5, 0, 0, 0.5, 0.5, 0, 0, 1, 0, 1], imageOrientation: .up)
        let request = try PrintService(baseURL: "http://localhost:8765")
            .makeRequest(for: .photo(Data("jpeg".utf8), heightMM: 80, pose: pose), boundary: "B")
        let text = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"image_orientation\"\r\n\r\n1\r\n"))
        XCTAssertTrue(text.contains("name=\"camera_transform\"\r\n\r\n[1,0,0,0,0,0.5,-0.5,0,0,0.5,0.5,0,0,1,0,1]\r\n"))
        XCTAssertFalse(text.contains("name=\"depth\""))
    }

    func testSavesReturnedSTL() async throws {
        let mesh = directory.appendingPathComponent("Object 1.usdz")
        try Data("usdz".utf8).write(to: mesh)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/print")
            return (200, "model/stl", Data("solid cube\nendsolid cube\n".utf8))
        }

        let url = try await service().requestSTL(for: .mesh(mesh), name: "Object 1", in: directory)

        XCTAssertEqual(url.lastPathComponent, "Object 1.stl")
        XCTAssertEqual(try String(contentsOf: url), "solid cube\nendsolid cube\n")
    }

    func testServerErrorCarriesStatusAndMessage() async throws {
        let mesh = directory.appendingPathComponent("Room 1.usdz")
        try Data("usdz".utf8).write(to: mesh)
        StubProtocol.handler = { _ in (400, "text/plain", Data("mesh is empty\n".utf8)) }

        do {
            _ = try await service().requestSTL(for: .mesh(mesh), name: "Room 1", in: directory)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? PrintError, .server(status: 400, message: "mesh is empty"))
        }
    }

    func testSendsBearerTokenWhenSet() throws {
        let mesh = directory.appendingPathComponent("Room 1.usdz")
        try Data("usdz".utf8).write(to: mesh)
        XCTAssertEqual(try PrintService(baseURL: "https://print.test", token: "abc").makeRequest(for: .mesh(mesh)).value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertNil(try PrintService(baseURL: "https://print.test", token: nil).makeRequest(for: .mesh(mesh)).value(forHTTPHeaderField: "Authorization"))
    }

    func testServerErrorReadsJSONDetail() async throws {
        let mesh = directory.appendingPathComponent("Room 1.usdz")
        try Data("usdz".utf8).write(to: mesh)
        StubProtocol.handler = { _ in (415, "application/json", Data(#"{"detail": "HEIC photos are not supported"}"#.utf8)) }

        do {
            _ = try await service().requestSTL(for: .mesh(mesh), name: "Room 1", in: directory)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? PrintError, .server(status: 415, message: "HEIC photos are not supported"))
        }
        XCTAssertEqual(PrintService.errorMessage(from: Data(#"{"detail": [{"msg": "field required"}, {"msg": "bad units"}]}"#.utf8)), "field required; bad units")
    }

    func testUnauthorizedPointsToTokenSetting() {
        XCTAssertTrue(PrintError.server(status: 401, message: "Invalid token").localizedDescription.contains("print token in Settings"))
    }

    func testRejectsNonSTLResponse() async throws {
        let mesh = directory.appendingPathComponent("Room 1.usdz")
        try Data("usdz".utf8).write(to: mesh)
        StubProtocol.handler = { _ in (200, "text/html", Data("<html>".utf8)) }

        do {
            _ = try await service().requestSTL(for: .mesh(mesh), name: "Room 1", in: directory)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? PrintError, .unexpectedResponse("text/html"))
        }
    }

    private func service() throws -> PrintService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try PrintService(baseURL: "http://print.test", token: nil, session: URLSession(configuration: configuration))
    }
}

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, contentType, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
