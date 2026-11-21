import Foundation

enum ScanKind: String, CaseIterable {
    case room = "Room"
    case object = "Object"

    var systemImage: String {
        switch self {
        case .room: return "house"
        case .object: return "cube"
        }
    }
}

struct ScanFile: Identifiable, Hashable {
    let url: URL
    let kind: ScanKind
    let createdAt: Date
    let byteCount: Int64

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Saved scans are USDZ files in Documents/Scans, so they also show up in the Files app.
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanFile] = []

    let directory: URL
    private let fileManager: FileManager

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
        scans = urls
            .filter { $0.pathExtension.lowercased() == "usdz" }
            .map(Self.scanFile(at:))
            .sorted { $0.createdAt > $1.createdAt }
    }

    func scans(of kind: ScanKind) -> [ScanFile] {
        scans.filter { $0.kind == kind }
    }

    func newScanURL(kind: ScanKind, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(kind.rawValue) \(formatter.string(from: date))"
        var url = directory.appendingPathComponent("\(base).usdz")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(suffix)).usdz")
            suffix += 1
        }
        return url
    }

    func delete(_ scan: ScanFile) throws {
        try fileManager.removeItem(at: scan.url)
        reload()
    }

    func deleteAll() {
        for scan in scans {
            try? fileManager.removeItem(at: scan.url)
        }
        reload()
    }

    /// Creates placeholder scans so the library can be exercised on the simulator, which has no LiDAR.
    func seedSamples() {
        let now = Date()
        let sample = Bundle.main.url(forResource: "SampleCube", withExtension: "usdz").flatMap { try? Data(contentsOf: $0) }
        for (offset, kind) in [ScanKind.room, .object].enumerated() {
            let url = newScanURL(kind: kind, date: now.addingTimeInterval(TimeInterval(-60 * offset)))
            fileManager.createFile(atPath: url.path, contents: sample ?? Data("sample".utf8))
        }
        reload()
    }

    nonisolated static func kind(forFileName name: String) -> ScanKind {
        ScanKind.allCases.first { name.hasPrefix($0.rawValue + " ") } ?? .object
    }

    nonisolated private static func scanFile(at url: URL) -> ScanFile {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        return ScanFile(
            url: url,
            kind: kind(forFileName: url.lastPathComponent),
            createdAt: values?.creationDate ?? .distantPast,
            byteCount: Int64(values?.fileSize ?? 0)
        )
    }
}
