import Foundation

/// What gets sent to the print endpoint: a scan's mesh, or a single photo plus the LiDAR-measured object height.
enum PrintInput {
    case mesh(URL)
    case photo(Data, heightMM: Double, pose: CameraPose? = nil, depth: DepthCapture? = nil)
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

    var errorDescription: String? {
        switch self {
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
/// authorised with `Authorization: Bearer <token>`, answered with `model/stl` (errors are JSON `{"detail"}`).
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
    private let token: String?
    private let session: URLSession

    init(baseURL: String = PrintService.configuredBaseURL, token: String? = PrintService.configuredToken, session: URLSession = .shared) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw PrintError.invalidBaseURL(baseURL)
        }
        endpoint = url.appendingPathComponent("print")
        checkEndpoint = url.appendingPathComponent("photo-check")
        self.token = token
        self.session = session
    }

    func makeRequest(for input: PrintInput, boundary: String = "Boundary-\(UUID().uuidString)") throws -> URLRequest {
        var form = MultipartForm(boundary: boundary)
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
        }

        return post(form, to: endpoint, accept: "model/stl", timeout: 600)
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

    /// Uploads the input and writes the returned STL to `directory/<name>.stl`.
    func requestSTL(for input: PrintInput, name: String, in directory: URL = PrintService.outputDirectory) async throws -> URL {
        let (data, response) = try await session.data(for: try makeRequest(for: input))
        guard let http = response as? HTTPURLResponse else {
            throw PrintError.unexpectedResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PrintError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        let mimeType = http.mimeType?.lowercased() ?? ""
        guard ["model/stl", "application/sla", "application/vnd.ms-pki.stl", "application/octet-stream"].contains(mimeType) else {
            throw PrintError.unexpectedResponse(mimeType.isEmpty ? "no content type" : mimeType)
        }
        guard !data.isEmpty else {
            throw PrintError.unexpectedResponse("empty body")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("stl")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Photo + depth fusion fields: `depth` (float32 LE metres), `depth_confidence` (uint8), `depth_width`, `depth_height`,
    /// `intrinsics` (photo pixels) and `object_points` ([[u, v]] photo pixels).
    private static func addDepth(_ depth: DepthCapture, to form: inout MultipartForm) throws {
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

private struct MultipartForm {
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
