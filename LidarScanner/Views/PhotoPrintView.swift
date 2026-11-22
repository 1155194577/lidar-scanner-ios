import ARKit
import RealityKit
import SwiftUI

/// Single-photo print: measure the object's height with LiDAR (tap its base, then its top), then send one photo plus the height to the print server.
struct PhotoPrintView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var printJobs: PrintJobManager
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
                        Text(model.progressText).font(.headline)
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
            .alert("Retake the photo?", isPresented: Binding(get: { model.photoIssues != nil }, set: { if !$0 { model.photoIssues = nil } })) {
                Button("Retake", role: .cancel) { model.retake() }
                Button("Print Anyway") { model.printAnyway(using: printJobs) }
            } message: {
                Text((model.photoIssues ?? []).map(\.message).joined(separator: "\n"))
            }
            .alert("Couldn't print photo", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("Retry") { model.print(using: printJobs) }
                Button("Dismiss", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
                    .accessibilityIdentifier("printError")
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
                    model.print(using: printJobs)
                } label: {
                    Label("Take Photo & Print", systemImage: "printer")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.heightMM == nil)
                .accessibilityIdentifier("takePhotoAndPrintButton")
            }
        }
    }
}

struct PrintedModel: Identifiable {
    let url: URL
    var sourceScanFileName: String? = nil
    var sourceScan: ScanFile? = nil
    var kind: ScanKind = .photo
    var optimisationRequested = false
    var optimisation: PrintOptimisation?
    var id: URL { url }

    @MainActor
    func save(in store: ScanStore) throws {
        if let scan = sourceScan {
            try store.savePrintedSTL(url, for: scan)
        } else if let fileName = sourceScanFileName {
            store.reload()
            guard let scan = store.scans.first(where: { $0.url.lastPathComponent == fileName && $0.kind != .photo }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try store.savePrintedSTL(url, for: scan)
        } else {
            try store.savePrint(url, kind: kind)
        }
    }
}

struct PrintResultView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @State private var isSharing = false
    @State private var isSaved = false
    @State private var saveError: String?
    let model: PrintedModel

    private var optimisationSummary: String {
        if let reason = model.optimisation?.skipped, !reason.isEmpty {
            return "Skipped: \(reason)"
        }
        if let percent = model.optimisation?.volumeSavedPct, (0...100).contains(percent) {
            return "\((percent / 100).formatted(.percent.precision(.fractionLength(0...1)))) less model volume"
        }
        return "The server did not report material savings."
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    STLPreview(url: model.url)
                        .listRowInsets(EdgeInsets())
                    Label(model.url.lastPathComponent, systemImage: "doc")
                }
                if model.optimisationRequested {
                    Section("Material Savings") {
                        Text(optimisationSummary)
                            .accessibilityIdentifier("printOptimisationSummary")
                    }
                }
                Section {
                    if isSaved {
                        Label("Saved to My Scans", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: save) {
                            Label(model.sourceScan == nil && model.sourceScanFileName == nil ? "Save to My Scans" : "Save to Scan", systemImage: "square.and.arrow.down")
                        }
                    }
                    Button {
                        isSharing = true
                    } label: {
                        Label("Share STL", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("STL Ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $isSharing) {
            ActivityView(items: [model.url]) { isSharing = false }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert("Couldn't save STL", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        do {
            try model.save(in: store)
            isSaved = true
        } catch {
            saveError = error.localizedDescription
        }
    }
}

@MainActor
final class PhotoPrintModel: ObservableObject {
    @Published private(set) var base: SIMD3<Float>?
    @Published private(set) var top: SIMD3<Float>?
    @Published var errorMessage: String?
    /// What `/photo-check` flagged about the last shot; the user retakes or prints anyway.
    @Published var photoIssues: [PhotoCheck.Issue]?
    @Published private(set) var isPrinting = false
    @Published private(set) var progressText = "Checking the photo"

    let isFake: Bool
    weak var arView: ARView?
    private var markers: [AnchorEntity] = []
    private var printTask: Task<Void, Never>?
    private var flaggedShot: Shot?

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
        guard let arView,
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

    func print(using manager: PrintJobManager) {
        guard !isPrinting, heightMM != nil else { return }
        guard let shot = capture() else {
            errorMessage = "Couldn't take the photo. Try again."
            return
        }
        if OnDeviceTripoSR.isAvailable, let height = heightMM {
            manager.startOnDevice(photo: shot.checkPhoto, heightMM: height, name: Self.fileName())
            return
        }
        isPrinting = true
        printTask = Task {
            // The check is advisory: if it fails or times out, print anyway.
            let check = try? await PrintService().checkPhoto(shot.checkPhoto, pose: shot.checkPose)
            if Task.isCancelled {
                finishPrinting()
                return
            }
            if let check, !check.ok, !check.issues.isEmpty {
                flaggedShot = shot
                photoIssues = check.issues
                finishPrinting()
                return
            }
            finishPrinting()
            upload(shot, using: manager)
        }
    }

    func printAnyway(using manager: PrintJobManager) {
        guard let shot = flaggedShot else { return }
        flaggedShot = nil
        photoIssues = nil
        upload(shot, using: manager)
    }

    func retake() {
        flaggedShot = nil
        photoIssues = nil
    }

    private func upload(_ shot: Shot, using manager: PrintJobManager) {
        guard let height = heightMM else { return }
        manager.start(input: .photo(shot.photo, heightMM: height, pose: shot.pose, depth: shot.depth), name: Self.fileName(), kind: "photo", allowsOptimisation: true)
    }

    private func finishPrinting() {
        isPrinting = false
        printTask = nil
    }

    func cancelPrint() {
        printTask?.cancel()
    }

    struct Shot {
        var photo: Data
        var pose: CameraPose
        var depth: DepthCapture?
        /// Upright photo and its camera for `/photo-check`; the same as `photo` and `pose` when there is no depth.
        var checkPhoto: Data
        var checkPose: CameraPose
    }

    /// The current frame as a JPEG plus the camera pose and LiDAR depth. With depth the photo stays in sensor orientation
    /// (the server rotates it by `image_orientation`); without it the photo is rotated upright.
    private func capture() -> Shot? {
        if isFake {
            guard let photo = Self.sampleImage.jpegData(compressionQuality: 0.9) else { return nil }
            let pose = Self.samplePose(pitchDegrees: Self.fakePitchDegrees)
            return Shot(photo: photo, pose: pose, depth: Self.sampleDepth, checkPhoto: photo, checkPose: pose)
        }
        guard let arView, let frame = arView.session.currentFrame else { return nil }
        let interface = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let orientation = Self.photoOrientation(for: interface)
        let depth = frame.depthCapture(objectPoints: [base, top].compactMap { $0 })
        let sensorImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let context = CIContext()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        // ARKit's camera for the interface orientation, whose axes match the upright photo.
        let uprightPose = CameraPose(cameraTransform: simd_inverse(frame.camera.viewMatrix(for: interface)).columnMajor, imageOrientation: .up)
        guard let upright = context.jpegRepresentation(of: sensorImage.oriented(orientation), colorSpace: sRGB, options: [:]) else { return nil }
        guard depth != nil else {
            return Shot(photo: upright, pose: uprightPose, depth: nil, checkPhoto: upright, checkPose: uprightPose)
        }
        guard let photo = context.jpegRepresentation(of: sensorImage, colorSpace: sRGB, options: [:]) else { return nil }
        let pose = CameraPose(cameraTransform: frame.camera.transform.columnMajor, imageOrientation: orientation)
        return Shot(photo: photo, pose: pose, depth: depth, checkPhoto: upright, checkPose: uprightPose)
    }

    /// How far the simulator's fake camera looks down; UI tests set it with `-UITestFakePitch <degrees>`.
    static var fakePitchDegrees: Double {
        UserDefaults.standard.object(forKey: LaunchArguments.fakePitchKey) == nil ? 50 : UserDefaults.standard.double(forKey: LaunchArguments.fakePitchKey)
    }

    /// Stand-in pose for simulator UI tests: looking `pitchDegrees` down at the object.
    static func samplePose(pitchDegrees: Double) -> CameraPose {
        let pitch = Float(pitchDegrees * .pi / 180)
        let c = cos(pitch), s = sin(pitch)
        return CameraPose(cameraTransform: [1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0.3, 0.25, 1], imageOrientation: .up)
    }

    /// Stand-in depth for simulator UI tests: a flat surface 0.5 m away, matching the upright sample photo.
    static let sampleDepth = DepthCapture(
        depth: Array(repeating: 0.5, count: 48 * 64),
        confidence: Array(repeating: 2, count: 48 * 64),
        width: 48,
        height: 64,
        intrinsics: CameraIntrinsics(fx: 700, fy: 700, cx: 300, cy: 400, width: 600, height: 800),
        objectPoints: [CGPoint(x: 300, y: 560), CGPoint(x: 300, y: 300)]
    )

    /// The camera buffer is in the sensor's landscape-right orientation; rotate it to match what the user sees.
    nonisolated static func photoOrientation(for interface: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch interface {
        case .landscapeRight: return .up
        case .landscapeLeft: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
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

private extension simd_float4x4 {
    var columnMajor: [Float] {
        [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}

private extension ARFrame {
    func depthCapture(objectPoints: [SIMD3<Float>]) -> DepthCapture? {
        guard let sceneDepth = smoothedSceneDepth ?? sceneDepth, let depth = Self.values(Float32.self, of: sceneDepth.depthMap) else { return nil }
        let k = camera.intrinsics
        let width = camera.imageResolution.width, height = camera.imageResolution.height
        // The measured world points projected into this frame, so they stay on the object if the phone moved since the taps.
        // `.landscapeRight` is the sensor's native orientation, i.e. the unrotated photo's pixels.
        let points = objectPoints.map { camera.projectPoint($0, orientation: .landscapeRight, viewportSize: camera.imageResolution) }
        return DepthCapture(
            depth: depth,
            confidence: sceneDepth.confidenceMap.flatMap { Self.values(UInt8.self, of: $0) },
            width: CVPixelBufferGetWidth(sceneDepth.depthMap),
            height: CVPixelBufferGetHeight(sceneDepth.depthMap),
            intrinsics: CameraIntrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]), width: Int(width), height: Int(height)),
            objectPoints: points
        )
    }

    static func values<T>(_ type: T.Type, of buffer: CVPixelBuffer) -> [T]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var out: [T] = []
        out.reserveCapacity(width * height)
        for row in 0..<height {
            let pointer = (base + row * rowBytes).assumingMemoryBound(to: T.self)
            out.append(contentsOf: UnsafeBufferPointer(start: pointer, count: width))
        }
        return out
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
