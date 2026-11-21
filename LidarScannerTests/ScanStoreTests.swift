import XCTest
@testable import LidarScanner

@MainActor
final class ScanStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreatesDirectoryAndStartsEmpty() {
        let store = ScanStore(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(store.scans.isEmpty)
    }

    func testNewScanURLIsUniqueAndNamedByKind() throws {
        let store = ScanStore(directory: directory)
        let date = Date(timeIntervalSince1970: 0)
        let first = store.newScanURL(kind: .room, date: date)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Room "))
        XCTAssertEqual(first.pathExtension, "usdz")
        try Data().write(to: first)
        let second = store.newScanURL(kind: .room, date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" (2).usdz"))
    }

    func testReloadListsOnlyUSDZFilesWithKinds() throws {
        let store = ScanStore(directory: directory)
        try Data().write(to: store.newScanURL(kind: .room))
        try Data().write(to: store.newScanURL(kind: .object))
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        store.reload()
        XCTAssertEqual(store.scans.count, 2)
        XCTAssertEqual(store.scans(of: .room).count, 1)
        XCTAssertEqual(store.scans(of: .object).count, 1)
    }

    func testDeleteRemovesFile() throws {
        let store = ScanStore(directory: directory)
        store.seedSamples()
        XCTAssertEqual(store.scans.count, 2)
        let scan = try XCTUnwrap(store.scans.first)
        try store.delete(scan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scan.url.path))
        XCTAssertEqual(store.scans.count, 1)
        store.deleteAll()
        XCTAssertTrue(store.scans.isEmpty)
    }

    func testPrintedSTLStaysWithItsScanAcrossReloadAndCanBeReplaced() throws {
        let store = ScanStore(directory: directory)
        store.seedSamples()
        let scan = try XCTUnwrap(store.scans(of: .room).first)
        let model = scan.url.deletingPathExtension().appendingPathExtension("stl")
        let source = directory.appendingPathComponent("server-download.tmp")
        let originalScan = try Data(contentsOf: scan.url)
        let firstPrint = Data("first STL".utf8)
        try firstPrint.write(to: source)
        try store.savePrintedSTL(source, for: scan)

        let reloaded = ScanStore(directory: directory)
        XCTAssertEqual(reloaded.scans(of: .room).first?.printedSTLURL, model)
        XCTAssertNil(reloaded.scans(of: .object).first?.printedSTLURL)
        XCTAssertEqual(reloaded.scans.count, 2)
        XCTAssertEqual(try Data(contentsOf: model), firstPrint)

        let secondPrint = Data("second STL".utf8)
        try secondPrint.write(to: source)
        try reloaded.savePrintedSTL(source, for: scan)
        XCTAssertEqual(try Data(contentsOf: model), secondPrint)
        XCTAssertEqual(try Data(contentsOf: scan.url), originalScan)

        try reloaded.delete(scan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
    }

    func testFacePrintsAreSavedInTheirOwnSection() throws {
        let store = ScanStore(directory: directory)
        let source = directory.appendingPathComponent("Face sample.stl")
        try Data("face STL".utf8).write(to: source)
        try store.savePrint(source, kind: .face)

        let reloaded = ScanStore(directory: directory)
        XCTAssertEqual(reloaded.scans(of: .face).map(\.name), ["Face sample"])
        XCTAssertTrue(reloaded.scans(of: .photo).isEmpty)
        XCTAssertEqual(reloaded.scans(of: .face).first?.url.deletingLastPathComponent().lastPathComponent, "Face Prints")
        reloaded.deleteAll()
        XCTAssertTrue(reloaded.scans.isEmpty)
    }

    func testPhotoPrintsAreStandaloneAndDoNotOverwriteEachOther() throws {
        let store = ScanStore(directory: directory)
        let source = directory.appendingPathComponent("Photo sample.stl")
        let contents = Data("photo STL".utf8)
        try contents.write(to: source)
        try store.savePrint(source, kind: .photo)
        try store.savePrint(source, kind: .photo)

        let reloaded = ScanStore(directory: directory)
        let photos = reloaded.scans(of: .photo)
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(Set(photos.map(\.name)), ["Photo sample", "Photo sample (2)"])
        for photo in photos {
            XCTAssertEqual(photo.printedSTLURL, photo.url)
            XCTAssertEqual(try Data(contentsOf: photo.url), contents)
        }
        reloaded.deleteAll()
        XCTAssertTrue(reloaded.scans.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testKindFromFileName() {
        XCTAssertEqual(ScanStore.kind(forFileName: "Room 2026-01-01.usdz"), .room)
        XCTAssertEqual(ScanStore.kind(forFileName: "Object 2026-01-01.usdz"), .object)
        XCTAssertEqual(ScanStore.kind(forFileName: "imported.usdz"), .object)
    }
}
