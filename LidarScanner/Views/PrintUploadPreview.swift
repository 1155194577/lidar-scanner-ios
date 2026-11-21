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
    @State private var loadingPhoto = true
    @State private var photo: UIImage?

    private var mainUpload: PrintService.UploadReference? { references["photo"] ?? references["mesh"] }

    var body: some View {
        NavigationStack {
            List {
                if references["photo"] != nil {
                    Section("Uploaded photo") {
                        Group {
                            if let photo {
                                Image(uiImage: photo).resizable().scaledToFit()
                                    .accessibilityLabel("Uploaded photo preview")
                                    .accessibilityIdentifier("uploadedPhotoPreview")
                            } else if loadingPhoto {
                                ProgressView("Loading photo from storage…")
                            } else {
                                Label("Couldn’t load photo from storage.", systemImage: "exclamationmark.icloud")
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
                        .disabled(refreshing || loadingPhoto)
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Upload Confirmed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("closePrintUploadPreview")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Print", action: onPrint)
                        .bold()
                        .accessibilityIdentifier("confirmS3Print")
                }
            }
        }
        .task { await loadPhoto(refreshOnForbidden: true) }
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            references = try await manager.refreshUpload(job)
            error = nil
            await loadPhoto(refreshOnForbidden: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadPhoto(refreshOnForbidden: Bool) async {
        defer { loadingPhoto = false }
        guard let url = references["photo"]?.get_url else { return }
        loadingPhoto = true
        photo = nil
        do {
            func fetch(_ url: URL) async throws -> (Data, URLResponse) {
                try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            }
            var (data, response) = try await fetch(url)
            if refreshOnForbidden, (response as? HTTPURLResponse)?.statusCode == 403 {
                references = try await manager.refreshUpload(job)
                guard let freshURL = references["photo"]?.get_url else { return }
                (data, response) = try await fetch(freshURL)
            }
            guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            photo = UIImage(data: data)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
