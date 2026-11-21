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
