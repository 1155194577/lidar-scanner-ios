import RealityKit
import SwiftUI
import UIKit

/// Shows a finished model with its holes filled in red, turned so the biggest one faces the viewer. Drag to turn it.
struct ModelGapView: UIViewRepresentable {
    let modelURL: URL
    let report: MeshGapReport

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.secondarySystemBackground)
        let coordinator = context.coordinator
        view.addGestureRecognizer(UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:))))
        coordinator.setUp(in: view, modelURL: modelURL, report: report)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.loading?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let pivot = Entity()
        private let camera = PerspectiveCamera()
        private var yaw: Float = 0
        private var pitch: Float = 0
        private var startYaw: Float = 0
        private var startPitch: Float = 0
        private var distance: Float = 1
        private var startDistance: Float = 1
        var loading: Task<Void, Never>?

        func setUp(in view: ARView, modelURL: URL, report: MeshGapReport) {
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(pivot)
            anchor.addChild(camera)
            view.scene.addAnchor(anchor)

            let content = Entity()
            content.position = -report.boundsCenter
            pivot.addChild(content)
            if let patches = Self.patchEntity(for: report.holes) {
                content.addChild(patches)
            }
            if let biggest = report.holes.first {
                let horizontal = SIMD2(biggest.direction.x, biggest.direction.z)
                // Face the hole, turned a little so the model around it shows too.
                yaw = (simd_length(horizontal) > 1e-4 ? -atan2(horizontal.x, horizontal.y) : 0) + 0.5
                pitch = max(-.pi / 2, min(.pi / 2, asin(max(-1, min(1, biggest.direction.y))) + 0.35))
            }
            distance = max(report.boundsDiagonal, 0.01) * 1.6
            apply()

            loading = Task { [weak content] in
                guard let model = try? await STLExporter.loadModel(at: modelURL) else { return }
                content?.addChild(model)
            }
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                startYaw = yaw
                startPitch = pitch
            }
            let translation = gesture.translation(in: gesture.view)
            yaw = startYaw + Float(translation.x) * 0.01
            pitch = max(-.pi / 2, min(.pi / 2, startPitch + Float(translation.y) * 0.01))
            apply()
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { startDistance = distance }
            distance = startDistance / Float(max(gesture.scale, 0.1))
            apply()
        }

        private func apply() {
            pivot.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
            camera.position = [0, 0, distance]
            camera.camera.near = distance / 100
        }

        /// A red fan over each hole, double-sided so it shows from any angle.
        static func patchEntity(for holes: [MeshHole]) -> ModelEntity? {
            var positions: [SIMD3<Float>] = []
            var indices: [UInt32] = []
            for hole in holes {
                let centerIndex = UInt32(positions.count)
                positions.append(hole.center)
                for (a, b) in hole.edges {
                    let base = UInt32(positions.count)
                    positions += [a, b]
                    indices += [centerIndex, base, base + 1, centerIndex, base + 1, base]
                }
            }
            guard !indices.isEmpty else { return nil }
            var descriptor = MeshDescriptor(name: "gaps")
            descriptor.positions = MeshBuffer(positions)
            descriptor.primitives = .triangles(indices)
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
            return ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .systemRed)])
        }
    }
}
