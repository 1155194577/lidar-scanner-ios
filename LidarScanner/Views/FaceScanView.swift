import ARKit
import AVFoundation
import RealityKit
import SwiftUI

/// Face print: the front TrueDepth camera reads the face's depth, and the print server fills in the back of the head to make a bust STL.
struct FaceScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var printJobs: PrintJobManager
    @StateObject private var model = FaceScanModel(fake: LaunchArguments.contains(LaunchArguments.fakeFaceCapture),
                                                   turnHead: UserDefaults.standard.bool(forKey: FaceScanModel.turnHeadKey),
                                                   fakeStaysFront: LaunchArguments.contains(LaunchArguments.fakeFaceNoTurn))

    var body: some View {
        NavigationStack {
            ZStack {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { cameraPreview.ignoresSafeArea() }
            }
            .navigationTitle("Face Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("closeButton")
                }
            }
            .alert("Couldn't print face", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder private var cameraPreview: some View {
        if model.isFake {
            Color.black.overlay {
                Image(uiImage: FaceScanModel.sampleImage)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
        } else {
            FaceARView(model: model)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if model.isCapturing, model.targets.count > 1 {
                Text(model.progressText)
                    .font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("faceViewProgress")
                Button {
                    model.printNow()
                } label: {
                    Label("Print Now", systemImage: "printer")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.canPrintNow)
                .accessibilityIdentifier("printNowButton")
            } else {
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
                    model.captureAndPrint(using: printJobs)
                } label: {
                    Label(model.targets.count > 1 ? "Start Face Scan" : "Capture Face & Print", systemImage: model.targets.count > 1 ? "face.dashed" : "printer")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.faceDetected || model.isCapturing)
                .accessibilityIdentifier("captureFaceButton")
            }
        }
    }
}

@MainActor
final class FaceScanModel: ObservableObject {
    /// Settings toggle for turn-your-head capture; off sends only the front view, as servers without multi-view support expect.
    static let turnHeadKey = "faceTurnHeadCapture"
    /// Head yaw for each view, degrees, + to the user's own left: front, then left, then right.
    static let turnTargets: [Double] = [0, 30, 60, -30, -60]
    static let yawTolerance = 10.0

    @Published private(set) var faceDetected: Bool
    @Published private(set) var isCapturing = false
    @Published private(set) var step = 0
    @Published private(set) var yaw: Double?
    @Published var heightMM = FaceCapture.defaultHeightMM
    @Published var errorMessage: String?

    let isFake: Bool
    let targets: [Double]
    private let fakeStaysFront: Bool
    private var front: FaceCapture?
    private var views: [FaceCapture.View] = []
    private var inRangeSince: Date?
    private weak var manager: PrintJobManager?
    private var fakeTask: Task<Void, Never>?

    /// Depth arrives at about 15 fps; after this long on target without it, take the view from the photo alone.
    private static let depthWait: TimeInterval = 1

    init(fake: Bool, turnHead: Bool = false, fakeStaysFront: Bool = false) {
        isFake = fake
        faceDetected = fake
        targets = turnHead ? Self.turnTargets : [0]
        self.fakeStaysFront = fakeStaysFront
    }

    deinit { fakeTask?.cancel() }

    var capturedCount: Int { front == nil ? 0 : views.count + 1 }
    var canPrintNow: Bool { front != nil }
    var progressText: String { "\(capturedCount) of \(targets.count) views" }

    var instruction: String {
        guard isCapturing else {
            if !faceDetected { return "Hold the phone at arm's length and look straight at the screen." }
            return targets.count > 1
                ? "Keep the phone still. You'll look straight ahead, then slowly turn your head left and right."
                : "Keep still with a neutral expression, then capture."
        }
        if !faceDetected { return "Turn back a little until the camera finds your face." }
        let target = targets[step]
        if target == 0 { return "Keep still while the camera reads your face." }
        let side = target > 0 ? "left" : "right"
        if let yaw, abs(yaw - target) <= Self.yawTolerance { return "Hold it there…" }
        if let yaw, abs(yaw) > abs(target) + Self.yawTolerance, yaw.sign == target.sign { return "A little less — turn back slightly." }
        return abs(target) > 45 ? "Keep turning \(side) until the phone sees your ear." : "Slowly turn your head to the \(side)."
    }

    func captureAndPrint(using manager: PrintJobManager) {
        guard !isCapturing else { return }
        self.manager = manager
        front = nil
        views = []
        step = 0
        inRangeSince = nil
        isCapturing = true
        if isFake { runFakeCapture() }
    }

    /// Stops turning and prints with the views captured so far.
    func printNow() {
        guard isCapturing, let front else { return }
        finish(front)
    }

    /// Called for every AR frame; takes each view from the first frame with depth once the head is at that view's yaw.
    func handle(frame: ARFrame) {
        let face = frame.anchors.lazy.compactMap { $0 as? ARFaceAnchor }.first { $0.isTracked }
        if faceDetected != (face != nil) { faceDetected = face != nil }
        guard let face else {
            inRangeSince = nil
            return
        }
        let current = FaceCapture.yawDegrees(faceTransform: face.transform, cameraTransform: frame.camera.transform)
        if isCapturing, targets.count > 1 { yaw = (current * 2).rounded() / 2 }
        guard isCapturing, step < targets.count else { return }
        let target = targets[step]
        guard step == 0 && targets.count == 1 || abs(current - target) <= Self.yawTolerance else {
            inRangeSince = nil
            return
        }
        let since = inRangeSince ?? Date()
        inRangeSince = since
        guard frame.capturedDepthData != nil || Date().timeIntervalSince(since) > Self.depthWait else { return }
        inRangeSince = nil
        if step == 0 {
            guard let capture = Self.capture(from: frame, face: face, heightMM: heightMM) else {
                isCapturing = false
                errorMessage = "Couldn't read the camera frame. Try again."
                return
            }
            record(front: capture)
        } else if let view = Self.view(from: frame, face: face, yaw: current) {
            record(view: view)
        }
    }

    private func record(front capture: FaceCapture) {
        front = capture
        advance()
    }

    private func record(view: FaceCapture.View) {
        views.append(view)
        advance()
    }

    private func advance() {
        step += 1
        if step >= targets.count, let front { finish(front) }
    }

    private func finish(_ front: FaceCapture) {
        fakeTask?.cancel()
        var capture = front
        capture.heightMM = heightMM
        capture.extraViews = views
        isCapturing = false
        step = 0
        yaw = nil
        self.front = nil
        views = []
        manager?.start(input: .face(capture), name: Self.fileName(), kind: "face")
    }

    /// Simulator stand-in: the fake head reaches each target in turn (or stays facing front with `-UITestFakeFaceNoTurn`).
    private func runFakeCapture() {
        fakeTask?.cancel()
        fakeTask = Task { [weak self] in
            guard let self else { return }
            for (index, target) in self.targets.enumerated() {
                if index > 0, self.fakeStaysFront { return }
                try? await Task.sleep(for: .milliseconds(index == 0 ? 0 : 300))
                guard !Task.isCancelled, self.isCapturing, self.step == index else { return }
                self.yaw = target
                if index == 0 {
                    self.record(front: Self.sampleCapture(heightMM: self.heightMM))
                } else {
                    self.record(view: Self.sampleView(yaw: target))
                }
            }
        }
    }

    nonisolated static func view(from frame: ARFrame, face: ARFaceAnchor, yaw: Double) -> FaceCapture.View? {
        guard let capture = capture(from: frame, face: face, heightMM: FaceCapture.defaultHeightMM) else { return nil }
        return FaceCapture.View(photo: capture.photo, intrinsics: capture.intrinsics, cameraTransform: capture.cameraTransform,
                                imageOrientation: capture.imageOrientation, depth: capture.depth,
                                faceTransform: FaceCapture.columns(face.transform), yawDegrees: yaw)
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

extension FaceScanModel {
    /// The synthetic capture's head turned by `yaw` degrees about its up axis (+ to its own left).
    nonisolated static func sampleView(yaw: Double) -> FaceCapture.View {
        let sample = sampleCapture(heightMM: FaceCapture.defaultHeightMM)
        var face = simd_float4x4(simd_quatf(angle: Float(yaw * .pi / 180), axis: SIMD3(0, 1, 0)))
        face.columns.3 = SIMD4(0, 0, -0.4, 1)
        return FaceCapture.View(photo: sample.photo, intrinsics: sample.intrinsics, cameraTransform: sample.cameraTransform,
                                imageOrientation: sample.imageOrientation, depth: sample.depth,
                                faceTransform: FaceCapture.columns(face), yawDegrees: yaw)
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
