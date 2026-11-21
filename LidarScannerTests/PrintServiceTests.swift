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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/x-ndjson, model/stl")
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

    func testStreamProgressUnknownEventAndDoneAcrossChunks() async throws {
        let observed = expectation(description: "server progress")
        observed.expectedFulfillmentCount = 2
        let lines = [
            #"{"type":"accepted","job_id":"server-id"}"#,
            #"{"type":"progress","stage":"TripoSR","message":"Building model","progress":0.4,"extra":true}"#,
            #"{"type":"future","progress":"unknown schema","unknown":"ignored"}"#,
            #"{"type":"progress","stage":"repair","message":"Repairing mesh","progress":null}"#,
            #"{"type":"done","filename":"server.stl","report":{},"stl_base64":"c3Rs"}"#
        ]
        StubProtocol.handler = { _ in (200, "application/x-ndjson", Data((lines.joined(separator: "\r\n") + "\n").utf8)) }
        let accepted = expectation(description: "accepted")
        let url = try await service().requestSTL(for: .photo(Data([1]), heightMM: 10), name: "result", in: directory, onProgress: { progress in
            if progress.stage == "TripoSR" {
                XCTAssertEqual(progress.message, "Building model")
                XCTAssertEqual(progress.progress, 0.4)
                observed.fulfill()
            } else if progress.stage == "repair" {
                XCTAssertNil(progress.progress)
                observed.fulfill()
            }
        }, onAccepted: { id in
            XCTAssertEqual(id, "server-id")
            accepted.fulfill()
        })
        XCTAssertEqual(try Data(contentsOf: url), Data("stl".utf8))
        await fulfillment(of: [observed, accepted], timeout: 1)
    }

    func testStreamErrorsAndMissingTerminalEvents() async throws {
        for (body, detail) in [
            (#"{"type":"error","detail":"Depth fusion failed"}"#, "Depth fusion failed"),
            (#"{"type":"progress","stage":"repair","progress":null}"# + "\n", "stream ended without a terminal event"),
            ("", "stream ended without a terminal event"),
            (#"{"type":"done","stl_base64":"!"}"#, "missing or invalid STL data"),
            (#"{"type":"done","stl_base64":""}"#, "missing or invalid STL data")
        ] {
            StubProtocol.handler = { _ in (200, "application/x-ndjson", Data(body.utf8)) }
            do {
                _ = try await service().requestSTL(for: .photo(Data([1]), heightMM: 10), name: "failed", in: directory)
                XCTFail("Expected failure for \(body)")
            } catch { XCTAssertTrue(error.localizedDescription.contains(detail), error.localizedDescription) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("failed.stl").path))
        }
    }

    func testStreamSilenceTimesOut() async throws {
        StubProtocol.finishLoading = false
        defer { StubProtocol.finishLoading = true }
        StubProtocol.handler = { _ in (200, "application/x-ndjson", Data(#"{"type":"progress","stage":"repair"}"#.utf8)) }
        do {
            _ = try await service(stallTimeout: 0.05).requestSTL(for: .photo(Data([1]), heightMM: 10), name: "silent", in: directory)
            XCTFail("Expected silence timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Lost contact with the print server")) }
    }

    func testClientJobIDAndCentralizedRoutes() throws {
        let service = try PrintService(baseURL: "http://print.test", token: "abc")
        let request = try service.makeRequest(for: .photo(Data([1]), heightMM: 10), jobID: "client-id")
        XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("name=\"job_id\"\r\n\r\nclient-id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Prefer"))
        XCTAssertEqual(service.jobRequest(id: "client-id").url?.path, "/print/client-id")
        XCTAssertEqual(service.jobRequest(id: "client-id", route: .result).url?.path, "/print/client-id/result")
        XCTAssertEqual(service.jobRequest(id: "client-id", route: .result).value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    }

    @MainActor
    func testRestoredJobReattachesAfterTruncatedStreamAndDedupes() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let job = PrintJob(id: UUID().uuidString, name: "Restored", kind: "photo", baseURL: PrintService.configuredBaseURL)
        defaults.set(try JSONEncoder().encode([job]), forKey: "printJobs")
        let complete = expectation(description: "reattached")
        var count = 0
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/print/\(job.id)")
            count += 1
            if count == 1 { return (200, "application/x-ndjson", Data()) }
            complete.fulfill()
            return (200, "application/x-ndjson", Data((#"{"type":"done","stl_base64":"c3Rs"}"# + "\n").utf8))
        }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _ in try self.service() })
        XCTAssertEqual(manager.jobs.first?.id, job.id)
        manager.sceneChanged(.active)
        await fulfillment(of: [complete], timeout: 5)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(count, 2)
        let result = try XCTUnwrap(manager.jobs.first?.result)
        XCTAssertEqual(try Data(contentsOf: result), Data("stl".utf8))
        manager.complete(id: job.id, result: .failure(PrintError.jobFailed("late duplicate")))
        XCTAssertNil(manager.jobs.first?.error)
        XCTAssertEqual(manager.jobs.first?.result, result)
        XCTAssertEqual(PrintJobManager(defaults: defaults, notifications: false).jobs.first?.result, result)
        manager.dismiss(manager.jobs[0])
        XCTAssertTrue(manager.jobs.isEmpty)
    }

    @MainActor
    func testRestoredJobRejectsChangedServerBeforeCreatingService() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let job = PrintJob(id: UUID().uuidString, name: "Old server", kind: "photo", baseURL: "https://old-print.invalid")
        defaults.set(try JSONEncoder().encode([job]), forKey: "printJobs")
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _ in
            XCTFail("Must not create an authenticated service for the old server")
            return try self.service()
        })
        manager.sceneChanged(.active)
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.error != nil }, object: nil)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(manager.jobs.first?.error, "Print server changed in Settings; print again")
    }

    func testBackgroundDownloadResponseHandling() throws {
        let file = directory.appendingPathComponent("download")
        let url = URL(string: "http://print.test/result")!
        try Data("solid cube".utf8).write(to: file)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "model/stl"])!
        let saved = try PrintBackgroundDownload.saveResponse(response, file: file, id: UUID().uuidString)
        XCTAssertEqual(try Data(contentsOf: saved), Data("solid cube".utf8))
        try? FileManager.default.removeItem(at: saved)
        try Data(#"{"detail":"repair failed"}"#.utf8).write(to: file)
        let failure = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        XCTAssertThrowsError(try PrintBackgroundDownload.saveResponse(failure, file: file, id: "failed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("repair failed"))
        }
        try Data().write(to: file)
        XCTAssertThrowsError(try PrintBackgroundDownload.saveResponse(response, file: file, id: "empty"))
        XCTAssertThrowsError(try PrintBackgroundDownload.saveResponse(nil, file: file, id: "missing"))
    }

    private func service(stallTimeout: TimeInterval = 10) throws -> PrintService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try PrintService(baseURL: "http://print.test", token: nil, session: URLSession(configuration: configuration), stallTimeout: stallTimeout)
    }
}

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String, Data))?
    nonisolated(unsafe) static var finishLoading = true

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
        for chunk in data { client?.urlProtocol(self, didLoad: Data([chunk])) }
        if Self.finishLoading { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}
