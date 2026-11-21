import ARKit
import RealityKit
import SwiftUI

/// Single-photo print: measure the object's height with LiDAR (tap its base, then its top), then send one photo plus the height to the print server.
struct PhotoPrintView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PhotoPrintModel(fake: LaunchArguments.contains(LaunchArguments.fakePhotoCapture))

    var body: some View {
        NavigationStack {
            ZStack {
                if model.isFake {
                    Image(uiImage: PhotoPrintModel.sampleImage)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                } else {
                    MeasureARView(model: model).ignoresSafeArea()
                }
                VStack {
                    Text(model.instruction)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("photoInstruction")
                    Spacer()
                    controls
                }
                .padding()
                if model.isPrinting {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text("Preparing STL for printing").font(.headline)
                        Button("Cancel", role: .cancel) { model.cancelPrint() }
                            .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("printProgress")
                }
            }
            .navigationTitle("Photo Print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("closeButton")
                }
            }
            .sheet(item: $model.printedModel) { printed in
                ActivityView(items: [printed.url]) { model.printedModel = nil }
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            .alert("Couldn't print photo", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let height = model.heightMM {
                Text("Height: \(Int(height.rounded())) mm")
                    .font(.title2.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("photoHeight")
            }
            HStack(spacing: 12) {
                Button("Reset") { model.reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.isFake || model.base == nil)
                Button {
                    model.print()
                } label: {
                    Label("Take Photo & Print", systemImage: "printer")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.heightMM == nil || model.isPrinting)
                .accessibilityIdentifier("takePhotoAndPrintButton")
            }
        }
    }
}

struct PrintedModel: Identifiable {
    let url: URL
    var id: URL { url }
}

@MainActor
final class PhotoPrintModel: ObservableObject {
    @Published private(set) var base: SIMD3<Float>?
    @Published private(set) var top: SIMD3<Float>?
    @Published private(set) var isPrinting = false
    @Published var printedModel: PrintedModel?
    @Published var errorMessage: String?

    let isFake: Bool
    weak var arView: ARView?
    private var markers: [AnchorEntity] = []
    private var printTask: Task<Void, Never>?

    init(fake: Bool) {
        isFake = fake
        if fake {
            base = .zero
            top = SIMD3(0, 0.12, 0)
        }
    }

    /// Vertical distance between the two tapped points.
    var heightMM: Double? {
        guard let base, let top else { return nil }
        let height = Double(abs(top.y - base.y)) * 1000
        return height > 1 ? height : nil
    }

    var instruction: String {
        if base == nil { return "Point at the object and tap where it sits on the surface." }
        if top == nil { return "Now tap the top of the object." }
        return "Frame the whole object, then take the photo."
    }

    func handleTap(at point: CGPoint) {
        guard let arView, !isPrinting,
              let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first else { return }
        let position = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        if base == nil || top != nil {
            reset()
            base = position
        } else {
            top = position
        }
        let anchor = AnchorEntity(world: position)
        anchor.addChild(ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [SimpleMaterial(color: .systemTeal, isMetallic: false)]))
        arView.scene.addAnchor(anchor)
        markers.append(anchor)
    }

    func reset() {
        markers.forEach { $0.removeFromParent() }
        markers = []
        base = nil
        top = nil
    }

    func print() {
        guard let height = heightMM else { return }
        guard let photo = capturePhoto() else {
            errorMessage = "Couldn't take the photo. Try again."
            return
        }
        isPrinting = true
        printTask = Task {
            do {
                let url = try await PrintService().requestSTL(for: .photo(photo, heightMM: height), name: Self.fileName())
                try Task.checkCancellation()
                printedModel = PrintedModel(url: url)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
            isPrinting = false
            printTask = nil
        }
    }

    func cancelPrint() {
        printTask?.cancel()
    }

    private func capturePhoto() -> Data? {
        if isFake { return Self.sampleImage.jpegData(compressionQuality: 0.9) }
        guard let buffer = arView?.session.currentFrame?.capturedImage else { return nil }
        let image = CIImage(cvPixelBuffer: buffer).oriented(.right)
        return CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
    }

    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Photo \(formatter.string(from: Date()))"
    }

    /// Stand-in photo for simulator UI tests, which have no camera.
    static let sampleImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { context in
        UIColor.darkGray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        UIColor.systemTeal.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 200, y: 300, width: 200, height: 260))
    }
}

private struct MeasureARView: UIViewRepresentable {
    let model: PhotoPrintModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        view.session.run(configuration)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        model.arView = view
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.session.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject {
        let model: PhotoPrintModel
        init(model: PhotoPrintModel) { self.model = model }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            model.handleTap(at: recognizer.location(in: view))
        }
    }
}
