import SwiftUI
import UIKit

struct PrintUploadPreview: View {
    @EnvironmentObject private var manager: PrintJobManager
    @Environment(\.dismiss) private var dismiss
    let job: PrintJob
    @State var references: [String: PrintService.UploadReference]
    let onPrint: () -> Void
    @State private var error: String?
    @State private var refreshing = false

    private var mainUpload: PrintService.UploadReference? { references["photo"] ?? references["mesh"] }

    var body: some View {
        NavigationStack {
            List {
                if let photo = references["photo"] {
                    Section("Uploaded photo") {
                        AsyncImage(url: photo.get_url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                                    .accessibilityLabel("Uploaded photo preview")
                                    .accessibilityIdentifier("uploadedPhotoPreview")
                            case .failure:
                                Label("Couldn’t load photo from storage.", systemImage: "exclamationmark.icloud")
                            default:
                                ProgressView("Loading photo from storage…")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                    }
                }
                if let upload = mainUpload {
                    Section("S3 file") {
                        Text(upload.file_id)
                            .accessibilityIdentifier("uploadedFileID")
                            .textSelection(.enabled)
                        Button("Copy File ID", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = upload.file_id
                        }
                        Link("Open S3 Link", destination: upload.get_url)
                        Button("Copy S3 Link", systemImage: "link") {
                            UIPasteboard.general.url = upload.get_url
                        }
                        Button("Refresh Link", systemImage: "arrow.clockwise") {
                            Task { await refresh() }
                        }
                        .disabled(refreshing)
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Upload Confirmed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Print", action: onPrint)
                        .bold()
                        .accessibilityIdentifier("confirmS3Print")
                }
            }
        }
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            references = try await manager.refreshUpload(job)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
