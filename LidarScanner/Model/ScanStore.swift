import Foundation

enum ScanKind: String, CaseIterable {
    case room = "Room"
    case object = "Object"
    case photo = "Photo Print"

    var systemImage: String {
        switch self {
        case .room: return "house"
        case .object: return "cube"
        case .photo: return "camera.viewfinder"
        }
    }
}

struct ScanFile: Identifiable, Hashable {
    let url: URL
    let kind: ScanKind
    let createdAt: Date
    let byteCount: Int64
    let printedSTLURL: URL?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Scans and saved print files live in Documents/Scans and also show up in Files.
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanFile] = []

    let directory: URL
    private let fileManager: FileManager
    private var photoPrintDirectory: URL {
        directory.appendingPathComponent("Photo Prints", isDirectory: true)
    }

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let meshes = urls.filter { $0.pathExtension.lowercased() == "usdz" }.map { url in
            let stl = Self.sidecarURL(for: url)
            return Self.scanFile(at: url, kind: Self.kind(forFileName: url.lastPathComponent),
                                 printedSTLURL: fileManager.fileExists(atPath: stl.path) ? stl : nil)
        }
        let photoURLs = (try? fileManager.contentsOfDirectory(at: photoPrintDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let photos = photoURLs.filter { $0.pathExtension.lowercased() == "stl" }.map {
            Self.scanFile(at: $0, kind: .photo, printedSTLURL: $0)
        }
        scans = (meshes + photos).sorted { $0.createdAt > $1.createdAt }
    }

    func scans(of kind: ScanKind) -> [ScanFile] {
        scans.filter { $0.kind == kind }
    }

    func newScanURL(kind: ScanKind, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return uniqueURL(in: directory, name: "\(kind.rawValue) \(formatter.string(from: date))", extension: "usdz")
    }

    func savePrintedSTL(_ source: URL, for scan: ScanFile) throws {
        guard scans.contains(where: { $0.id == scan.id && $0.kind != .photo }),
              fileManager.fileExists(atPath: scan.url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try Data(contentsOf: source, options: .mappedIfSafe)
            .write(to: Self.sidecarURL(for: scan.url), options: .atomic)
        reload()
    }

    func savePhotoPrint(_ source: URL) throws {
        try fileManager.createDirectory(at: photoPrintDirectory, withIntermediateDirectories: true)
        let destination = uniqueURL(in: photoPrintDirectory, name: source.deletingPathExtension().lastPathComponent, extension: "stl")
        try Data(contentsOf: source, options: .mappedIfSafe).write(to: destination, options: .atomic)
        reload()
    }

    private func uniqueURL(in directory: URL, name: String, extension fileExtension: String) -> URL {
        var url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name) (\(suffix))").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return url
    }

    func delete(_ scan: ScanFile) throws {
        defer { reload() }
        try removeFiles(for: scan)
    }

    func deleteAll() {
        for scan in scans {
            try? removeFiles(for: scan)
        }
        reload()
    }

    private func removeFiles(for scan: ScanFile) throws {
        if scan.kind != .photo {
            let stl = Self.sidecarURL(for: scan.url)
            if fileManager.fileExists(atPath: stl.path) {
                try fileManager.removeItem(at: stl)
            }
        }
        try fileManager.removeItem(at: scan.url)
    }

    /// Creates placeholder scans so the library can be exercised on the simulator, which has no LiDAR.
    func seedSamples(contents: Data? = nil) {
        let now = Date()
        let sample = contents != nil ? nil : Bundle.main.url(forResource: "SampleCube", withExtension: "usdz").flatMap { try? Data(contentsOf: $0) }
        for (offset, kind) in [ScanKind.room, .object].enumerated() {
            let url = newScanURL(kind: kind, date: now.addingTimeInterval(TimeInterval(-60 * offset)))
            fileManager.createFile(atPath: url.path, contents: contents ?? sample ?? Data("sample".utf8))
        }
        reload()
    }

    nonisolated static func kind(forFileName name: String) -> ScanKind {
        name.hasPrefix(ScanKind.room.rawValue + " ") ? .room : .object
    }

    nonisolated private static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("stl")
    }

    nonisolated private static func scanFile(at url: URL, kind: ScanKind, printedSTLURL: URL?) -> ScanFile {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        return ScanFile(
            url: url,
            kind: kind,
            createdAt: values?.creationDate ?? .distantPast,
            byteCount: Int64(values?.fileSize ?? 0),
            printedSTLURL: printedSTLURL
        )
    }
}
