import Foundation

enum ScanKind: String, CaseIterable {
    case room = "Room"
    case object = "Object"
    case photo = "Photo Print"
    case face = "Face Print"

    var systemImage: String {
        switch self {
        case .room: return "house"
        case .object: return "cube"
        case .photo: return "camera.viewfinder"
        case .face: return "face.smiling"
        }
    }

    /// Prints made straight from the camera, saved as STLs without a source scan.
    var isStandalonePrint: Bool { self == .photo || self == .face }
}

struct ScanFile: Identifiable, Hashable {
    let url: URL
    let kind: ScanKind
    let createdAt: Date
    let byteCount: Int64
    let printedSTLURL: URL?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// The server's G-code for the CUHK MakerSpace Creality K1C, saved beside the STL.
    var printedGCodeURL: URL? {
        printedSTLURL.map(\.gcodeSidecar).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
}

/// Scans and saved print files live in Documents/Scans and also show up in Files.
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanFile] = []

    let directory: URL
    private let fileManager: FileManager
    private func printDirectory(for kind: ScanKind) -> URL {
        directory.appendingPathComponent("\(kind.rawValue)s", isDirectory: true)
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
        let prints = ScanKind.allCases.filter(\.isStandalonePrint).flatMap { kind in
            let printURLs = (try? fileManager.contentsOfDirectory(at: printDirectory(for: kind), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return printURLs.filter { $0.pathExtension.lowercased() == "stl" }.map {
                Self.scanFile(at: $0, kind: kind, printedSTLURL: $0)
            }
        }
        scans = (meshes + prints).sorted { $0.createdAt > $1.createdAt }
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
        guard scans.contains(where: { $0.id == scan.id && !$0.kind.isStandalonePrint }),
              fileManager.fileExists(atPath: scan.url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let stl = Self.sidecarURL(for: scan.url)
        try Data(contentsOf: source, options: .mappedIfSafe).write(to: stl, options: .atomic)
        copyGCode(from: source, to: stl)
        reload()
    }

    func savePrint(_ source: URL, kind: ScanKind) throws {
        precondition(kind.isStandalonePrint)
        let folder = printDirectory(for: kind)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent, extension: "stl")
        try Data(contentsOf: source, options: .mappedIfSafe).write(to: destination, options: .atomic)
        copyGCode(from: source, to: destination)
        reload()
    }

    private func copyGCode(from sourceSTL: URL, to stl: URL) {
        try? fileManager.removeItem(at: stl.gcodeSidecar)
        if fileManager.fileExists(atPath: sourceSTL.gcodeSidecar.path) {
            try? fileManager.copyItem(at: sourceSTL.gcodeSidecar, to: stl.gcodeSidecar)
        }
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
        if !scan.kind.isStandalonePrint {
            let stl = Self.sidecarURL(for: scan.url)
            if fileManager.fileExists(atPath: stl.path) {
                try fileManager.removeItem(at: stl)
            }
        }
        if let gcode = scan.printedGCodeURL { try? fileManager.removeItem(at: gcode) }
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
