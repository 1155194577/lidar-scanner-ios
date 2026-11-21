import Foundation

struct PrintProgress: Equatable, Codable {
    let stage: String
    let message: String
    let progress: Double?

    static let uploading = PrintProgress(stage: "uploading", message: "Uploading to print server", progress: 0)
}

/// What gets sent to the print endpoint: a scan's mesh, a single photo plus the LiDAR-measured object height, or a TrueDepth face for a bust.
enum PrintInput {
    case mesh(URL)
    case photo(Data, heightMM: Double, pose: CameraPose? = nil, depth: DepthCapture? = nil)
    case face(FaceCapture)
}

/// `/photo-check`'s verdict on a Photo Print shot, from the phone's pitch plus a vision model.
struct PhotoCheck: Decodable, Equatable {
    struct Issue: Decodable, Equatable {
        /// `steep_angle`, `cluttered_background` or `cut_off`.
        let code: String
        let message: String
    }

    let ok: Bool
    let issues: [Issue]
    let cameraPitchDeg: Double?
}

enum PrintError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case server(status: Int, message: String)
    case unexpectedResponse(String)
    case jobFailed(String)
    case lostContact
    case serverChanged
    /// Step 3 of a signed upload got 409: the server no longer has these uploaded files.
    case uploadMissing([String])

    var errorDescription: String? {
        switch self {
        case .serverChanged: return "Print server changed in Settings; print again"
        case .jobFailed(let detail): return detail
        case .lostContact: return "Lost contact with the print server. Please retry."
        case .uploadMissing(let names):
            return "The print server lost the uploaded \(names.isEmpty ? "files" : names.joined(separator: ", ")). Please retry."
        case .invalidBaseURL(let value):
            return "\"\(value)\" isn't a valid print server URL. Set it in Settings."
        case .server(401, _):
            return "The print server rejected the token (HTTP 401). Check the print token in Settings."
        case .server(let status, let message):
            return message.isEmpty ? "The print server returned HTTP \(status)." : "The print server returned HTTP \(status): \(message)"
        case .unexpectedResponse(let detail):
            return "The print server didn't return an STL file (\(detail))."
        }
    }
}

/// Client for `POST {baseURL}/print`: multipart `mesh` (OBJ, PLY or USDZ, in metres) or `photo` + `height_mm`,
/// Authorised with Bearer token; accepts NDJSON progress, then done (base64 STL) or error detail.
/// Unknown events are ignored; missing terminal events and 10 s without a line fail. Legacy model/stl
/// responses and non-2xx JSON detail errors remain supported. The overall request deadline is 600 s.
/// Async jobs include a client UUID `job_id` in the unchanged multipart form. `accepted` acknowledges it;
/// GET /print/{id} replays the stream, and GET /print/{id}/result long-polls an STL (or JSON error).
///
/// Signed uploads (when the server has them): `POST /print/uploads` with the job's file names, types and sizes
/// returns a signed URL per file; each file is PUT there with exactly the returned headers, and `POST /print`
/// then sends `job_id`, `uploaded=<names>` and the form fields with no file parts. A 403 PUT (expired URL) asks
/// for a fresh URL for that file; a 409 from `/print` re-uploads the files it names. Servers without
/// `/print/uploads` (404/405), and jobs whose signed uploads fail before step 3, get the single multipart POST.
struct PrintService {
    static let baseURLKey = "printBaseURL"
    static let tokenKey = "printAPIToken"

    static var defaultBaseURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "PrintBaseURL") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "http://localhost:8765"
    }

    /// The token saved in Settings (Keychain), else one passed as `-printAPIToken <token>` at launch.
    static var configuredToken: String? {
        (KeychainStore.read(tokenKey) ?? UserDefaults.standard.string(forKey: tokenKey)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The base URL set in Settings (or via `-printBaseURL <url>` at launch), else the build's default.
    static var configuredBaseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
    }

    let endpoint: URL
    let checkEndpoint: URL
    let uploadsEndpoint: URL
    private let token: String?
    private let session: URLSession
    private let stallTimeout: TimeInterval
    private let signedUploads: Bool
    private let uploader: PrintUploading

    init(baseURL: String = PrintService.configuredBaseURL, token: String? = PrintService.configuredToken, session: URLSession = .shared,
         stallTimeout: TimeInterval = 60, signedUploads: Bool = true, uploader: PrintUploading? = nil) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw PrintError.invalidBaseURL(baseURL)
        }
        endpoint = url.appendingPathComponent("print")
        checkEndpoint = url.appendingPathComponent("photo-check")
        uploadsEndpoint = endpoint.appendingPathComponent("uploads")
        self.token = token
        self.session = session
        self.stallTimeout = stallTimeout
        self.signedUploads = signedUploads
        self.uploader = uploader ?? SessionUploader(session: session)
    }

    /// The single multipart `POST /print` (servers without signed uploads).
    func makeRequest(for input: PrintInput, boundary: String = "Boundary-\(UUID().uuidString)", jobID: String? = nil) throws -> URLRequest {
        var form = MultipartForm(boundary: boundary)
        if let jobID { form.addField(name: "job_id", value: jobID) }
        try payload(for: input).write(to: &form)
        return post(form, to: endpoint, accept: "application/x-ndjson, model/stl", timeout: 600)
    }

    /// Step 3 of a signed upload: `job_id`, `uploaded` and the form fields, without file parts.
    func makeSubmitRequest(for payload: PrintPayload, jobID: String, boundary: String = "Boundary-\(UUID().uuidString)") -> URLRequest {
        var form = MultipartForm(boundary: boundary)
        form.addField(name: "job_id", value: jobID)
        form.addField(name: "uploaded", value: payload.files.map(\.name).joined(separator: ","))
        for field in payload.fields { form.addField(name: field.name, value: field.value) }
        return post(form, to: endpoint, accept: "application/x-ndjson, model/stl", timeout: 600)
    }

    /// Step 1 of a signed upload: asks for a signed URL per file.
    func makeUploadsRequest(jobID: String, files: [PrintPayload.File]) throws -> URLRequest {
        var request = URLRequest(url: uploadsEndpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let described = Dictionary(uniqueKeysWithValues: files.map { ($0.name, ["content_type": $0.contentType, "size": $0.data.count] as [String: Any]) })
        request.httpBody = try JSONSerialization.data(withJSONObject: ["job_id": jobID, "files": described], options: .sortedKeys)
        return request
    }

    /// The input's form fields and files, in the order the multipart POST sends them.
    func payload(for input: PrintInput) throws -> PrintPayload {
        var form = PrintPayload()
        switch input {
        case .mesh(let url):
            form.addFile(name: "mesh", fileName: url.lastPathComponent, contentType: Self.contentType(for: url), data: try Data(contentsOf: url))
        case .photo(let data, let heightMM, let pose, let depth):
            form.addFile(name: "photo", fileName: "photo.jpg", contentType: "image/jpeg", data: data)
            form.addField(name: "height_mm", value: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), heightMM))
            if let pose {
                form.addField(name: "image_orientation", value: String(pose.imageOrientation.rawValue))
                form.addField(name: "camera_transform", value: String(decoding: try JSONEncoder().encode(pose.cameraTransform), as: UTF8.self))
            }
            if let depth {
                try Self.addDepth(depth, to: &form)
            }
        case .face(let capture):
            try capture.addFields(to: &form)
        }
        return form
    }

    func makePhotoCheckRequest(photo: Data, pose: CameraPose?, boundary: String = "Boundary-\(UUID().uuidString)") throws -> URLRequest {
        var form = MultipartForm(boundary: boundary)
        form.addFile(name: "photo", fileName: "photo.jpg", contentType: "image/jpeg", data: photo)
        if let pose {
            form.addField(name: "camera_transform", value: String(decoding: try JSONEncoder().encode(pose.cameraTransform), as: UTF8.self))
        }
        return post(form, to: checkEndpoint, accept: "application/json", timeout: Self.photoCheckTimeout)
    }

    /// Asks `/photo-check` whether the shot needs a retake (steep angle, clutter, object cut off).
    func checkPhoto(_ photo: Data, pose: CameraPose?) async throws -> PhotoCheck {
        let (data, response) = try await session.data(for: try makePhotoCheckRequest(photo: photo, pose: pose))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PrintError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: Self.errorMessage(from: data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PhotoCheck.self, from: data)
    }

    static let photoCheckTimeout: TimeInterval = 45

    private func post(_ form: MultipartForm, to url: URL, accept: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var form = form
        request.httpBody = form.finalized()
        return request
    }

    /// Uploads the input and writes the returned STL to `directory/<name>.stl`. With a `jobID`, files go by signed
    /// URL; `uploads` remembers which already went up, so a resend before `accepted` repeats only what is missing.
    func requestSTL(for input: PrintInput, name: String, in directory: URL = PrintService.outputDirectory,
                    jobID: String? = nil, uploads: PrintUploadState? = nil,
                    onProgress: @escaping @Sendable (PrintProgress) -> Void = { _ in },
                    onAccepted: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let state = uploads ?? PrintUploadState()
        guard signedUploads, let jobID, !state.legacy else {
            return try await receive(try makeRequest(for: input, jobID: jobID), name: name, in: directory, onProgress: onProgress, onAccepted: onAccepted)
        }
        let payload = try payload(for: input)
        var conflicts = 0
        while true {
            let pending = payload.files.filter { !state.isUploaded($0.name) }
            if !pending.isEmpty, !(try await uploadOrFallBack(pending, jobID: jobID, state: state, onProgress: onProgress)) {
                state.legacy = true
                return try await receive(try makeRequest(for: input, jobID: jobID), name: name, in: directory, onProgress: onProgress, onAccepted: onAccepted)
            }
            do {
                return try await receive(makeSubmitRequest(for: payload, jobID: jobID), name: name, in: directory, onProgress: onProgress, onAccepted: onAccepted)
            } catch PrintError.uploadMissing(let missing) {
                let names = missing.isEmpty ? payload.files.map(\.name) : missing
                state.forget(names)
                conflicts += 1
                if conflicts > 2 { throw PrintError.server(status: 409, message: "upload missing: " + names.joined(separator: ", ")) }
            }
        }
    }

    struct UploadSlot: Decodable, Equatable {
        let url: URL
        let method: String?
        let headers: [String: String]?
        let file_id: String?
        let get_url: URL?
    }

    struct UploadReference: Decodable, Equatable {
        let file_id: String
        let get_url: URL
    }

    func confirmedUploads(jobID: String) async throws -> [String: UploadReference] {
        var request = URLRequest(url: uploadsEndpoint.appendingPathComponent(jobID))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        struct Confirmation: Decodable {
            let files: [String: UploadReference]

            private enum CodingKeys: String, CodingKey { case files, uploads }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                files = try container.decodeIfPresent([String: UploadReference].self, forKey: .files)
                    ?? container.decode([String: UploadReference].self, forKey: .uploads)
            }
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PrintError.server(status: status, message: Self.errorMessage(from: data))
        }
        return try JSONDecoder().decode(Confirmation.self, from: data).files
    }

    func prepareUploads(for input: PrintInput, jobID: String, state: PrintUploadState,
                        onProgress: @escaping @Sendable (PrintProgress) -> Void) async throws -> [String: UploadReference]? {
        guard signedUploads, !state.legacy else { return nil }
        let files = try payload(for: input).files
        let pending = files.filter { !state.isUploaded($0.name) }
        if !pending.isEmpty, !(try await uploadOrFallBack(pending, jobID: jobID, state: state, onProgress: onProgress)) {
            state.legacy = true
            return nil
        }
        guard state.supportsConfirmation else { return nil }
        let references: [String: UploadReference]
        do {
            references = try await confirmedUploads(jobID: jobID)
        } catch PrintError.server(let status, let message) where status == 404 {
            state.forget(files.map(\.name))
            throw PrintError.server(status: status, message: message)
        }
        guard files.allSatisfy({ references[$0.name] != nil }) else {
            throw PrintError.unexpectedResponse("missing uploaded files")
        }
        return references
    }

    /// Step 1; nil when the server has no signed uploads.
    func requestUploads(jobID: String, files: [PrintPayload.File]) async throws -> [String: UploadSlot]? {
        let (data, response) = try await session.data(for: try makeUploadsRequest(jobID: jobID, files: files))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 405 { return nil }
        guard (200..<300).contains(status) else { throw PrintError.server(status: status, message: Self.errorMessage(from: data)) }
        struct Plan: Decodable { let uploads: [String: UploadSlot] }
        guard let plan = try? JSONDecoder().decode(Plan.self, from: data) else {
            throw PrintError.unexpectedResponse("invalid upload URLs")
        }
        for file in files where plan.uploads[file.name] == nil {
            throw PrintError.unexpectedResponse("no upload URL for \(file.name)")
        }
        return plan.uploads
    }

    /// Steps 1 and 2; false when the job should use the multipart POST instead: the server has no signed uploads,
    /// or they failed before step 3 (e.g. storage denying every PUT once the URL renewals are used up).
    private func uploadOrFallBack(_ files: [PrintPayload.File], jobID: String, state: PrintUploadState,
                                  onProgress: @escaping @Sendable (PrintProgress) -> Void) async throws -> Bool {
        do {
            return try await upload(files, jobID: jobID, state: state, onProgress: onProgress)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { throw error }
            return false
        }
    }

    /// Steps 1 and 2 for `files`; false when the server has no signed uploads.
    private func upload(_ files: [PrintPayload.File], jobID: String, state: PrintUploadState,
                        onProgress: @escaping @Sendable (PrintProgress) -> Void) async throws -> Bool {
        guard var slots = try await requestUploads(jobID: jobID, files: files) else { return false }
        if slots.values.contains(where: { $0.file_id != nil && $0.get_url != nil }) {
            state.supportsConfirmation = true
        }
        let folder = Self.uploadDirectory.appendingPathComponent(jobID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let total = Double(max(1, files.reduce(0) { $0 + $1.data.count }))
        var sent = 0
        onProgress(PrintProgress(stage: "uploading", message: "Uploading to print server", progress: 0))
        for file in files {
            let source = folder.appendingPathComponent(file.name)
            try file.data.write(to: source, options: .atomic)
            var renewals = 0
            while true {
                guard let slot = slots[file.name] else { throw PrintError.unexpectedResponse("no upload URL for \(file.name)") }
                var request = URLRequest(url: slot.url, timeoutInterval: 600)
                request.httpMethod = slot.method ?? "PUT"
                for (field, value) in slot.headers ?? [:] { request.setValue(value, forHTTPHeaderField: field) }
                let base = sent
                let (status, body) = try await uploader.upload(request, fromFile: source) { bytes in
                    onProgress(PrintProgress(stage: "uploading", message: "Uploading to print server", progress: min(1, Double(base + Int(bytes)) / total)))
                }
                if (200..<300).contains(status) { break }
                // An expired URL (e.g. a suspended upload resumed late) gets a fresh one for this file.
                guard status == 403, renewals < 2, let fresh = try await requestUploads(jobID: jobID, files: [file]) else {
                    throw PrintError.server(status: status, message: "Uploading \(file.name) failed: " + Self.storageMessage(from: body))
                }
                renewals += 1
                slots.merge(fresh) { $1 }
            }
            sent += file.data.count
            state.markUploaded(file.name)
        }
        onProgress(PrintProgress(stage: "waiting", message: "Waiting for print server", progress: nil))
        return true
    }

    /// S3's XML `<Message>`, else the body as text.
    static func storageMessage(from data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        if let start = text.range(of: "<Message>"), let end = text.range(of: "</Message>", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
        }
        return errorMessage(from: data)
    }

    static var uploadDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PrintUploads", isDirectory: true)
    }

    enum JobRoute: String { case events = "", result }

    func jobRequest(id: String, route: JobRoute = .events) -> URLRequest {
        var url = endpoint.appendingPathComponent(id)
        if !route.rawValue.isEmpty { url.appendPathComponent(route.rawValue) }
        var request = URLRequest(url: url, timeoutInterval: route == .result ? 86400 : 600)
        request.setValue(route == .result ? "model/stl" : "application/x-ndjson", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func reattach(id: String, name: String, in directory: URL = PrintService.outputDirectory,
                  onProgress: @escaping @Sendable (PrintProgress) -> Void = { _ in }) async throws -> URL {
        try await receive(jobRequest(id: id), name: name, in: directory, onProgress: onProgress, onAccepted: { _ in })
    }

    private func receive(_ request: URLRequest, name: String, in directory: URL,
                         onProgress: @escaping @Sendable (PrintProgress) -> Void,
                         onAccepted: @escaping @Sendable (String) -> Void) async throws -> URL {
        let transfer = PrintTransfer(configuration: session.configuration, stallTimeout: stallTimeout, onProgress: onProgress, onAccepted: onAccepted)
        let result = try await withTaskCancellationHandler {
            try await transfer.run(request)
        } onCancel: {
            transfer.cancel()
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("stl")
        switch result {
        case .bytes(let data):
            try data.write(to: url, options: .atomic)
        case .remote(let signedURL):
            let (data, response) = try await session.data(from: signedURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                throw PrintError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Couldn't download STL from storage")
            }
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    /// Photo + depth fusion fields: `depth` (float32 LE metres), `depth_confidence` (uint8), `depth_width`, `depth_height`,
    /// `intrinsics` (photo pixels) and `object_points` ([[u, v]] photo pixels).
    private static func addDepth<Form: PrintFormBuilder>(_ depth: DepthCapture, to form: inout Form) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        form.addFile(name: "depth", fileName: "depth.f32", contentType: "application/octet-stream", data: depth.depthData)
        if let confidence = depth.confidence {
            form.addFile(name: "depth_confidence", fileName: "confidence.u8", contentType: "application/octet-stream", data: Data(confidence))
        }
        form.addField(name: "depth_width", value: String(depth.width))
        form.addField(name: "depth_height", value: String(depth.height))
        form.addField(name: "intrinsics", value: String(decoding: try encoder.encode(depth.intrinsics), as: UTF8.self))
        let points = depth.objectPoints.map { [($0.x * 10).rounded() / 10, ($0.y * 10).rounded() / 10] }
        form.addField(name: "object_points", value: String(decoding: try encoder.encode(points), as: UTF8.self))
    }

    /// The `detail` of a JSON error body (a string, or a list of `{"msg"}` validation errors), else the body as text.
    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String { return detail }
            if let details = json["detail"] as? [[String: Any]] {
                let messages = details.compactMap { $0["msg"] as? String }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            }
        }
        return String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func failureMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        if (error as? URLError)?.code == .unknown || message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unknown error" {
            return "Couldn't contact the print server. Check your connection and retry."
        }
        return message
    }

    static var outputDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Prints", isDirectory: true)
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "usdz": return "model/vnd.usdz+zip"
        case "obj": return "model/obj"
        case "ply": return "application/x-ply"
        default: return "application/octet-stream"
        }
    }
}

private final class PrintTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Output {
        case bytes(Data)
        case remote(URL)
    }
    private let queue = DispatchQueue(label: "PrintTransfer")
    private let configuration: URLSessionConfiguration
    private let stallTimeout: TimeInterval
    private let onProgress: @Sendable (PrintProgress) -> Void
    private let onAccepted: @Sendable (String) -> Void
    private var session: URLSession?
    private var continuation: CheckedContinuation<Output, Error>?
    private var response: HTTPURLResponse?
    private var buffer = Data()
    private var watchdog: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var cancelled = false

    init(configuration: URLSessionConfiguration, stallTimeout: TimeInterval, onProgress: @escaping @Sendable (PrintProgress) -> Void, onAccepted: @escaping @Sendable (String) -> Void) {
        self.configuration = configuration
        self.stallTimeout = stallTimeout
        self.onProgress = onProgress
        self.onAccepted = onAccepted
    }

    func run(_ request: URLRequest) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                if self.cancelled { self.finish(.failure(CancellationError())); return }
                let delegateQueue = OperationQueue()
                delegateQueue.maxConcurrentOperationCount = 1
                delegateQueue.underlyingQueue = self.queue
                self.session = URLSession(configuration: self.configuration, delegate: self, delegateQueue: delegateQueue)
                let deadline = DispatchWorkItem { self.finish(.failure(URLError(.timedOut))) }
                self.deadline = deadline
                self.queue.asyncAfter(deadline: .now() + 600, execute: deadline)
                self.onProgress(.uploading)
                self.session?.dataTask(with: request).resume()
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.finish(.failure(CancellationError()))
        }
    }

    private var streaming: Bool {
        response?.mimeType?.lowercased() == "application/x-ndjson" && (200..<300).contains(response?.statusCode ?? 0)
    }

    private func resetWatchdog() {
        watchdog?.cancel()
        let work = DispatchWorkItem {
            self.finish(.failure(PrintError.lostContact))
        }
        watchdog = work
        queue.asyncAfter(deadline: .now() + stallTimeout, execute: work)
    }

    private func finish(_ result: Result<Output, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel()
        deadline?.cancel()
        watchdog = nil
        deadline = nil
        session?.invalidateAndCancel()
        session = nil
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard continuation != nil, response == nil, totalBytesExpectedToSend > 0 else { return }
        onProgress(PrintProgress(stage: "uploading", message: "Uploading to print server", progress: min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
        if totalBytesSent >= totalBytesExpectedToSend {
            onProgress(PrintProgress(stage: "waiting", message: "Waiting for print server", progress: nil))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if streaming { resetWatchdog() } else { watchdog?.cancel() }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard continuation != nil else { return }
        buffer.append(data)
        guard streaming else { return }
        if !data.isEmpty { resetWatchdog() }
        while let newline = buffer.firstIndex(of: 10), continuation != nil {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { parse(line) }
        }
    }

    private struct Event: Decodable {
        let type: String
        let stage: String?
        let message: String?
        let progress: Double?
        let detail: String?
        let stl_base64: String?
        let stl_url: URL?
        let job_id: String?
    }

    private func parse(_ line: Data) {
        do {
            struct Envelope: Decodable { let type: String }
            let type = try JSONDecoder().decode(Envelope.self, from: line).type
            guard ["accepted", "progress", "error", "done"].contains(type) else { return }
            let event = try JSONDecoder().decode(Event.self, from: line)
            switch event.type {
            case "accepted":
                if let id = event.job_id, !id.isEmpty { onAccepted(id) }
            case "progress":
                onProgress(PrintProgress(stage: event.stage ?? "", message: event.message ?? event.stage ?? "Processing", progress: event.progress.map { min(1, max(0, $0)) }))
            case "error":
                finish(.failure(PrintError.jobFailed(event.detail ?? "Printing failed")))
            case "done":
                if let url = event.stl_url {
                    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                        throw PrintError.unexpectedResponse("invalid STL download URL")
                    }
                    finish(.success(.remote(url)))
                    return
                }
                guard let encoded = event.stl_base64, let data = Data(base64Encoded: encoded), !data.isEmpty else {
                    throw PrintError.unexpectedResponse("missing or invalid STL data")
                }
                finish(.success(.bytes(data)))
            default: break
            }
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard continuation != nil else { return }
        if let error { finish(.failure(error)); return }
        guard let response else { finish(.failure(PrintError.unexpectedResponse("no HTTP response"))); return }
        if response.statusCode == 409, let json = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
           let missing = json["missing"] as? [String] {
            finish(.failure(PrintError.uploadMissing(missing)))
        } else if !(200..<300).contains(response.statusCode) {
            finish(.failure(PrintError.server(status: response.statusCode, message: PrintService.errorMessage(from: buffer))))
        } else if streaming {
            if !buffer.isEmpty { parse(buffer) }
            finish(.failure(PrintError.unexpectedResponse("stream ended without a terminal event")))
        } else if !["model/stl", "application/sla", "application/vnd.ms-pki.stl", "application/octet-stream"].contains(response.mimeType?.lowercased() ?? "") {
            finish(.failure(PrintError.unexpectedResponse(response.mimeType ?? "no content type")))
        } else if buffer.isEmpty {
            finish(.failure(PrintError.unexpectedResponse("empty body")))
        } else { finish(.success(.bytes(buffer))) }
    }
}

protocol PrintFormBuilder {
    mutating func addField(name: String, value: String)
    mutating func addFile(name: String, fileName: String, contentType: String, data: Data)
}

/// A print request's fields and files, kept apart so files can go by signed URL.
struct PrintPayload: PrintFormBuilder {
    struct File: Equatable {
        let name: String
        let fileName: String
        let contentType: String
        let data: Data
    }

    private enum Part {
        case field(name: String, value: String)
        case file(File)
    }

    private var parts: [Part] = []

    var fields: [(name: String, value: String)] {
        parts.compactMap { if case .field(let name, let value) = $0 { return (name, value) } else { return nil } }
    }

    var files: [File] {
        parts.compactMap { if case .file(let file) = $0 { return file } else { return nil } }
    }

    mutating func addField(name: String, value: String) { parts.append(.field(name: name, value: value)) }

    mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        parts.append(.file(File(name: name, fileName: fileName, contentType: contentType, data: data)))
    }

    func write<Form: PrintFormBuilder>(to form: inout Form) {
        for part in parts {
            switch part {
            case .field(let name, let value): form.addField(name: name, value: value)
            case .file(let file): form.addFile(name: file.name, fileName: file.fileName, contentType: file.contentType, data: file.data)
            }
        }
    }
}

/// Which of a job's files already reached their signed URLs, kept across resends of the same job.
final class PrintUploadState: @unchecked Sendable {
    private let lock = NSLock()
    private var uploaded = Set<String>()
    private var usesMultipart = false
    private var hasReadURLs = false

    /// The server has no signed uploads, so this job uses the single multipart POST.
    var legacy: Bool {
        get { lock.withLock { usesMultipart } }
        set { lock.withLock { usesMultipart = newValue } }
    }

    var uploadedNames: Set<String> { lock.withLock { uploaded } }
    var supportsConfirmation: Bool {
        get { lock.withLock { hasReadURLs } }
        set { lock.withLock { hasReadURLs = newValue } }
    }
    func isUploaded(_ name: String) -> Bool { lock.withLock { uploaded.contains(name) } }
    func markUploaded(_ name: String) { _ = lock.withLock { uploaded.insert(name) } }
    func forget(_ names: [String]) { lock.withLock { uploaded.subtract(names) } }
}

/// PUTs a file to a signed URL and returns the status and body.
protocol PrintUploading: Sendable {
    func upload(_ request: URLRequest, fromFile file: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> (status: Int, body: Data)
}

struct SessionUploader: PrintUploading {
    let session: URLSession

    func upload(_ request: URLRequest, fromFile file: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.upload(for: request, fromFile: file, delegate: UploadProgress(onProgress: onProgress))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
        let onProgress: @Sendable (Int64) -> Void
        init(onProgress: @escaping @Sendable (Int64) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            onProgress(totalBytesSent)
        }
    }
}

struct MultipartForm: PrintFormBuilder {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
