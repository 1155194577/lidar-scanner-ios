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
                    CaptureControls(session: session)
                        .padding()
                }
            } else {
                VStack(spacing: 20) {
                    reconstructionStatus
                }
                .padding()
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
        case .done(let url):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("Model saved").font(.title2.bold())
            Button("View in 3D") { previewURL = url }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            Button("Try Again") { model.start(outputURL: store.newScanURL(kind: .object)) }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct CaptureControls: View {
    let session: ObjectCaptureSession
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
                    if session.userCompletedScanPass {
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
                        Text("\(session.numberOfShotsTaken) / \(session.maximumNumberOfInputImages) photos")
                            .font(.footnote.monospacedDigit())
                            .padding(10)
                            .background(.thinMaterial, in: Capsule())
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

    private var stepHeader: String {
        switch session.state {
        case .ready, .detecting: return "Step 1 of 3 · Fit the box"
        case .capturing: return "Step 2 of 3 · Capture pass \(pass) of 3"
        default: return "Step 3 · Finish"
        }
    }

    private var hint: String? {
        if let feedback = ObjectScanCoaching.feedbackMessage(session.feedback) { return feedback }
        switch session.state {
        case .ready: return "Place the object on a plain surface with space to walk around it."
        case .detecting: return "Fit the box around the object, then start capturing."
        case .capturing:
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

/// Runs the guided Object Capture session, then reconstructs a USDZ on-device with PhotogrammetrySession.
@MainActor
final class ObjectScanModel: ObservableObject {
    enum Phase: Equatable {
        case preparing, capturing
        case reconstructing(Double)
        case done(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var session: ObjectCaptureSession?

    private var workspace: URL?
    private var outputURL: URL?
    private var tasks: [Task<Void, Never>] = []
    private var photogrammetry: PhotogrammetrySession?

    var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }

    func start(outputURL: URL) {
        cancel()
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObjectCapture/\(UUID().uuidString)", isDirectory: true)
        let images = workspace.appendingPathComponent("Images", isDirectory: true)
        let checkpoints = workspace.appendingPathComponent("Checkpoints", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Couldn't prepare storage: \(error.localizedDescription)")
            return
        }
        self.workspace = workspace
        self.outputURL = outputURL

        var configuration = ObjectCaptureSession.Configuration()
        configuration.isOverCaptureEnabled = true
        configuration.checkpointDirectory = checkpoints
        let session = ObjectCaptureSession()
        session.start(imagesDirectory: images, configuration: configuration)
        self.session = session
        phase = .capturing

        tasks.append(Task { [weak self] in
            for await state in session.stateUpdates {
                self?.handle(state)
            }
        })
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

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        switch state {
        case .completed:
            session = nil
            reconstruct()
        case .failed(let error):
            if case ObjectCaptureSession.Error.cancelled = error { return }
            session = nil
            phase = .failed("Capture failed: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func reconstruct() {
        guard let workspace, let outputURL else { return }
        phase = .reconstructing(0)
        let images = workspace.appendingPathComponent("Images", isDirectory: true)
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .high
        configuration.isObjectMaskingEnabled = true
        configuration.checkpointDirectory = workspace.appendingPathComponent("Checkpoints", isDirectory: true)

        tasks.append(Task { [weak self] in
            do {
                let photogrammetry = try PhotogrammetrySession(input: images, configuration: configuration)
                self?.photogrammetry = photogrammetry
                try photogrammetry.process(requests: [.modelFile(url: outputURL)])
                for try await output in photogrammetry.outputs {
                    guard let self else { return }
                    switch output {
                    case .requestProgress(_, let fraction):
                        self.phase = .reconstructing(fraction)
                    case .requestComplete:
                        self.phase = .done(outputURL)
                        self.photogrammetry = nil
                        try? FileManager.default.removeItem(at: workspace)
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
}
