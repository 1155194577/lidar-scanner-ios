import Combine
import Foundation
import RealityKit
import simd

final class STLFile: Identifiable, Sendable {
    let url: URL

    fileprivate init(url: URL) {
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

enum STLExporter {
    enum ExportError: LocalizedError {
        case unreadableScan, noTriangles, tooManyTriangles

        var errorDescription: String? {
            switch self {
            case .unreadableScan: return "This scan could not be opened as a 3D model."
            case .noTriangles: return "This scan does not contain any triangles to export."
            case .tooManyTriangles: return "This scan has too many triangles for an STL file."
            }
        }
    }

    private struct MeshPart: Sendable {
        let positions: [SIMD3<Float>]
        let indices: [UInt32]
        let transform: simd_float4x4
    }

    @MainActor
    static func export(_ source: URL) async throws -> STLFile {
        let root: Entity
        if #available(iOS 18.0, *) {
            root = try await Entity(contentsOf: source)
        } else {
            guard let entity = try await Entity.loadAsync(contentsOf: source).values.first(where: { _ in true }) else {
                throw ExportError.unreadableScan
            }
            root = entity
        }

        var parts: [MeshPart] = []
        collectParts(from: root, into: &parts)
        try Task.checkCancellation()

        let filename = source.deletingPathExtension().lastPathComponent + ".stl"
        let meshParts = parts
        let writer = Task.detached(priority: .userInitiated) {
            try write(meshParts, filename: filename)
        }
        return try await withTaskCancellationHandler {
            try await writer.value
        } onCancel: {
            writer.cancel()
        }
    }

    @MainActor
    private static func collectParts(from entity: Entity, into parts: inout [MeshPart]) {
        guard entity.isEnabled else { return }
        if let mesh = entity.components[ModelComponent.self]?.mesh {
            let contents = mesh.contents
            let entityTransform = entity.transformMatrix(relativeTo: nil)
            for model in contents.models {
                let instances = contents.instances.filter { $0.model == model.id }
                for part in model.parts {
                    guard let indices = part.triangleIndices?.elements else { continue }
                    let positions = part.positions.elements
                    for instance in instances {
                        parts.append(MeshPart(positions: positions, indices: indices,
                                              transform: entityTransform * instance.transform))
                    }
                }
            }
        }
        for child in entity.children {
            collectParts(from: child, into: &parts)
        }
    }

    private static func write(_ parts: [MeshPart], filename: String) throws -> STLFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = STLFile(url: directory.appendingPathComponent(filename))
        try Data(count: 84).write(to: file.url)
        let handle = try FileHandle(forWritingTo: file.url)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var count: UInt32 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for part in parts {
            let mirrored = simd_determinant(part.transform) < 0
            for offset in stride(from: 0, to: part.indices.count - 2, by: 3) {
                let i = Int(part.indices[offset])
                let j = Int(part.indices[offset + (mirrored ? 2 : 1)])
                let k = Int(part.indices[offset + (mirrored ? 1 : 2)])
                guard max(i, j, k) < part.positions.count else { continue }

                let a = stlPosition(part.positions[i], transform: part.transform)
                let b = stlPosition(part.positions[j], transform: part.transform)
                let c = stlPosition(part.positions[k], transform: part.transform)
                let cross = simd_cross(b - a, c - a)
                let squaredLength = simd_length_squared(cross)
                guard squaredLength.isFinite, squaredLength > 0 else { continue }
                guard count < UInt32.max else { throw ExportError.tooManyTriangles }

                for point in [cross / sqrt(squaredLength), a, b, c] {
                    append(point.x.bitPattern, to: &buffer)
                    append(point.y.bitPattern, to: &buffer)
                    append(point.z.bitPattern, to: &buffer)
                }
                append(UInt16(0), to: &buffer)
                count += 1
                if buffer.count >= 64 * 1024 {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }

        try Task.checkCancellation()
        guard count > 0 else { throw ExportError.noTriangles }
        try handle.write(contentsOf: buffer)
        try handle.seek(toOffset: 80)
        buffer.removeAll(keepingCapacity: true)
        append(count, to: &buffer)
        try handle.write(contentsOf: buffer)
        return file
    }

    private static func stlPosition(_ point: SIMD3<Float>, transform: simd_float4x4) -> SIMD3<Float> {
        let p = transform * SIMD4(point.x, point.y, point.z, 1)
        // RealityKit imports USD in meters, Y-up. Slicers conventionally expect millimeters, Z-up.
        return SIMD3(p.x, -p.z, p.y) * 1000
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to buffer: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { buffer.append(contentsOf: $0) }
    }
}
