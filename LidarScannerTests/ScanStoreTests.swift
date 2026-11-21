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

    func testKindFromFileName() {
        XCTAssertEqual(ScanStore.kind(forFileName: "Room 2026-01-01.usdz"), .room)
        XCTAssertEqual(ScanStore.kind(forFileName: "Object 2026-01-01.usdz"), .object)
        XCTAssertEqual(ScanStore.kind(forFileName: "imported.usdz"), .object)
    }
}
