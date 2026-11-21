import RoomPlan
import SwiftUI

struct RoomScanView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = RoomScanController()
    @State private var savedURL: URL?

    var body: some View {
        ZStack {
            RoomCaptureContainer(captureView: controller.captureView)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if controller.phase == .scanning {
                        Button("Done") { controller.finishScanning() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding()

                Spacer()

                bottomPanel
                    .padding()
            }
        }
        .onAppear { controller.start() }
        .quickLookPreview($savedURL)
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch controller.phase {
        case .scanning:
            Text("Move slowly around the room, pointing at walls, floor and furniture.")
                .font(.footnote)
                .padding(10)
                .background(.thinMaterial, in: Capsule())
        case .processing:
            ProgressView("Building 3D model…")
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .processed:
            Button {
                save()
            } label: {
                Label("Save Scan", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .saved(let url):
            HStack {
                Button("View in 3D") { savedURL = url }
                    .buttonStyle(.bordered)
                Button("New Scan") { controller.start() }
                    .buttonStyle(.bordered)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).font(.footnote).multilineTextAlignment(.center)
                Button("Try Again") { controller.start() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .idle:
            EmptyView()
        }
    }

    private func save() {
        let url = store.newScanURL(kind: .room)
        controller.export(to: url)
        store.reload()
    }
}

private struct RoomCaptureContainer: UIViewRepresentable {
    let captureView: RoomCaptureView

    func makeUIView(context: Context) -> RoomCaptureView { captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

@MainActor
final class RoomScanController: NSObject, ObservableObject, @preconcurrency RoomCaptureViewDelegate {
    enum Phase: Equatable {
        case idle, scanning, processing, processed
        case saved(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    let captureView: RoomCaptureView
    private var capturedRoom: CapturedRoom?

    override init() {
        captureView = RoomCaptureView(frame: .zero)
        super.init()
        captureView.delegate = self
    }

    required init?(coder: NSCoder) {
        return nil
    }

    nonisolated func encode(with coder: NSCoder) {}

    func start() {
        capturedRoom = nil
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
    }

    func finishScanning() {
        captureView.captureSession.stop()
        phase = .processing
    }

    func cancel() {
        captureView.captureSession.stop()
        phase = .idle
    }

    func export(to url: URL) {
        guard let capturedRoom else { return }
        do {
            try capturedRoom.export(to: url, exportOptions: .parametric)
            phase = .saved(url)
        } catch {
            phase = .failed("Couldn't save the scan: \(error.localizedDescription)")
        }
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            guard self.phase == .processing else { return }
            if let error {
                self.phase = .failed("Scanning failed: \(error.localizedDescription)")
            } else {
                self.capturedRoom = processedResult
                self.phase = .processed
            }
        }
    }
}
