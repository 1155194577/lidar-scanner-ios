import XCTest
@testable import LidarScanner

@MainActor
final class MeshHoleFinderTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "usdz"))
    }

    func testClosedBoxWithSplitFaceVerticesHasNoGaps() async throws {
        let report = try await MeshHoleFinder.analyze(fixture("ClosedBox"))
        XCTAssertEqual(report.holes.count, 0)
        XCTAssertEqual(report.boundsDiagonal, 0.1 * sqrt(3), accuracy: 0.001)
    }

    func testOpenBoxReportsTheMissingSide() async throws {
        let report = try await MeshHoleFinder.analyze(fixture("OpenBox"))
        let hole = try XCTUnwrap(report.holes.first)
        XCTAssertEqual(report.holes.count, 1)
        XCTAssertEqual(hole.edges.count, 4)
        XCTAssertEqual(hole.perimeter, 0.4, accuracy: 0.001)
        XCTAssertEqual(hole.side, .side)
        XCTAssertEqual(hole.direction.x, 1, accuracy: 0.001)
        XCTAssertEqual(hole.center.x, 0.05, accuracy: 0.001)
        XCTAssertEqual(hole.widthDescription, "about 13 cm")
    }

    func testOpenBottomIsReportedUnderneath() {
        // A tetrahedron-like cap: four sides meeting at the top, no bottom face.
        let positions: [SIMD3<Float>] = [[-1, 0, -1], [1, 0, -1], [1, 0, 1], [-1, 0, 1], [0, 2, 0]]
        let report = MeshHoleFinder.report(positions: positions,
                                           triangles: [(0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)])
        XCTAssertEqual(report.holes.first?.side, .bottom)
        XCTAssertEqual(report.holes.first?.rescanInstruction.hasPrefix("Flip the object"), true)
    }
}
