import Foundation

/// What gets sent to the print endpoint: a scan's mesh, or a single photo plus the LiDAR-measured object height.
enum PrintInput {
    case mesh(URL)
    case photo(Data, heightMM: Double)
}

enum PrintError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case server(status: Int, message: String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "\"\(value)\" isn't a valid print server URL. Set it in Settings."
        case .server(let status, let message):
            return message.isEmpty ? "The print server returned HTTP \(status)." : "The print server returned HTTP \(status): \(message)"
        case .unexpectedResponse(let detail):
            return "The print server didn't return an STL file (\(detail))."
        }
    }
}

/// Client for `POST {baseURL}/print`: multipart `mesh` (OBJ, PLY or USDZ, in metres) or `photo` + `height_mm`, answered with `model/stl`.
struct PrintService {
    static let baseURLKey = "printBaseURL"

    static var defaultBaseURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "PrintBaseURL") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "http://localhost:8765"
    }

    /// The base URL set in Settings (or via `-printBaseURL <url>` at launch), else the build's default.
    static var configuredBaseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
    }

    let endpoint: URL
    private let session: URLSession

    init(baseURL: String = PrintService.configuredBaseURL, session: URLSession = .shared) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw PrintError.invalidBaseURL(baseURL)
        }
        endpoint = url.appendingPathComponent("print")
        self.session = session
    }

    func makeRequest(for input: PrintInput, boundary: String = "Boundary-\(UUID().uuidString)") throws -> URLRequest {
        var form = MultipartForm(boundary: boundary)
        switch input {
        case .mesh(let url):
            form.addFile(name: "mesh", fileName: url.lastPathComponent, contentType: Self.contentType(for: url), data: try Data(contentsOf: url))
        case .photo(let data, let heightMM):
            form.addFile(name: "photo", fileName: "photo.jpg", contentType: "image/jpeg", data: data)
            form.addField(name: "height_mm", value: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), heightMM))
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("model/stl", forHTTPHeaderField: "Accept")
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
            let message = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrintError.server(status: http.statusCode, message: message)
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
