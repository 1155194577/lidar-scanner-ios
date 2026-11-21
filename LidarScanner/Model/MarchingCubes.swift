/// Marching cubes over a cubic grid of samples stored x-major: `values[(x * n + y) * n + z]`.
enum MarchingCubes {
    struct Mesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
    }

    private static let corners: [SIMD3<Int>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
    ]
    private static let edges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7),
    ]

    /// The surface where `values` crosses `isovalue`, with samples above it inside and triangles wound
    /// counter-clockwise seen from outside. Grid point `i` maps to `lower + i * (upper - lower) / (n - 1)` on each axis.
    static func extract(_ values: [Float], resolution n: Int, isovalue: Float, lower: Float, upper: Float) -> Mesh {
        precondition(n >= 2 && values.count == n * n * n)
        let step = (upper - lower) / Float(n - 1)
        var mesh = Mesh()
        var vertexForEdge: [Int: UInt32] = [:]
        var cube = [Float](repeating: 0, count: 8)
        var edgeVertex = [UInt32](repeating: 0, count: 12)

        for x in 0..<(n - 1) {
            for y in 0..<(n - 1) {
                for z in 0..<(n - 1) {
                    var caseIndex = 0
                    for (c, offset) in corners.enumerated() {
                        let value = values[((x + offset.x) * n + y + offset.y) * n + z + offset.z]
                        cube[c] = value
                        if value < isovalue { caseIndex |= 1 << c }
                    }
                    let triangles = triangleTable[caseIndex]
                    if triangles.isEmpty { continue }
                    for edge in Set(triangles) {
                        let (a, b) = edges[Int(edge)]
                        let pa = SIMD3(x, y, z) &+ corners[a], pb = SIMD3(x, y, z) &+ corners[b]
                        let origin = pointwiseMin(pa, pb)
                        let axis = pa.x != pb.x ? 0 : (pa.y != pb.y ? 1 : 2)
                        let key = ((origin.x * n + origin.y) * n + origin.z) * 3 + axis
                        if let index = vertexForEdge[key] {
                            edgeVertex[Int(edge)] = index
                            continue
                        }
                        let va = cube[a], vb = cube[b]
                        let t = va == vb ? 0.5 : (isovalue - va) / (vb - va)
                        let fa = SIMD3<Float>(Float(pa.x), Float(pa.y), Float(pa.z))
                        let fb = SIMD3<Float>(Float(pb.x), Float(pb.y), Float(pb.z))
                        let p = fa + (fb - fa) * t
                        let index = UInt32(mesh.positions.count)
                        mesh.positions.append(SIMD3(repeating: lower) + p * step)
                        vertexForEdge[key] = index
                        edgeVertex[Int(edge)] = index
                    }
                    for i in stride(from: 0, to: triangles.count, by: 3) {
                        mesh.indices.append(edgeVertex[Int(triangles[i])])
                        mesh.indices.append(edgeVertex[Int(triangles[i + 1])])
                        mesh.indices.append(edgeVertex[Int(triangles[i + 2])])
                    }
                }
            }
        }
        return mesh
    }
}
