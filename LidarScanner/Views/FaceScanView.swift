import ARKit
import AVFoundation
import RealityKit
import SwiftUI

/// Face print: the front TrueDepth camera reads the face's depth, and the print server fills in the back of the head to make a bust STL.
struct FaceScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FaceScanModel(fake: LaunchArguments.contains(LaunchArguments.fakeFaceCapture))

    var body: some View {
        NavigationStack {
            ZStack {
                if model.isFake {
                    Image(uiImage: FaceScanModel.sampleImage)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                } else {
                    FaceARView(model: model).ignoresSafeArea()
                }
                VStack {
                    Text(model.instruction)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("faceInstruction")
                    Spacer()
                    controls
                }
                .padding()
                if model.isPrinting {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text("Building the bust STL").font(.headline)
                        Button("Cancel", role: .cancel) { model.cancelPrint() }
                            .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("printProgress")
                }
            }
            .navigationTitle("Face Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("closeButton")
                }
            }
            .sheet(item: $model.printedModel) { printed in
                PrintResultView(model: printed)
            }
            .alert("Couldn't print face", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Stepper(value: $model.heightMM, in: 50...200, step: 10) {
                Text("Bust height: \(Int(model.heightMM)) mm")
                    .font(.headline)
                    .accessibilityIdentifier("bustHeight")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .accessibilityIdentifier("bustHeightStepper")
            Button {
                model.captureAndPrint()
            } label: {
                Label("Capture Face & Print", systemImage: "printer")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.faceDetected || model.isPrinting)
            .accessibilityIdentifier("captureFaceButton")
        }
    }
}

@MainActor
final class FaceScanModel: ObservableObject {
    @Published private(set) var faceDetected: Bool
    @Published private(set) var isPrinting = false
    @Published var heightMM = FaceCapture.defaultHeightMM
    @Published var printedModel: PrintedModel?
    @Published var errorMessage: String?

    let isFake: Bool
    private var pendingCapture: Date?
    private var printTask: Task<Void, Never>?

    /// Depth arrives at about 15 fps; after this long without it, print from the photo and face mesh alone.
    private static let depthWait: TimeInterval = 1

    init(fake: Bool) {
        isFake = fake
        faceDetected = fake
    }

    var instruction: String {
        if isPrinting { return "Hold on while the print server builds your bust." }
        if !faceDetected { return "Hold the phone at arm's length and look straight at the screen." }
        return "Keep still with a neutral expression, then capture."
    }

    func captureAndPrint() {
        guard !isPrinting else { return }
        if isFake {
            upload(Self.sampleCapture(heightMM: heightMM))
        } else {
            pendingCapture = Date()
        }
    }

    func cancelPrint() {
        printTask?.cancel()
    }

    /// Called for every AR frame; takes the capture from the first frame with depth after the button was tapped.
    func handle(frame: ARFrame) {
        let face = frame.anchors.lazy.compactMap { $0 as? ARFaceAnchor }.first { $0.isTracked }
        if faceDetected != (face != nil) { faceDetected = face != nil }
        guard let requested = pendingCapture, let face else { return }
        guard frame.capturedDepthData != nil || Date().timeIntervalSince(requested) > Self.depthWait else { return }
        pendingCapture = nil
        guard let capture = Self.capture(from: frame, face: face, heightMM: heightMM) else {
            errorMessage = "Couldn't read the camera frame. Try again."
            return
        }
        upload(capture)
    }

    private func upload(_ capture: FaceCapture) {
        isPrinting = true
        printTask = Task {
            do {
                let url = try await PrintService().requestSTL(for: .face(capture), name: Self.fileName())
                try Task.checkCancellation()
                printedModel = PrintedModel(url: url, kind: .face)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
            isPrinting = false
            printTask = nil
        }
    }

    nonisolated static func capture(from frame: ARFrame, face: ARFaceAnchor, heightMM: Double) -> FaceCapture? {
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let photo = CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                         options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]) else { return nil }
        let camera = frame.camera
        let width = CVPixelBufferGetWidth(frame.capturedImage)
        let height = CVPixelBufferGetHeight(frame.capturedImage)
        return FaceCapture(
            photo: photo,
            intrinsics: .init(matrix: camera.intrinsics, reference: camera.imageResolution, width: width, height: height),
            cameraTransform: FaceCapture.columns(camera.transform),
            imageOrientation: FaceCapture.uprightOrientation(cameraTransform: camera.transform),
            depth: frame.capturedDepthData.flatMap(depth(from:)),
            faceTransform: FaceCapture.columns(face.transform),
            faceVertices: face.geometry.vertices.flatMap { [$0.x, $0.y, $0.z] },
            heightMM: heightMM
        )
    }

    nonisolated static func depth(from data: AVDepthData) -> FaceCapture.Depth? {
        let converted = data.depthDataType == kCVPixelFormatType_DepthFloat32 ? data : data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let map = FaceCapture.depthValues(from: converted.depthDataMap) else { return nil }
        let calibration = converted.cameraCalibrationData
        return FaceCapture.Depth(
            values: map.values,
            width: map.width,
            height: map.height,
            intrinsics: calibration.map { .init(matrix: $0.intrinsicMatrix, reference: $0.intrinsicMatrixReferenceDimensions, width: map.width, height: map.height) },
            extrinsics: calibration.flatMap { FaceCapture.extrinsics($0.extrinsicMatrix) }
        )
    }

    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Face \(formatter.string(from: Date()))"
    }

    /// Stand-in face for simulator UI tests, which have no TrueDepth camera.
    nonisolated static let sampleImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 640)).image { context in
        UIColor.darkGray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 640))
        UIColor.systemOrange.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 120, y: 140, width: 240, height: 320))
    }

    /// A synthetic capture: a 64×48 depth map of a dome 40 cm away, an upright photo and a small face mesh.
    nonisolated static func sampleCapture(heightMM: Double) -> FaceCapture {
        let width = 64, height = 48
        var values = [Float32](repeating: .nan, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Float(x - width / 2) / 16, dy = Float(y - height / 2) / 20
                let r2 = dx * dx + dy * dy
                if r2 < 1 { values[y * width + x] = 0.4 - 0.08 * (1 - r2).squareRoot() }
            }
        }
        var face = matrix_identity_float4x4
        face.columns.3 = SIMD4(0, 0, -0.4, 1)
        return FaceCapture(
            photo: sampleImage.jpegData(compressionQuality: 0.9) ?? Data(),
            intrinsics: .init(fx: 500, fy: 500, cx: 240, cy: 320, width: 480, height: 640),
            cameraTransform: FaceCapture.columns(matrix_identity_float4x4),
            imageOrientation: .up,
            depth: .init(values: values, width: width, height: height,
                         intrinsics: .init(fx: 66.7, fy: 66.7, cx: 32, cy: 24, width: width, height: height)),
            faceTransform: FaceCapture.columns(face),
            faceVertices: [0, 0.05, 0.02, -0.03, 0, 0.03, 0.03, 0, 0.03, 0, -0.06, 0.02],
            heightMM: heightMM
        )
    }
}

private struct FaceARView: UIViewRepresentable {
    let model: FaceScanModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session.delegate = context.coordinator
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.session.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, ARSessionDelegate {
        let model: FaceScanModel
        init(model: FaceScanModel) { self.model = model }

        /// ARView's session delivers on the main queue.
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            MainActor.assumeIsolated { model.handle(frame: frame) }
        }
    }
}
