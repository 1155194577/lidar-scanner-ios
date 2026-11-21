import Foundation
import simd

/// A gap in a reconstructed model: a loop of mesh edges that only one triangle uses.
struct MeshHole: Equatable, Sendable {
    enum Side: Equatable, Sendable {
        case top, bottom, side
    }

    /// World-space boundary edges (meters, Y-up).
    let edges: [(SIMD3<Float>, SIMD3<Float>)]
    let center: SIMD3<Float>
    /// Unit vector from the model's centre towards the hole.
    let direction: SIMD3<Float>
    let perimeter: Float

    var side: Side {
        if direction.y > 0.7 { return .top }
        if direction.y < -0.7 { return .bottom }
        return .side
    }

    /// Diameter of a circle with the same perimeter.
    var width: Float { perimeter / .pi }

    var widthDescription: String {
        let centimeters = width * 100
        return centimeters < 1 ? "under 1 cm" : "about \(Int(centimeters.rounded())) cm"
    }

    var rescanInstruction: String {
        switch side {
        case .top: return "Scan from high above, looking down at the red area."
        case .bottom: return "Flip the object onto its side so the red area faces you, then scan it."
        case .side: return "Walk round to the red area and scan it from close up, at its height."
        }
    }

    static func == (lhs: MeshHole, rhs: MeshHole) -> Bool {
        lhs.center == rhs.center && lhs.perimeter == rhs.perimeter
    }
}

struct MeshGapReport: Equatable, Sendable {
    /// Significant holes, largest first.
    let holes: [MeshHole]
    let boundsCenter: SIMD3<Float>
    let boundsDiagonal: Float
}

enum MeshHoleFinder {
    /// Holes narrower than this share of the model's bounding-box diagonal are reconstruction noise.
    static let minimumRelativeWidth: Float = 0.04

    @MainActor
    static func analyze(_ source: URL) async throws -> MeshGapReport {
        let root = try await STLExporter.loadModel(at: source)
        var parts: [STLExporter.MeshPart] = []
        STLExporter.collectParts(from: root, into: &parts)
        let meshParts = parts
        return try await Task.detached(priority: .userInitiated) {
            try analyze(meshParts)
        }.value
    }

    static func analyze(_ parts: [STLExporter.MeshPart]) throws -> MeshGapReport {
        var positions: [SIMD3<Float>] = []
        var triangles: [(Int, Int, Int)] = []
        for part in parts {
            let base = positions.count
            positions += part.positions.map { point in
                let p = part.transform * SIMD4(point, 1)
                return SIMD3(p.x, p.y, p.z)
            }
            for offset in stride(from: 0, to: part.indices.count - 2, by: 3) {
                let i = Int(part.indices[offset]), j = Int(part.indices[offset + 1]), k = Int(part.indices[offset + 2])
                guard max(i, j, k) < part.positions.count else { continue }
                triangles.append((base + i, base + j, base + k))
            }
        }
        guard !triangles.isEmpty else { throw STLExporter.ExportError.noTriangles }
        return report(positions: positions, triangles: triangles)
    }

    static func report(positions: [SIMD3<Float>], triangles: [(Int, Int, Int)]) -> MeshGapReport {
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = -lower
        for index in Set(triangles.flatMap { [$0.0, $0.1, $0.2] }) {
            lower = simd_min(lower, positions[index])
            upper = simd_max(upper, positions[index])
        }
        let center = (lower + upper) / 2
        let diagonal = simd_distance(lower, upper)

        // Weld duplicated vertices (UV and normal seams) so seams don't count as open edges.
        let cell = max(diagonal * 1e-5, 1e-7)
        var welded: [SIMD3<Int32>: Int] = [:]
        var weldedPositions: [SIMD3<Float>] = []
        let remap = positions.map { point -> Int in
            let key = SIMD3<Int32>((point / cell).rounded(.toNearestOrAwayFromZero))
            if let id = welded[key] { return id }
            welded[key] = weldedPositions.count
            weldedPositions.append(point)
            return weldedPositions.count - 1
        }

        struct Edge: Hashable { let a: Int, b: Int }
        var uses: [Edge: Int] = [:]
        for (i, j, k) in triangles {
            let a = remap[i], b = remap[j], c = remap[k]
            guard a != b, b != c, a != c else { continue }
            for (u, v) in [(a, b), (b, c), (c, a)] {
                uses[Edge(a: min(u, v), b: max(u, v)), default: 0] += 1
            }
        }
        let open = uses.filter { $0.value == 1 }.map(\.key)

        var parent: [Int: Int] = [:]
        func root(_ x: Int) -> Int {
            var x = x
            while let p = parent[x], p != x {
                parent[x] = parent[p] ?? p
                x = p
            }
            return x
        }
        for edge in open {
            if parent[edge.a] == nil { parent[edge.a] = edge.a }
            if parent[edge.b] == nil { parent[edge.b] = edge.b }
            let ra = root(edge.a), rb = root(edge.b)
            if ra != rb { parent[ra] = rb }
        }
        let loops = Dictionary(grouping: open) { root($0.a) }.values

        let minimumWidth = diagonal * minimumRelativeWidth
        let holes = loops.compactMap { loop -> MeshHole? in
            let edges = loop.map { (weldedPositions[$0.a], weldedPositions[$0.b]) }
            var perimeter: Float = 0
            var weighted = SIMD3<Float>.zero
            for (a, b) in edges {
                let length = simd_distance(a, b)
                perimeter += length
                weighted += (a + b) / 2 * length
            }
            guard perimeter / .pi >= minimumWidth, perimeter > 0 else { return nil }
            let holeCenter = weighted / perimeter
            let offset = holeCenter - center
            let direction = simd_length(offset) > 1e-6 ? simd_normalize(offset) : SIMD3(0, -1, 0)
            return MeshHole(edges: edges, center: holeCenter, direction: direction, perimeter: perimeter)
        }
        return MeshGapReport(holes: holes.sorted { $0.perimeter > $1.perimeter },
                             boundsCenter: center, boundsDiagonal: diagonal)
    }
}
