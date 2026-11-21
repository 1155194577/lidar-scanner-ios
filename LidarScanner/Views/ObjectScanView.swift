import RealityKit
import SwiftUI

struct ObjectScanView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ObjectScanModel()
    @State private var previewURL: URL?
    @State private var showsGuide = false

    var body: some View {
        ZStack {
            if let session = model.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
                VStack {
                    topBar
                    Spacer()
                    if session.state == .capturing && session.userCompletedScanPass {
                        CapturedPointsPreview(session: session)
                            .padding(.horizontal)
                    }
                    CaptureControls(session: session, rescan: model.rescanHole)
                        .padding()
                }
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        reconstructionStatus
                    }
                    .padding()
                    .padding(.top, 72)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { topBar }
            }
        }
        .onAppear { model.start(outputURL: store.newScanURL(kind: .object)) }
        .onDisappear { model.cancel() }
        .onChange(of: model.phase) { _, phase in
            if case .done = phase { store.reload() }
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showsGuide) { ObjectScanGuideView() }
    }

    private var topBar: some View {
        HStack {
            Button(model.isFinished ? "Close" : "Cancel") {
                model.cancel()
                dismiss()
            }
            .buttonStyle(.bordered)
            Spacer()
            Button { showsGuide = true } label: {
                Label("How to scan", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    @ViewBuilder
    private var reconstructionStatus: some View {
        switch model.phase {
        case .preparing, .capturing:
            ProgressView()
        case .reconstructing(let fraction):
            Image(systemName: "cube.transparent").font(.system(size: 64))
            Text("Building 3D model").font(.title2.bold())
            ProgressView(value: fraction)
            Text("\(Int(fraction * 100))% — keep the app open.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView()
            Text("Checking the model for gaps…").font(.title3)
        case .done(let url, let report):
            if let report, let biggest = report.holes.first {
                gapReview(url: url, report: report, biggest: biggest)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                Text("Model saved").font(.title2.bold())
                Text(report == nil ? "Couldn't check the model for gaps." : "No gaps found. Every side was captured.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("gapCheckResult")
                Button("View in 3D") { previewURL = url }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            Button("Try Again") { model.start(outputURL: store.newScanURL(kind: .object)) }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func gapReview(url: URL, report: MeshGapReport, biggest: MeshHole) -> some View {
        Text(report.holes.count == 1 ? "1 part wasn't captured" : "\(report.holes.count) parts weren't captured")
            .font(.title2.bold())
            .accessibilityIdentifier("gapTitle")
        ModelGapView(modelURL: url, report: report)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("gapModelView")
        Text("Red shows the missing part: \(Self.place(biggest.side)), \(biggest.widthDescription) across. Drag to turn the model.")
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("gapSummary")
        Text(biggest.rescanInstruction)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        Button {
            model.rescan(biggest)
        } label: {
            Text("Rescan Missing Part").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("rescanGapButton")
        HStack {
            Button("View in 3D") { previewURL = url }
            Spacer()
            Button("Keep As Is") {
                model.cancel()
                dismiss()
            }
            .accessibilityIdentifier("keepModelButton")
        }
        .buttonStyle(.bordered)
    }

    private static func place(_ side: MeshHole.Side) -> String {
        switch side {
        case .top: return "on the top"
        case .bottom: return "underneath"
        case .side: return "on the side"
        }
    }
}

/// The points Object Capture has reconstructed so far; thin or empty patches still need photos.
private struct CapturedPointsPreview: View {
    let session: ObjectCaptureSession

    var body: some View {
        VStack(spacing: 6) {
            ObjectCapturePointCloudView(session: session)
                .frame(height: 220)
            Text("Captured so far. Sparse or empty patches still need photos — scan them in the next pass.")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CaptureControls: View {
    let session: ObjectCaptureSession
    let rescan: MeshHole?
    @State private var pass = 1
    @State private var confirmsEarlyFinish = false

    var body: some View {
        VStack(spacing: 12) {
            Text(stepHeader).font(.headline)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.thinMaterial, in: Capsule())
            }
            HStack {
                switch session.state {
                case .ready:
                    primaryButton("Continue") { _ = session.startDetecting() }
                case .detecting:
                    primaryButton("Start Capture") { session.startCapturing() }
                case .capturing:
                    if rescan != nil {
                        photoCount
                        Spacer()
                        if session.numberOfShotsTaken >= 5 || session.userCompletedScanPass {
                            Button("Finish & Rebuild") { session.finish() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if session.userCompletedScanPass {
                        if pass < 3 {
                            primaryButton(pass == 1 ? "Pass 2 · Lower angle" : "Pass 3 · High angle") {
                                session.beginNewScanPass()
                                pass += 1
                            }
                            if pass == 2 && !session.feedback.contains(.objectNotFlippable) {
                                Button("Pass 3 · Flip object") {
                                    session.beginNewScanPassAfterFlip()
                                    pass += 1
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Button("Finish") { confirmsEarlyFinish = true }
                                .buttonStyle(.bordered)
                        } else {
                            primaryButton("Finish") { session.finish() }
                        }
                    } else {
                        photoCount
                        Spacer()
                        if session.numberOfShotsTaken >= 20 {
                            Button("Finish Early") { confirmsEarlyFinish = true }
                                .buttonStyle(.bordered)
                        }
                    }
                case .finishing:
                    ProgressView("Saving photos…")
                default:
                    EmptyView()
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .alert("Finish with fewer photos?", isPresented: $confirmsEarlyFinish) {
            Button("Keep Scanning", role: .cancel) {}
            Button("Finish Anyway") { session.finish() }
        } message: {
            Text("Fewer photos and angles can give a worse model with missing surfaces. Complete all three passes for better results.")
        }
    }

    private var photoCount: some View {
        Text("\(session.numberOfShotsTaken) / \(session.maximumNumberOfInputImages) photos")
            .font(.footnote.monospacedDigit())
            .padding(10)
            .background(.thinMaterial, in: Capsule())
    }

    private var stepHeader: String {
        if rescan != nil {
            switch session.state {
            case .ready, .detecting: return "Rescan · Fit the box"
            case .capturing: return "Rescan · Capture the missing part"
            default: return "Rescan · Finish"
            }
        }
        switch session.state {
        case .ready, .detecting: return "Step 1 of 3 · Fit the box"
        case .capturing: return "Step 2 of 3 · Capture pass \(pass) of 3"
        default: return "Step 3 · Finish"
        }
    }

    private var hint: String? {
        if let feedback = ObjectScanCoaching.feedbackMessage(session.feedback) { return feedback }
        switch session.state {
        case .ready:
            if let rescan { return rescan.rescanInstruction }
            return "Place the object on a plain surface with space to walk around it."
        case .detecting: return "Fit the box around the object, then start capturing."
        case .capturing:
            if let rescan {
                return rescan.rescanInstruction + " Your earlier photos are kept and the model is rebuilt from both."
            }
            return ObjectScanCoaching.instruction(pass: pass, completed: session.userCompletedScanPass)
        default: return nil
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// Runs the guided Object Capture session, reconstructs a USDZ on-device with PhotogrammetrySession,
/// then checks the model for holes and can rescan a missing part and rebuild from all the photos.
@MainActor
final class ObjectScanModel: ObservableObject {
    enum Phase: Equatable {
        case preparing, capturing
        case reconstructing(Double)
        case checking
        /// `report` is nil when the model couldn't be checked for gaps.
        case done(URL, MeshGapReport?)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var session: ObjectCaptureSession?
    /// The hole the current capture session is filling in, if it is a rescan.
    @Published private(set) var rescanHole: MeshHole?

    private var workspace: URL?
    private var outputURL: URL?
    private var captureCount = 0
    private var tasks: [Task<Void, Never>] = []
    private var photogrammetry: PhotogrammetrySession?
    private let fake = LaunchArguments.contains(LaunchArguments.fakeObjectCapture)

    var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }

    private var imagesDirectory: URL? {
        workspace?.appendingPathComponent("Images", isDirectory: true)
    }

    func start(outputURL: URL) {
        cancel()
        rescanHole = nil
        captureCount = 0
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObjectCapture/\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Images", isDirectory: true),
                                                    withIntermediateDirectories: true)
        } catch {
            phase = .failed("Couldn't prepare storage: \(error.localizedDescription)")
            return
        }
        self.workspace = workspace
        self.outputURL = outputURL
        if fake {
            fakeBuild(fixtureKey: "UITestObjectModelFixture")
        } else {
            beginCapture()
        }
    }

    /// Captures more photos of the part around `hole`, keeping the earlier photos, then rebuilds the model.
    func rescan(_ hole: MeshHole) {
        guard workspace != nil, outputURL != nil else { return }
        rescanHole = hole
        if fake {
            fakeBuild(fixtureKey: "UITestObjectRescanFixture")
        } else {
            beginCapture()
        }
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        photogrammetry?.cancel()
        photogrammetry = nil
        session?.cancel()
        session = nil
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        workspace = nil
    }

    private func beginCapture() {
        guard let workspace else { return }
        captureCount += 1
        // The first capture writes straight into Images so its checkpoint still matches the photos.
        let images = captureCount == 1
            ? workspace.appendingPathComponent("Images", isDirectory: true)
            : workspace.appendingPathComponent("Capture-\(captureCount)", isDirectory: true)
        let checkpoints = workspace.appendingPathComponent("Checkpoints-\(captureCount)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Couldn't prepare storage: \(error.localizedDescription)")
            return
        }

        var configuration = ObjectCaptureSession.Configuration()
        configuration.isOverCaptureEnabled = true
        configuration.checkpointDirectory = checkpoints
        let session = ObjectCaptureSession()
        session.start(imagesDirectory: images, configuration: configuration)
        self.session = session
        phase = .capturing

        let capture = captureCount
        tasks.append(Task { [weak self] in
            for await state in session.stateUpdates {
                self?.handle(state, capture: capture, images: images)
            }
        })
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState, capture: Int, images: URL) {
        switch state {
        case .completed:
            session = nil
            do {
                try collectPhotos(from: images, capture: capture)
            } catch {
                phase = .failed("Couldn't save the photos: \(error.localizedDescription)")
                return
            }
            let checkpoint = capture == 1
                ? workspace?.appendingPathComponent("Checkpoints-1", isDirectory: true) : nil
            reconstruct(checkpoint: checkpoint, ordering: capture == 1 ? .sequential : .unordered)
        case .failed(let error):
            if case ObjectCaptureSession.Error.cancelled = error { return }
            session = nil
            if rescanHole != nil {
                phase = .failed("Rescan failed: \(error.localizedDescription). Your previous model is still saved.")
            } else {
                phase = .failed("Capture failed: \(error.localizedDescription)")
            }
        default:
            break
        }
    }

    /// Moves a capture's photos into the shared Images folder, prefixed so later captures don't overwrite earlier ones.
    private func collectPhotos(from images: URL, capture: Int) throws {
        guard capture > 1, let destination = imagesDirectory else { return }
        let manager = FileManager.default
        for file in try manager.contentsOfDirectory(at: images, includingPropertiesForKeys: nil) {
            try manager.moveItem(at: file, to: destination.appendingPathComponent("c\(capture)-\(file.lastPathComponent)"))
        }
    }

    private func reconstruct(checkpoint: URL?, ordering: PhotogrammetrySession.Configuration.SampleOrdering) {
        guard let workspace, let images = imagesDirectory, let outputURL else { return }
        phase = .reconstructing(0)
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = ordering
        configuration.featureSensitivity = .high
        configuration.isObjectMaskingEnabled = true
        configuration.checkpointDirectory = checkpoint
        let built = workspace.appendingPathComponent("Model-\(captureCount).usdz")

        tasks.append(Task { [weak self] in
            do {
                let photogrammetry = try PhotogrammetrySession(input: images, configuration: configuration)
                self?.photogrammetry = photogrammetry
                try photogrammetry.process(requests: [.modelFile(url: built)])
                for try await output in photogrammetry.outputs {
                    guard let self else { return }
                    switch output {
                    case .requestProgress(_, let fraction):
                        self.phase = .reconstructing(fraction)
                    case .requestComplete:
                        self.photogrammetry = nil
                        await self.save(built, to: outputURL)
                    case .requestError(_, let error):
                        self.phase = .failed("Reconstruction failed: \(error.localizedDescription)")
                    case .processingCancelled:
                        self.phase = .failed("Reconstruction was cancelled.")
                    default:
                        break
                    }
                }
            } catch {
                self?.phase = .failed("Reconstruction failed: \(error.localizedDescription)")
            }
        })
    }

    private func check(_ model: URL) async {
        phase = .checking
        let report = try? await MeshHoleFinder.analyze(model)
        guard !Task.isCancelled else { return }
        rescanHole = nil
        phase = .done(model, report)
    }

    /// Moves a finished build over the saved scan; the first build has no saved scan to replace yet.
    private func save(_ built: URL, to outputURL: URL) async {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: outputURL.path) {
                _ = try manager.replaceItemAt(outputURL, withItemAt: built)
            } else {
                try manager.moveItem(at: built, to: outputURL)
            }
        } catch {
            phase = .failed("Couldn't save the model: \(error.localizedDescription)")
            return
        }
        await check(outputURL)
    }

    private func fakeBuild(fixtureKey: String) {
        guard let workspace, let outputURL else { return }
        captureCount += 1
        let built = workspace.appendingPathComponent("Model-\(captureCount).usdz")
        let contents = ProcessInfo.processInfo.environment[fixtureKey].flatMap { Data(base64Encoded: $0) } ?? Data()
        do {
            try contents.write(to: built)
        } catch {
            phase = .failed("Couldn't save the model: \(error.localizedDescription)")
            return
        }
        tasks.append(Task { [weak self] in await self?.save(built, to: outputURL) })
    }
}
