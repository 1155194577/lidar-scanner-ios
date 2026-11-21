import Foundation

/// What gets sent to the print endpoint: a scan's mesh, a single photo plus the LiDAR-measured object height, or a TrueDepth face for a bust.
enum PrintInput {
    case mesh(URL)
    case photo(Data, heightMM: Double)
    case face(FaceCapture)
}

enum PrintError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case server(status: Int, message: String)
    case unexpectedResponse(String)
    case jobFailed(String)
    case lostContact
    case serverChanged

    var errorDescription: String? {
        switch self {
        case .serverChanged: return "Print server changed in Settings; print again"
        case .jobFailed(let detail): return detail
        case .lostContact: return "Lost contact with the print server. Please retry."
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
    private let token: String?
    private let session: URLSession
    private let stallTimeout: TimeInterval

    init(baseURL: String = PrintService.configuredBaseURL, token: String? = PrintService.configuredToken, session: URLSession = .shared, stallTimeout: TimeInterval = 10) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw PrintError.invalidBaseURL(baseURL)
        }
        endpoint = url.appendingPathComponent("print")
        self.token = token
        self.session = session
        self.stallTimeout = stallTimeout
    }

    func makeRequest(for input: PrintInput, boundary: String = "Boundary-\(UUID().uuidString)", jobID: String? = nil) throws -> URLRequest {
        var form = MultipartForm(boundary: boundary)
        if let jobID { form.addField(name: "job_id", value: jobID) }
        switch input {
        case .mesh(let url):
            form.addFile(name: "mesh", fileName: url.lastPathComponent, contentType: Self.contentType(for: url), data: try Data(contentsOf: url))
        case .photo(let data, let heightMM):
            form.addFile(name: "photo", fileName: "photo.jpg", contentType: "image/jpeg", data: data)
            form.addField(name: "height_mm", value: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), heightMM))
        case .face(let capture):
            try capture.addFields(to: &form)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson, model/stl", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = form.finalized()
        return request
    }

    /// Uploads the input and writes the returned STL to `directory/<name>.stl`.
    func requestSTL(for input: PrintInput, name: String, in directory: URL = PrintService.outputDirectory,
                    jobID: String? = nil,
                    onProgress: @escaping @Sendable (PrintProgress) -> Void = { _ in },
                    onAccepted: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        try await receive(try makeRequest(for: input, jobID: jobID), name: name, in: directory, onProgress: onProgress, onAccepted: onAccepted)
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
        let data = try await withTaskCancellationHandler {
            try await transfer.run(request)
        } onCancel: {
            transfer.cancel()
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("stl")
        try data.write(to: url, options: .atomic)
        return url
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

struct MultipartForm {
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
