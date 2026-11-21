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

    func testPhotoCheckRequestSendsPhotoAndPose() throws {
        let pose = CameraPose(cameraTransform: [1, 0, 0, 0, 0, 0.6428, -0.766, 0, 0, 0.766, 0.6428, 0, 0, 0.3, 0.25, 1], imageOrientation: .up)
        let request = try PrintService(baseURL: "http://localhost:8765", token: "t")
            .makePhotoCheckRequest(photo: Data("jpeg".utf8), pose: pose, boundary: "B")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8765/photo-check")
        XCTAssertEqual(request.timeoutInterval, PrintService.photoCheckTimeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"photo\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\njpeg\r\n"))
        XCTAssertTrue(body.contains("name=\"camera_transform\"\r\n\r\n[1,0,0,0,0,0.6428,-0.766,0,0,0.766,0.6428,0,0,0.3,0.25,1]\r\n"))
        XCTAssertFalse(body.contains("name=\"height_mm\""))
    }

    func testPhotoCheckReadsIssues() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/photo-check")
            let json = #"{"ok": false, "issues": [{"code": "steep_angle", "message": "Too steep"}, {"code": "cut_off", "message": "Cut off"}], "camera_pitch_deg": 50.0, "angle_checked": true, "max_pitch_deg": 30.0, "model": "x"}"#
            return (200, "application/json", Data(json.utf8))
        }

        let check = try await service().checkPhoto(Data("jpeg".utf8), pose: nil)

        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.issues.map(\.code), ["steep_angle", "cut_off"])
        XCTAssertEqual(check.issues.first?.message, "Too steep")
        XCTAssertEqual(check.cameraPitchDeg, 50)
    }

    func testPhotoCheckErrorThrows() async throws {
        StubProtocol.handler = { _ in (404, "application/json", Data(#"{"detail": "Not Found"}"#.utf8)) }
        do {
            _ = try await service().checkPhoto(Data("jpeg".utf8), pose: nil)
            XCTFail("expected an error")
        } catch let error as PrintError {
            XCTAssertEqual(error, .server(status: 404, message: "Not Found"))
        }
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

    func testSlowTerminalLineDoesNotTimeOutWhileBytesArrive() async throws {
        StubProtocol.chunkDelay = 0.01
        defer { StubProtocol.chunkDelay = 0 }
        StubProtocol.handler = { _ in
            (200, "application/x-ndjson", Data((#"{"type":"done","stl_base64":"c3Rs"}"# + "\n").utf8))
        }
        let url = try await service(stallTimeout: 0.1).requestSTL(for: .photo(Data([1]), heightMM: 10), name: "slow", in: directory)
        XCTAssertEqual(try Data(contentsOf: url), Data("stl".utf8))
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
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
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
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in
            XCTFail("Must not create an authenticated service for the old server")
            return try self.service()
        })
        manager.sceneChanged(.active)
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.error != nil }, object: nil)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(manager.jobs.first?.error, "Print server changed in Settings; print again")
        XCTAssertFalse(manager.canRetry(manager.jobs[0]))
    }

    @MainActor
    func testDownloadFailureDoesNotDefeatRunningStream() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let job = PrintJob(id: UUID().uuidString, name: "Concurrent", kind: "photo", baseURL: PrintService.configuredBaseURL)
        defaults.set(try JSONEncoder().encode([job]), forKey: "printJobs")
        let connected = expectation(description: "stream connected")
        StubProtocol.finishLoading = false
        defer { StubProtocol.finishLoading = true }
        StubProtocol.handler = { _ in
            connected.fulfill()
            return (200, "application/x-ndjson", Data())
        }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
        manager.sceneChanged(.active)
        await fulfillment(of: [connected], timeout: 2)
        manager.complete(id: job.id, result: .failure(URLError(.networkConnectionLost)), source: .download)
        XCTAssertNil(manager.jobs.first?.error)
        manager.complete(id: job.id, result: .failure(URLError(.cancelled)), source: .download)
        XCTAssertNil(manager.jobs.first?.error)
        let file = directory.appendingPathComponent("concurrent.stl")
        try Data("stl".utf8).write(to: file)
        manager.complete(id: job.id, result: .success(file))
        XCTAssertNotNil(manager.jobs.first?.result)
        manager.dismiss(manager.jobs[0])
    }

    @MainActor
    func testUnavailableBackgroundTransferFallsBackToForegroundStream() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let job = PrintJob(id: UUID().uuidString, name: "Fallback", kind: "photo", baseURL: PrintService.configuredBaseURL)
        defaults.set(try JSONEncoder().encode([job]), forKey: "printJobs")
        StubProtocol.handler = { _ in (200, "application/x-ndjson", Data((#"{"type":"done","stl_base64":"c3Rs"}"# + "\n").utf8)) }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
        manager.complete(id: job.id, result: .failure(URLError(.unknown)), source: .download)
        XCTAssertNil(manager.jobs.first?.error)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertNil(manager.jobs.first?.error)
        manager.dismiss(manager.jobs[0])
    }

    @MainActor
    func testRetryUnacceptedJobUsesCurrentServerAndFreshID() async throws {
        let previous = UserDefaults.standard.object(forKey: PrintService.baseURLKey)
        defer { UserDefaults.standard.set(previous, forKey: PrintService.baseURLKey) }
        UserDefaults.standard.set("bad-url", forKey: PrintService.baseURLKey)
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { job, _ in
            if job.baseURL == "bad-url" { throw PrintError.invalidBaseURL(job.baseURL) }
            XCTAssertEqual(job.baseURL, "http://print.test")
            return try self.service()
        })
        manager.start(input: .photo(Data([1]), heightMM: 10), name: "Retry", kind: "photo")
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.error != nil }, object: nil)
        await fulfillment(of: [failed], timeout: 2)
        let old = try XCTUnwrap(manager.jobs.first)
        UserDefaults.standard.set("http://print.test", forKey: PrintService.baseURLKey)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, "model/stl", Data("stl".utf8))
        }
        manager.retry(old)
        XCTAssertNotEqual(manager.jobs.first?.id, old.id)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertNil(manager.jobs.first?.error)
        manager.dismiss(manager.jobs[0])
    }

    @MainActor
    func testFirstPrintWaitsForPermissionAndSurvivesInactivePhase() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let requested = expectation(description: "permission requested")
        var release: CheckedContinuation<Void, Never>?
        var submitted = false
        StubProtocol.handler = { _ in
            submitted = true
            return (200, "model/stl", Data("stl".utf8))
        }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() }, authorize: {
            await withCheckedContinuation { continuation in
                release = continuation
                requested.fulfill()
            }
        })
        manager.sceneChanged(.active)
        manager.start(input: .photo(Data([1]), heightMM: 10), name: "Permission", kind: "photo")
        await fulfillment(of: [requested], timeout: 2)
        manager.sceneChanged(.inactive)
        XCTAssertFalse(submitted)
        XCTAssertNil(manager.jobs.first?.error)
        release?.resume()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(submitted)
        XCTAssertNil(manager.jobs.first?.error)
        manager.dismiss(manager.jobs[0])
        XCTAssertEqual(PrintService.failureMessage(URLError(.unknown)), "Couldn't contact the print server. Check your connection and retry.")
    }

    @MainActor
    func testDismissDeletesResultAndLateDownloadCopies() throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let job = PrintJob(id: UUID().uuidString, name: "Cleanup", kind: "photo", baseURL: PrintService.configuredBaseURL)
        defaults.set(try JSONEncoder().encode([job]), forKey: "printJobs")
        let manager = PrintJobManager(defaults: defaults, notifications: false)
        try FileManager.default.createDirectory(at: PrintJobManager.directory, withIntermediateDirectories: true)
        let raw = PrintJobManager.directory.appendingPathComponent(job.id).appendingPathExtension("stl")
        try Data("stl".utf8).write(to: raw)
        manager.complete(id: job.id, result: .success(raw))
        let result = try XCTUnwrap(manager.jobs.first?.result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        manager.dismiss(manager.jobs[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        try Data("late download".utf8).write(to: raw)
        manager.complete(id: job.id, result: .success(raw), source: .download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
    }

    @MainActor
    func testRetryDroppedSubmissionPreservesClientJobID() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var retrying = false
        StubProtocol.handler = { request in
            if retrying { return (200, "model/stl", Data("stl".utf8)) }
            if request.httpMethod == "POST" { return (200, "application/x-ndjson", Data()) }
            return (404, "application/json", Data(#"{"detail":"unknown job"}"#.utf8))
        }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
        manager.start(input: .photo(Data([1]), heightMM: 10), name: "Dropped", kind: "photo")
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.error != nil }, object: nil)
        await fulfillment(of: [failed], timeout: 4)
        let job = try XCTUnwrap(manager.jobs.first)
        XCTAssertFalse(job.accepted)
        retrying = true
        manager.retry(job)
        XCTAssertEqual(manager.jobs.first?.id, job.id)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(manager.jobs.first?.id, job.id)
        manager.dismiss(manager.jobs[0])
    }

    @MainActor
    func testUploadFailingBeforeAcceptanceIsResentNotReattached() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); StubProtocol.connectFailures = 0 }
        var methods: [String] = []
        StubProtocol.connectFailures = 1
        StubProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" { return (200, "model/stl", Data("stl".utf8)) }
            return (404, "application/json", Data(#"{"detail":"unknown job"}"#.utf8))
        }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
        manager.start(input: .photo(Data([1]), heightMM: 10), name: "Cold start", kind: "photo")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 4)
        XCTAssertEqual(methods, ["POST"])
        manager.dismiss(manager.jobs[0])
    }

    @MainActor
    func testChangedServerRetryUsesNewSettingsWhenInputRemains() async throws {
        let previous = UserDefaults.standard.object(forKey: PrintService.baseURLKey)
        defer { UserDefaults.standard.set(previous, forKey: PrintService.baseURLKey) }
        UserDefaults.standard.set("http://old.print.test", forKey: PrintService.baseURLKey)
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { job, _ in
            XCTAssertEqual(job.baseURL, "http://print.test")
            return try self.service()
        })
        manager.start(input: .photo(Data([1]), heightMM: 10), name: "Changed", kind: "photo")
        let id = manager.jobs[0].id
        UserDefaults.standard.set("http://print.test", forKey: PrintService.baseURLKey)
        manager.complete(id: id, result: .failure(PrintError.serverChanged))
        let old = manager.jobs[0]
        XCTAssertTrue(manager.canRetry(old))
        StubProtocol.handler = { _ in (200, "model/stl", Data("stl".utf8)) }
        manager.retry(old)
        XCTAssertNotEqual(manager.jobs[0].id, id)
        XCTAssertEqual(manager.jobs[0].baseURL, "http://print.test")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        manager.dismiss(manager.jobs[0])
    }

    @MainActor
    func testTerminalBackgroundHTTPFailuresNotifyInsteadOfReconnecting() throws {
        for status in [404, 422, 500] {
            let suite = "PrintJobs-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let job = PrintJob(id: UUID().uuidString, name: "HTTP failure", kind: "photo", baseURL: PrintService.configuredBaseURL)
            defaults.set(try JSONEncoder().encode([job]), forKey: "printJobs")
            var notifications = [String]()
            let manager = PrintJobManager(defaults: defaults, notifications: false, notify: { id, title, body in
                XCTAssertEqual(id, job.id)
                XCTAssertEqual(title, "Printing failed")
                notifications.append(body)
            })
            manager.sceneChanged(.background)
            let file = directory.appendingPathComponent("http-error")
            try Data(#"{"detail":"repair failed"}"#.utf8).write(to: file)
            let response = HTTPURLResponse(url: URL(string: "http://print.test/result")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let result = Result { try PrintBackgroundDownload.saveResponse(response, file: file, id: job.id) }
            manager.complete(id: job.id, result: result, source: .download)
            XCTAssertNotNil(manager.jobs.first?.error)
            XCTAssertEqual(notifications.count, 1)
            XCTAssertTrue(notifications[0].contains(status == 404 ? "Lost contact" : "repair failed"))
            manager.dismiss(manager.jobs[0])
        }
    }

    @MainActor
    func testAuthenticationRetryUsesCorrectedTokenAndSameJobID() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var token = "rejected-test-token"
        var authorizations = [String?]()
        StubProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            authorizations.append(authorization)
            if authorization == "Bearer rejected-test-token" {
                return (401, "application/json", Data(#"{"detail":"invalid token"}"#.utf8))
            }
            return (200, "model/stl", Data("stl".utf8))
        }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, suppliedToken in
            try self.service(token: suppliedToken)
        }, currentToken: { token })
        manager.start(input: .photo(Data([1]), heightMM: 10), name: "Auth retry", kind: "photo")
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.error != nil }, object: nil)
        await fulfillment(of: [failed], timeout: 2)
        let job = try XCTUnwrap(manager.jobs.first)
        token = "corrected-test-token"
        manager.retry(job)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(manager.jobs.first?.id, job.id)
        XCTAssertEqual(authorizations, ["Bearer rejected-test-token", "Bearer corrected-test-token"])
        manager.dismiss(manager.jobs[0])
    }

    @MainActor
    func testRejectedJobWithoutInputOffersNoRetryAfterRelaunch() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            return (400, "application/json", Data(#"{"detail":"bad face upload"}"#.utf8))
        }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
        manager.start(input: .photo(Data([1]), heightMM: 10), name: "Rejected", kind: "photo")
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.error != nil }, object: nil)
        await fulfillment(of: [failed], timeout: 2)
        let job = try XCTUnwrap(manager.jobs.first)
        XCTAssertTrue(job.rejected)
        XCTAssertEqual(job.error, "The print server returned HTTP 400: bad face upload")
        XCTAssertTrue(manager.canRetry(job))

        let restored = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
        let restoredJob = try XCTUnwrap(restored.jobs.first)
        XCTAssertTrue(restoredJob.rejected)
        XCTAssertFalse(restored.canRetry(restoredJob))
        let sent = requests
        restored.retry(restoredJob)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(requests, sent)
        XCTAssertEqual(restored.jobs.first?.error, "The print server returned HTTP 400: bad face upload")
        restored.dismiss(restoredJob)
        manager.dismiss(job)
    }

    @MainActor
    func testReattachAuthFailureKeepsRetryAvailable() async throws {
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var job = PrintJob(id: UUID().uuidString, name: "Restored", kind: "photo", baseURL: PrintService.configuredBaseURL)
        job.error = PrintError.lostContact.localizedDescription
        defaults.set(try JSONEncoder().encode([job]), forKey: "printJobs")
        StubProtocol.handler = { _ in (401, "application/json", Data(#"{"detail":"missing or wrong bearer token"}"#.utf8)) }
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
        manager.retry(manager.jobs[0])
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.error?.contains("401") == true }, object: nil)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(manager.jobs[0].rejected)
        XCTAssertTrue(manager.canRetry(manager.jobs[0]))
        manager.dismiss(manager.jobs[0])
    }

    @MainActor
    func testRestoringOriginalServerAllowsInputlessJobToReconnect() async throws {
        let previous = UserDefaults.standard.object(forKey: PrintService.baseURLKey)
        defer { UserDefaults.standard.set(previous, forKey: PrintService.baseURLKey) }
        UserDefaults.standard.set("http://different.print.test", forKey: PrintService.baseURLKey)
        let suite = "PrintJobs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var job = PrintJob(id: UUID().uuidString, name: "Restore settings", kind: "photo", baseURL: "http://print.test")
        job.error = PrintError.serverChanged.localizedDescription
        job.retryFromStart = true
        defaults.set(try JSONEncoder().encode([job]), forKey: "printJobs")
        let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in try self.service() })
        XCTAssertFalse(manager.canRetry(manager.jobs[0]))
        UserDefaults.standard.set("http://print.test", forKey: PrintService.baseURLKey)
        XCTAssertTrue(manager.canRetry(manager.jobs[0]))
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/print/\(job.id)")
            return (200, "application/x-ndjson", Data((#"{"type":"done","stl_base64":"c3Rs"}"# + "\n").utf8))
        }
        manager.retry(manager.jobs[0])
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in manager.jobs.first?.result != nil }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(manager.jobs.first?.id, job.id)
        XCTAssertNil(manager.jobs.first?.error)
        manager.dismiss(manager.jobs[0])
    }

    func testPersistedResultUsesRelativePathAndMigratesOldContainer() throws {
        let legacy = #"{"id":"job","name":"Cube","kind":"photo","baseURL":"http://print.test","result":"file:///old-container/Library/Application%20Support/PrintJobs/job/Cube.stl"}"#
        let job = try JSONDecoder().decode(PrintJob.self, from: Data(legacy.utf8))
        XCTAssertEqual(job.result, PrintJobManager.directory.appendingPathComponent("job/Cube.stl"))
        let data = try JSONEncoder().encode(job)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["result"])
        XCTAssertEqual(json["resultPath"] as? String, "job/Cube.stl")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("old-container"))
        XCTAssertEqual(try JSONDecoder().decode(PrintJob.self, from: data).result, job.result)
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

    @MainActor
    func testRestoredScanResultsSaveBesideSourceForBothTransfers() throws {
        let store = ScanStore(directory: directory.appendingPathComponent("Scans"))
        store.seedSamples(contents: Data("mesh".utf8))
        let scan = try XCTUnwrap(store.scans.first)
        for transfer in [PrintJobManager.Transfer.stream, .download] {
            let suite = "PrintJobs-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in throw CancellationError() })
            manager.start(input: .mesh(scan.url), name: scan.name, kind: "scan")
            let restored = PrintJobManager(defaults: defaults, notifications: false)
            let job = try XCTUnwrap(restored.jobs.first)
            XCTAssertNil(restored.printedModel(for: job))
            XCTAssertEqual(job.sourceScanFileName, scan.url.lastPathComponent)
            let source = directory.appendingPathComponent("received.stl")
            try Data("printed mesh".utf8).write(to: source)
            restored.complete(id: job.id, result: .success(source), source: transfer)
            let model = try XCTUnwrap(restored.printedModel(for: restored.jobs[0]))
            try model.save(in: store)
            let saved = try XCTUnwrap(store.scans.first(where: { $0.id == scan.id })?.printedSTLURL)
            XCTAssertEqual(saved, scan.url.deletingPathExtension().appendingPathExtension("stl"))
            XCTAssertEqual(try Data(contentsOf: saved), Data("printed mesh".utf8))
            restored.dismiss(restored.jobs[0])
            manager.dismiss(job)
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        }
    }

    @MainActor
    func testRestoredPhotoResultsSaveAsStandalonePrintsForBothTransfers() throws {
        let store = ScanStore(directory: directory.appendingPathComponent("Scans"))
        for transfer in [PrintJobManager.Transfer.stream, .download] {
            let suite = "PrintJobs-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = PrintJobManager(defaults: defaults, notifications: false, makeService: { _, _ in throw CancellationError() })
            manager.start(input: .photo(Data([1]), heightMM: 10), name: "Photo result", kind: "photo")
            let restored = PrintJobManager(defaults: defaults, notifications: false)
            let job = try XCTUnwrap(restored.jobs.first)
            let source = directory.appendingPathComponent("received.stl")
            try Data("photo mesh".utf8).write(to: source)
            restored.complete(id: job.id, result: .success(source), source: transfer)
            let model = try XCTUnwrap(restored.printedModel(for: restored.jobs[0]))
            XCTAssertNil(model.sourceScanFileName)
            try model.save(in: store)
            XCTAssertTrue(store.scans.allSatisfy { $0.kind == .photo })
            XCTAssertEqual(store.scans.count, transfer == .stream ? 1 : 2)
            restored.dismiss(restored.jobs[0])
            manager.dismiss(job)
        }
    }

    @MainActor
    func testSavingResultForDeletedScanDoesNotCreatePhotoPrint() throws {
        let store = ScanStore(directory: directory.appendingPathComponent("Scans"))
        let source = directory.appendingPathComponent("received.stl")
        try Data("mesh".utf8).write(to: source)
        let model = PrintedModel(url: source, sourceScanFileName: "Deleted.usdz")
        XCTAssertThrowsError(try model.save(in: store))
        XCTAssertTrue(store.scans.isEmpty)
    }

    // MARK: Signed uploads

    private static let depth = DepthCapture(depth: [0.5, .nan], confidence: [2, 0], width: 2, height: 1,
                                            intrinsics: CameraIntrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720, width: 1920, height: 1440),
                                            objectPoints: [])

    func testSignedPayloadNamesOnlyTheFilesEachInputHas() throws {
        let mesh = FileManager.default.temporaryDirectory.appendingPathComponent("signed-\(UUID().uuidString).obj")
        try Data("v 0 0 0".utf8).write(to: mesh)
        defer { try? FileManager.default.removeItem(at: mesh) }
        let service = try PrintService(baseURL: "http://localhost:8765")
        let face = FaceCapture(photo: Data("jpeg".utf8), intrinsics: .init(fx: 1, fy: 1, cx: 0, cy: 0, width: 4, height: 4),
                               cameraTransform: Array(repeating: 0, count: 16), imageOrientation: .up,
                               depth: .init(values: [1, 2], width: 2, height: 1), faceVertices: [0, 0, 0, 1, 1, 1, 2, 2, 2])
        XCTAssertEqual(try service.payload(for: .mesh(mesh)).files.map(\.name), ["mesh"])
        XCTAssertEqual(try service.payload(for: .mesh(mesh)).files.first?.contentType, "model/obj")
        XCTAssertEqual(try service.payload(for: .photo(Data("jpeg".utf8), heightMM: 10)).files.map(\.name), ["photo"])
        XCTAssertEqual(try service.payload(for: .photo(Data("jpeg".utf8), heightMM: 10, depth: Self.depth)).files.map(\.name), ["photo", "depth", "depth_confidence"])
        XCTAssertEqual(try service.payload(for: .face(face)).files.map(\.name), ["photo", "depth", "face_vertices"])
        XCTAssertEqual(try service.payload(for: .face(face)).fields.map(\.name).contains("face_vertex_count"), true)
    }

    func testUploadsRequestSendsJobIDTypesAndSizes() throws {
        let service = try PrintService(baseURL: "http://localhost:8765", token: "abc")
        let payload = try service.payload(for: .photo(Data("jpeg".utf8), heightMM: 10, depth: Self.depth))
        let request = try service.makeUploadsRequest(jobID: "job-1", files: payload.files)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8765/print/uploads")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["job_id"] as? String, "job-1")
        let files = try XCTUnwrap(json["files"] as? [String: [String: Any]])
        XCTAssertEqual(Set(files.keys), ["photo", "depth", "depth_confidence"])
        XCTAssertEqual(files["photo"]?["content_type"] as? String, "image/jpeg")
        XCTAssertEqual(files["photo"]?["size"] as? Int, 4)
        XCTAssertEqual(files["depth"]?["size"] as? Int, 8)
        XCTAssertEqual(files["depth_confidence"]?["content_type"] as? String, "application/octet-stream")
    }

    func testSubmitRequestNamesUploadsAndHasNoFileParts() throws {
        let service = try PrintService(baseURL: "http://localhost:8765", token: "abc")
        let payload = try service.payload(for: .photo(Data("jpeg".utf8), heightMM: 120, depth: Self.depth))
        let request = service.makeSubmitRequest(for: payload, jobID: "job-1", boundary: "B")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8765/print")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/x-ndjson, model/stl")
        XCTAssertTrue(body.contains("name=\"job_id\"\r\n\r\njob-1\r\n"))
        XCTAssertTrue(body.contains("name=\"uploaded\"\r\n\r\nphoto,depth,depth_confidence\r\n"))
        XCTAssertTrue(body.contains("name=\"height_mm\"\r\n\r\n120.0\r\n"))
        XCTAssertTrue(body.contains("name=\"depth_width\"\r\n\r\n2\r\n"))
        XCTAssertFalse(body.contains("filename="))
    }

    func testPrepareConfirmsUploadedPhotoWithoutSubmittingAndResultUsesSignedSTL() async throws {
        let uploader = FakeUploader()
        let client = try service(token: "abc", signedUploads: true, uploader: uploader)
        let input = PrintInput.photo(Data("jpeg".utf8), heightMM: 10)
        let state = PrintUploadState()
        var calls: [String] = []
        StubProtocol.handler = { request in
            let path = request.url!.path
            calls.append("\(request.httpMethod!) \(path)")
            switch path {
            case "/print/uploads":
                return (200, "application/json", Data(#"{"job_id":"job-1","uploads":{"photo":{"url":"https://s3.test/bucket/job-1/photo","method":"PUT","file_id":"job-1/photo","get_url":"https://s3.test/preview?old=1"}}}"#.utf8))
            case "/print/uploads/job-1":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
                XCTAssertEqual(uploader.puts.map(\.name), ["photo"])
                return (200, "application/json", Data(#"{"job_id":"job-1","uploads":{"photo":{"file_id":"job-1/photo","get_url":"https://s3.test/preview?fresh=1"}}}"#.utf8))
            case "/print":
                XCTAssertTrue(String(decoding: Self.body(of: request), as: UTF8.self).contains("name=\"uploaded\"\r\n\r\nphoto"))
                return (200, "application/x-ndjson", Data((#"{"type":"done","stl_url":"https://s3.test/result.stl?signature=1","stl_file_id":"job-1/result.stl","stl_expires_in":900}"# + "\n").utf8))
            case "/result.stl":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.url?.query, "signature=1")
                return (200, "model/stl", Data("signed STL".utf8))
            default:
                XCTFail("unexpected request: \(path)")
                return (404, "application/json", Data())
            }
        }
        let saved = try await client.prepareUploads(for: input, jobID: "job-1", state: state, onProgress: { _ in })
        XCTAssertEqual(saved?["photo"]?.file_id, "job-1/photo")
        XCTAssertEqual(saved?["photo"]?.get_url.query, "fresh=1")
        XCTAssertEqual(calls, ["POST /print/uploads", "GET /print/uploads/job-1"])

        let result = try await client.requestSTL(for: input, name: "photo", in: directory, jobID: "job-1", uploads: state)
        XCTAssertEqual(try Data(contentsOf: result), Data("signed STL".utf8))
        XCTAssertEqual(uploader.puts.count, 1)
        XCTAssertEqual(calls, ["POST /print/uploads", "GET /print/uploads/job-1", "POST /print", "GET /result.stl"])
    }

    func testPreflightStorageDenialSkipsConfirmationAndUsesMultipart() async throws {
        let uploader = FakeUploader()
        uploader.statuses = ["photo": [403, 403, 403]]
        let client = try service(signedUploads: true, uploader: uploader)
        let input = PrintInput.photo(Data("jpeg".utf8), heightMM: 10)
        let state = PrintUploadState()
        var calls: [String] = []
        StubProtocol.handler = { request in
            let path = request.url!.path
            calls.append(path)
            if path == "/print/uploads" {
                return (200, "application/json", Data(#"{"uploads":{"photo":{"url":"https://s3.test/photo","file_id":"job-1/photo","get_url":"https://s3.test/preview"}}}"#.utf8))
            }
            let body = String(decoding: Self.body(of: request), as: UTF8.self)
            XCTAssertEqual(path, "/print")
            XCTAssertTrue(body.contains("name=\"photo\"; filename=\"photo.jpg\""))
            XCTAssertFalse(body.contains("name=\"uploaded\""))
            return (200, "model/stl", Data("stl".utf8))
        }
        let preview = try await client.prepareUploads(for: input, jobID: "job-1", state: state, onProgress: { _ in })
        XCTAssertNil(preview)
        XCTAssertTrue(state.legacy)
        XCTAssertEqual(calls, Array(repeating: "/print/uploads", count: 3))

        _ = try await client.requestSTL(for: input, name: "denied", in: directory, jobID: "job-1", uploads: state)
        XCTAssertEqual(calls, ["/print/uploads", "/print/uploads", "/print/uploads", "/print"])
        XCTAssertEqual(uploader.puts.count, 3)
    }

    func testSTLPreviewParsesASCIITrianglesAndRejectsEmptyMeshes() throws {
        let mesh = try XCTUnwrap(STLMesh(data: Data("""
        solid sample
          facet normal 0 0 1
            outer loop
              vertex 10 10 10
              vertex 20 10 10
              vertex 10 20 10
            endloop
          endfacet
        endsolid sample
        """.utf8)))
        XCTAssertEqual(mesh.vertices, [SIMD3(-0.5, -0.5, 0), SIMD3(0.5, -0.5, 0), SIMD3(-0.5, 0.5, 0)])
        XCTAssertEqual(mesh.normals, Array(repeating: SIMD3(0, 0, 1), count: 3))
        XCTAssertNil(STLMesh(data: Data("solid empty\nendsolid empty".utf8)))
    }

    func testSignedUploadPutsEachFileWithReturnedHeadersThenSubmits() async throws {
        let uploader = FakeUploader()
        var calls: [String] = []
        StubProtocol.handler = { request in
            let path = request.url!.path
            calls.append("\(request.httpMethod!) \(path)")
            if path == "/print/uploads" {
                let files = (try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])?["files"] as? [String: Any] ?? [:]
                return (200, "application/json", Self.uploadPlan(for: files.keys.sorted()))
            }
            XCTAssertFalse(String(decoding: Self.body(of: request), as: UTF8.self).contains("filename="))
            return (200, "application/x-ndjson", Data("{\"type\":\"accepted\",\"job_id\":\"job-1\"}\n{\"type\":\"done\",\"filename\":\"x.stl\",\"stl_base64\":\"c3Rs\"}\n".utf8))
        }
        let state = PrintUploadState()
        let url = try await service(token: "abc", signedUploads: true, uploader: uploader)
            .requestSTL(for: .photo(Data("jpeg".utf8), heightMM: 10, depth: Self.depth), name: "signed-\(UUID().uuidString)",
                        in: FileManager.default.temporaryDirectory, jobID: "job-1", uploads: state)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "stl")
        XCTAssertEqual(calls, ["POST /print/uploads", "POST /print"])
        XCTAssertEqual(uploader.puts.map(\.name), ["photo", "depth", "depth_confidence"])
        XCTAssertEqual(uploader.puts[0].data, Data("jpeg".utf8))
        XCTAssertEqual(uploader.puts[0].request.httpMethod, "PUT")
        XCTAssertEqual(uploader.puts[0].request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(uploader.puts[0].request.value(forHTTPHeaderField: "x-amz-meta-job"), "job-1")
        XCTAssertNil(uploader.puts[0].request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(state.uploadedNames, ["photo", "depth", "depth_confidence"])
    }

    func testExpiredUploadURLIsRenewedForThatFileOnly() async throws {
        let uploader = FakeUploader()
        uploader.statuses = ["depth": [403]]
        var requested: [[String]] = []
        StubProtocol.handler = { request in
            if request.url!.path == "/print/uploads" {
                let names = ((try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])?["files"] as? [String: Any] ?? [:]).keys.sorted()
                requested.append(names)
                return (200, "application/json", Self.uploadPlan(for: names))
            }
            return (200, "model/stl", Data("stl".utf8))
        }
        let url = try await service(signedUploads: true, uploader: uploader)
            .requestSTL(for: .photo(Data("jpeg".utf8), heightMM: 10, depth: Self.depth), name: "renew-\(UUID().uuidString)",
                        in: FileManager.default.temporaryDirectory, jobID: "job-1")
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(requested, [["depth", "depth_confidence", "photo"], ["depth"]])
        XCTAssertEqual(uploader.puts.map(\.name), ["photo", "depth", "depth", "depth_confidence"])
    }

    func testConflictReuploadsTheMissingFilesAndResubmits() async throws {
        let uploader = FakeUploader()
        var requested: [[String]] = []
        var submits = 0
        StubProtocol.handler = { request in
            if request.url!.path == "/print/uploads" {
                let names = ((try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])?["files"] as? [String: Any] ?? [:]).keys.sorted()
                requested.append(names)
                return (200, "application/json", Self.uploadPlan(for: names))
            }
            submits += 1
            if submits == 1 { return (409, "application/json", Data(#"{"detail":"upload missing: depth","missing":["depth"]}"#.utf8)) }
            return (200, "model/stl", Data("stl".utf8))
        }
        let url = try await service(signedUploads: true, uploader: uploader)
            .requestSTL(for: .photo(Data("jpeg".utf8), heightMM: 10, depth: Self.depth), name: "conflict-\(UUID().uuidString)",
                        in: FileManager.default.temporaryDirectory, jobID: "job-1")
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(submits, 2)
        XCTAssertEqual(requested, [["depth", "depth_confidence", "photo"], ["depth"]])
        XCTAssertEqual(uploader.puts.map(\.name), ["photo", "depth", "depth_confidence", "depth"])
    }

    func testResendBeforeAcceptedRepeatsOnlyTheSubmit() async throws {
        let uploader = FakeUploader()
        var calls: [String] = []
        StubProtocol.handler = { request in
            calls.append(request.url!.path)
            if request.url!.path == "/print/uploads" { return (200, "application/json", Self.uploadPlan(for: ["photo"])) }
            return (200, "model/stl", Data("stl".utf8))
        }
        let state = PrintUploadState()
        state.markUploaded("photo")
        let url = try await service(signedUploads: true, uploader: uploader)
            .requestSTL(for: .photo(Data("jpeg".utf8), heightMM: 10), name: "resend-\(UUID().uuidString)",
                        in: FileManager.default.temporaryDirectory, jobID: "job-1", uploads: state)
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(calls, ["/print"])
        XCTAssertTrue(uploader.puts.isEmpty)
    }

    func testServerWithoutSignedUploadsGetsTheMultipartPost() async throws {
        let uploader = FakeUploader()
        var calls: [String] = []
        StubProtocol.handler = { request in
            calls.append(request.url!.path)
            if request.url!.path == "/print/uploads" { return (405, "application/json", Data(#"{"detail":"Method Not Allowed"}"#.utf8)) }
            XCTAssertTrue(String(decoding: Self.body(of: request), as: UTF8.self).contains("name=\"photo\"; filename=\"photo.jpg\""))
            return (200, "model/stl", Data("stl".utf8))
        }
        let state = PrintUploadState()
        let url = try await service(signedUploads: true, uploader: uploader)
            .requestSTL(for: .photo(Data("jpeg".utf8), heightMM: 10), name: "legacy-\(UUID().uuidString)",
                        in: FileManager.default.temporaryDirectory, jobID: "job-1", uploads: state)
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(calls, ["/print/uploads", "/print"])
        XCTAssertTrue(state.legacy)
        XCTAssertTrue(uploader.puts.isEmpty)
    }

    func testStorageDenyingEveryPutFallsBackToTheMultipartPost() async throws {
        let uploader = FakeUploader()
        uploader.statuses = ["photo": [403, 403, 403]]
        var calls: [String] = []
        StubProtocol.handler = { request in
            calls.append(request.url!.path)
            if request.url!.path == "/print/uploads" { return (200, "application/json", Self.uploadPlan(for: ["photo"])) }
            let body = String(decoding: Self.body(of: request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"photo\"; filename=\"photo.jpg\""))
            XCTAssertFalse(body.contains("name=\"uploaded\""))
            return (200, "model/stl", Data("stl".utf8))
        }
        let state = PrintUploadState()
        let url = try await service(signedUploads: true, uploader: uploader)
            .requestSTL(for: .photo(Data("jpeg".utf8), heightMM: 10), name: "denied-\(UUID().uuidString)",
                        in: FileManager.default.temporaryDirectory, jobID: "job-1", uploads: state)
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(uploader.puts.count, 3)
        XCTAssertEqual(calls, ["/print/uploads", "/print/uploads", "/print/uploads", "/print"])
        XCTAssertTrue(state.legacy)
    }

    func testFailingUploadPlanFallsBackToTheMultipartPost() async throws {
        let uploader = FakeUploader()
        var calls: [String] = []
        StubProtocol.handler = { request in
            calls.append(request.url!.path)
            if request.url!.path == "/print/uploads" { return (500, "application/json", Data(#"{"detail":"boom"}"#.utf8)) }
            return (200, "model/stl", Data("stl".utf8))
        }
        let url = try await service(signedUploads: true, uploader: uploader)
            .requestSTL(for: .photo(Data("jpeg".utf8), heightMM: 10), name: "plan-\(UUID().uuidString)",
                        in: FileManager.default.temporaryDirectory, jobID: "job-1")
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(calls, ["/print/uploads", "/print"])
        XCTAssertTrue(uploader.puts.isEmpty)
    }

    func testFailedUploadsRequestIsAnError() async throws {
        StubProtocol.handler = { _ in (401, "application/json", Data(#"{"detail":"bad token"}"#.utf8)) }
        do {
            _ = try await service(signedUploads: true, uploader: FakeUploader())
                .requestSTL(for: .photo(Data("jpeg".utf8), heightMM: 10), name: "x", in: FileManager.default.temporaryDirectory, jobID: "job-1")
            XCTFail("expected an error")
        } catch PrintError.server(let status, let message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "bad token")
        }
    }

    private static func uploadPlan(for names: [String]) -> Data {
        let uploads = Dictionary(uniqueKeysWithValues: names.map { name in
            (name, ["url": "https://s3.test/bucket/job-1/\(name)?sig=\(UUID().uuidString)", "method": "PUT",
                    "headers": ["Content-Type": name == "photo" ? "image/jpeg" : "application/octet-stream", "x-amz-meta-job": "job-1"]] as [String: Any])
        })
        return try! JSONSerialization.data(withJSONObject: ["job_id": "job-1", "expires_in": 900, "uploads": uploads])
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func service(stallTimeout: TimeInterval = 10, token: String? = nil, signedUploads: Bool = false, uploader: PrintUploading? = nil) throws -> PrintService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try PrintService(baseURL: "http://print.test", token: token, session: URLSession(configuration: configuration), stallTimeout: stallTimeout, signedUploads: signedUploads, uploader: uploader)
    }
}

private final class FakeUploader: PrintUploading, @unchecked Sendable {
    struct Put { let name: String; let request: URLRequest; let data: Data }
    private let lock = NSLock()
    private var recorded: [Put] = []
    /// Status codes to answer per file name, in order; then 200.
    var statuses: [String: [Int]] = [:]
    var puts: [Put] { lock.withLock { recorded } }

    func upload(_ request: URLRequest, fromFile file: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> (status: Int, body: Data) {
        let name = request.url!.lastPathComponent
        let data = try Data(contentsOf: file)
        let status: Int = lock.withLock {
            recorded.append(Put(name: name, request: request, data: data))
            return statuses[name]?.isEmpty == false ? statuses[name]!.removeFirst() : 200
        }
        onProgress(Int64(data.count))
        return (status, status == 403 ? Data("<Error><Code>AccessDenied</Code><Message>Request has expired</Message></Error>".utf8) : Data())
    }
}

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String, Data))?
    nonisolated(unsafe) static var finishLoading = true
    nonisolated(unsafe) static var chunkDelay: TimeInterval = 0
    nonisolated(unsafe) static var connectFailures = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.connectFailures > 0 {
            Self.connectFailures -= 1
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, contentType, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in data {
            if Self.chunkDelay > 0 { Thread.sleep(forTimeInterval: Self.chunkDelay) }
            client?.urlProtocol(self, didLoad: Data([chunk]))
        }
        if Self.finishLoading { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}
