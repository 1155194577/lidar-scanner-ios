import QuickLook
import SwiftUI
import UIKit

struct ScansListView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var printJobs: PrintJobManager
    @State private var previewURL: URL?
    @State private var error: (title: String, message: String)?
    @State private var pendingExport: ScanFile?
    @State private var stlFile: STLFile?

    var body: some View {
        Group {
            if store.scans.isEmpty {
                ContentUnavailableView(
                    "No Scans Yet",
                    systemImage: "cube.transparent",
                    description: Text("Room scans, object scans, and photo prints you save appear here.")
                )
                .accessibilityIdentifier("emptyScans")
            } else {
                List {
                    ForEach(ScanKind.allCases) { kind in
                        let scans = store.scans(of: kind)
                        if !scans.isEmpty {
                            Section(kind == .photo ? "Photo Prints" : "\(kind.rawValue) Scans") {
                                ForEach(scans) { scan in
                                    row(for: scan)
                                }
                                .onDelete { offsets in
                                    delete(offsets.map { scans[$0] })
                                }
                            }
                        }
                    }
                }
            }
        }
        .disabled(pendingExport != nil)
        .navigationTitle("My Scans")
        .onAppear(perform: store.reload)
        .navigationDestination(item: $selectedScan) { scan in
            ScanDetailView(scan: scan)
        }
        .safeAreaInset(edge: .bottom) {
            if pendingExport != nil {
                ProgressView("Preparing STL…")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .task(id: pendingExport) {
            if let scan = pendingExport {
                await exportSTL(for: scan)
            }
        }
        .sheet(item: $stlFile) { file in
            STLDocumentPicker(file: file) { stlFile = nil }
        }
        .alert(error?.title ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.message ?? "")
        }
    }

    private func row(for scan: ScanFile) -> some View {
        HStack {
            Button {
                selectedScan = scan
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(scan.name).foregroundStyle(.primary)
                        Text(ByteCountFormatter.string(fromByteCount: scan.byteCount, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: scan.kind.systemImage)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scan-\(scan.name)")

            if scan.kind != .photo {
                Button {
                    startPrint(scan)
                } label: {
                    Image(systemName: "printer")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Print")
                .accessibilityIdentifier("print-\(scan.name)")

                Menu {
                    ShareLink(item: scan.url) {
                        Label("Share USDZ", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        pendingExport = scan
                    } label: {
                        Label("Export as STL", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share or export \(scan.name)")
                .accessibilityIdentifier("share-\(scan.name)")
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                delete([scan])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func exportSTL(for scan: ScanFile) async {
        defer { pendingExport = nil }
        do {
            let file = try await STLExporter.export(scan.url)
            try Task.checkCancellation()
            stlFile = file
        } catch {
            if !Task.isCancelled {
                self.error = ("Couldn't export STL", error.localizedDescription)
            }
        }
    }

    private func startPrint(_ scan: ScanFile) {
        printJobs.start(input: .mesh(scan.url), name: scan.name, kind: "scan")
    }

    private func delete(_ scans: [ScanFile]) {
        do {
            for scan in scans {
                try store.delete(scan)
            }
        } catch {
            self.error = ("Couldn't delete scan", error.localizedDescription)
        }
    }
}

private struct ScanDetailView: View {
    let scan: ScanFile
    @State private var previewURL: URL?

    var body: some View {
        List {
            if scan.kind != .photo {
                Section("Source Scan") {
                    Button {
                        previewURL = scan.url
                    } label: {
                        Label("Preview USDZ", systemImage: "cube")
                    }
                }
            }
            if let stl = scan.printedSTLURL {
                Section("Saved STL") {
                    Label(stl.lastPathComponent, systemImage: "doc")
                        .accessibilityIdentifier("savedSTLFilename")
                    ShareLink(item: stl) {
                        Label("Share STL", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
    }
}

private struct STLDocumentPicker: UIViewControllerRepresentable {
    let file: STLFile
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss()
        }
    }
}
