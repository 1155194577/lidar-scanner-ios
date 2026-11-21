import XCTest
@testable import LidarScanner

final class OnDeviceMeshTests: XCTestCase {
    private func signedVolume(_ mesh: MarchingCubes.Mesh) -> Float {
        var volume: Float = 0
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])]
            let c = mesh.positions[Int(mesh.indices[i + 2])]
            volume += (a * SIMD3(b.y * c.z - b.z * c.y, b.z * c.x - b.x * c.z, b.x * c.y - b.y * c.x)).sum() / 6
        }
        return volume
    }

    func testMarchingCubesSphereIsClosedAndFacesOutward() {
        let n = 64, radius: Float = 0.5
        var values = [Float](repeating: 0, count: n * n * n)
        for x in 0..<n { for y in 0..<n { for z in 0..<n {
            let p = SIMD3<Float>(Float(x), Float(y), Float(z)) / Float(n - 1) * 2 - 1
            values[(x * n + y) * n + z] = radius - (p * p).sum().squareRoot()
        } } }
        let mesh = MarchingCubes.extract(values, resolution: n, isovalue: 0, lower: -1, upper: 1)
        let expected = 4 / 3 * Float.pi * radius * radius * radius
        XCTAssertEqual(signedVolume(mesh), expected, accuracy: expected * 0.02)
        var uses: [UInt64: Int] = [:]
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let t = mesh.indices[i..<(i + 3)].map(UInt64.init)
            for (a, b) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])] { uses[min(a, b) << 32 | max(a, b), default: 0] += 1 }
        }
        XCTAssertTrue(uses.values.allSatisfy { $0 == 2 })
    }

    func testFittedMeshStandsOnBedAtMeasuredHeight() {
        let tetra = MarchingCubes.Mesh(positions: [SIMD3(0, 0, -0.5), SIMD3(1, 0, -0.5), SIMD3(0, 1, -0.5), SIMD3(0, 0, 0.5)],
                                       indices: [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3])
        let fitted = PrintableMesh.fitted(tetra, heightMM: 120)
        XCTAssertEqual(fitted.positions.map(\.z).min()!, 0, accuracy: 1e-4)
        XCTAssertEqual(fitted.positions.map(\.z).max()!, 120, accuracy: 1e-3)
        XCTAssertEqual(fitted.positions.map(\.x).max()! + fitted.positions.map(\.x).min()!, 0, accuracy: 1e-3)
        let stl = PrintableMesh.stl(fitted)
        XCTAssertEqual(stl.count, 84 + 4 * 50)
        XCTAssertEqual(stl[80..<84], Data([4, 0, 0, 0]))
    }

    func testPrintJobDecodesWithoutOnDeviceFlag() throws {
        let job = PrintJob(id: "a", name: "Old", kind: "photo", baseURL: "https://print.invalid")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        XCTAssertEqual(json["onDevice"] as? Bool, false)
        json.removeValue(forKey: "onDevice")
        let decoded = try JSONDecoder().decode(PrintJob.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.onDevice)
    }
}
