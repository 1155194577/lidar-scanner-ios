import Foundation

/// Turns a TripoSR surface (model units, Z up) into a print-ready binary STL in millimetres.
enum PrintableMesh {
    /// Scales `mesh` uniformly so it stands `heightMM` tall, centred on x/y with its base on z = 0.
    static func fitted(_ mesh: MarchingCubes.Mesh, heightMM: Float) -> MarchingCubes.Mesh {
        guard var low = mesh.positions.first else { return mesh }
        var high = low
        for p in mesh.positions {
            low = pointwiseMin(low, p)
            high = pointwiseMax(high, p)
        }
        let scale = heightMM / max(high.z - low.z, .leastNonzeroMagnitude)
        let anchor = SIMD3((low.x + high.x) / 2, (low.y + high.y) / 2, low.z)
        var out = mesh
        out.positions = mesh.positions.map { ($0 - anchor) * scale }
        return out
    }

    /// Binary STL with one facet per triangle; degenerate triangles are skipped.
    static func stl(_ mesh: MarchingCubes.Mesh) -> Data {
        var data = Data(count: 80)
        var body = Data()
        body.reserveCapacity(mesh.indices.count / 3 * 50)
        var count: UInt32 = 0
        func append(_ v: SIMD3<Float>) {
            for f in [v.x, v.y, v.z] { withUnsafeBytes(of: f.bitPattern.littleEndian) { body.append(contentsOf: $0) } }
        }
        for i in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = mesh.positions[Int(mesh.indices[i])]
            let b = mesh.positions[Int(mesh.indices[i + 1])]
            let c = mesh.positions[Int(mesh.indices[i + 2])]
            let u = b - a, w = c - a
            let normal = SIMD3(u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x)
            let length = (normal * normal).sum().squareRoot()
            guard length > 0, length.isFinite else { continue }
            append(normal / length); append(a); append(b); append(c)
            body.append(contentsOf: [0, 0])
            count += 1
        }
        withUnsafeBytes(of: count.littleEndian) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}
