import SceneKit
import SwiftUI

struct STLPreview: View {
    let url: URL
    @State private var mesh: STLMesh?
    @State private var failed = false

    var body: some View {
        Group {
            if let mesh {
                STLScene(mesh: mesh)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Interactive 3D model")
                    .accessibilityIdentifier("stlViewer")
            } else if failed {
                ContentUnavailableView("Preview Unavailable", systemImage: "cube",
                                       description: Text("You can still save or share this STL."))
            } else {
                ProgressView("Loading 3D model…")
            }
        }
        .frame(height: 330)
        .frame(maxWidth: .infinity)
        .task(id: url) {
            let file = url
            let result = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: file, options: .mappedIfSafe)).flatMap(STLMesh.init(data:))
            }.value
            guard !Task.isCancelled else { return }
            mesh = result
            failed = result == nil
        }
    }
}

struct STLMesh {
    let vertices: [SIMD3<Float>]
    let normals: [SIMD3<Float>]

    init?(data: Data) {
        var positions = [SIMD3<Float>]()
        if data.count >= 84,
           let count = data.withUnsafeBytes({ bytes -> Int? in
               let count = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 80, as: UInt32.self)))
               return count == (data.count - 84) / 50 && (data.count - 84) % 50 == 0 ? count : nil
           }) {
            positions.reserveCapacity(count * 3)
            data.withUnsafeBytes { bytes in
                func float(at index: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
                }
                for face in 0..<count {
                    for vertex in 0..<3 {
                        let offset = 96 + face * 50 + vertex * 12
                        positions.append(SIMD3(float(at: offset), float(at: offset + 4), float(at: offset + 8)))
                    }
                }
            }
        } else if let text = String(data: data, encoding: .utf8), text.hasPrefix("solid") {
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.first == "vertex" else { continue }
                guard fields.count == 4, let x = Float(fields[1]), let y = Float(fields[2]), let z = Float(fields[3]) else { return nil }
                positions.append(SIMD3(x, y, z))
            }
        }
        guard let first = positions.first, positions.count.isMultiple(of: 3) else { return nil }
        var minimum = first
        var maximum = first
        for vertex in positions {
            guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else { return nil }
            minimum = simd_min(minimum, vertex)
            maximum = simd_max(maximum, vertex)
        }
        let size = maximum - minimum
        let extent = max(size.x, size.y, size.z)
        guard extent.isFinite, extent > 0 else { return nil }
        let center = minimum + size * 0.5
        vertices = positions.map { ($0 - center) / extent }
        var faceNormals = [SIMD3<Float>]()
        faceNormals.reserveCapacity(vertices.count)
        for index in stride(from: 0, to: vertices.count, by: 3) {
            let cross = simd_cross(vertices[index + 1] - vertices[index], vertices[index + 2] - vertices[index])
            let normal = simd_length_squared(cross) > 0 ? simd_normalize(cross) : SIMD3<Float>(0, 0, 1)
            faceNormals.append(contentsOf: [normal, normal, normal])
        }
        normals = faceNormals
    }
}

private struct STLScene: UIViewRepresentable {
    let mesh: STLMesh

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        let indices = mesh.vertices.indices.map { UInt32($0) }
        let triangles = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [
            SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) }),
            SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) })
        ], elements: [triangles])
        geometry.firstMaterial?.diffuse.contents = UIColor.systemTeal
        geometry.firstMaterial?.isDoubleSided = true
        let model = SCNNode(geometry: geometry)
        model.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(model)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(1.55, 1.2, 2.05)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        view.backgroundColor = .secondarySystemBackground
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.target = SCNVector3Zero
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}
