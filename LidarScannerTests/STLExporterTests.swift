import XCTest
@testable import LidarScanner

@MainActor
final class STLExporterTests: XCTestCase {
    func testExportPreservesScaleAndTransformsWithCorrectWinding() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ExportSample", withExtension: "usdz"))
        let original = try Data(contentsOf: source)
        let file = try await STLExporter.export(source)
        XCTAssertEqual(file.url.lastPathComponent, "ExportSample.stl")
        let stl = try Data(contentsOf: file.url)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(stl.count, 84 + 4 * 50)
        guard stl.count == 84 + 4 * 50 else { return }
        XCTAssertEqual(stl[80..<84], Data([4, 0, 0, 0]))

        var vertices: [SIMD3<Float>] = []
        for face in 0..<4 {
            let offset = 84 + face * 50
            func vector(at offset: Int) -> SIMD3<Float> {
                let components = stride(from: offset, to: offset + 12, by: 4).map { index in
                    Float(bitPattern: UInt32(littleEndian: stl.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: index, as: UInt32.self)
                    }))
                }
                return SIMD3(components[0], components[1], components[2])
            }
            let normal = vector(at: offset)
            XCTAssertEqual(normal.x, 0, accuracy: 0.001)
            XCTAssertEqual(normal.y, -1, accuracy: 0.001)
            XCTAssertEqual(normal.z, 0, accuracy: 0.001)
            for i in 1...3 { vertices.append(vector(at: offset + i * 12)) }
        }
        let positiveX = vertices.map(\.x).filter { $0 > 0 }
        let negativeX = vertices.map(\.x).filter { $0 < 0 }
        XCTAssertEqual(try XCTUnwrap(positiveX.min()), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(positiveX.max()), 110, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(negativeX.min()), -110, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(negativeX.max()), -100, accuracy: 0.001)
        XCTAssertTrue(vertices.allSatisfy { abs($0.y + 300) < 0.001 })
        XCTAssertEqual(try XCTUnwrap(vertices.map(\.z).min()), 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(vertices.map(\.z).max()), 210, accuracy: 0.001)
    }
}
