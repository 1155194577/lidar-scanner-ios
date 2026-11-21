import QuickLook
import SwiftUI

struct ScansListView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var previewURL: URL?
    @State private var error: (title: String, message: String)?
    @State private var pendingExport: ScanFile?
    @State private var stlFile: STLFile?
    @State private var showsExporter = false

    var body: some View {
        Group {
            if store.scans.isEmpty {
                ContentUnavailableView(
                    "No Scans Yet",
                    systemImage: "cube.transparent",
                    description: Text("Room and object scans you save appear here as USDZ files.")
                )
                .accessibilityIdentifier("emptyScans")
            } else {
                List {
                    ForEach(ScanKind.allCases) { kind in
                        let scans = store.scans(of: kind)
                        if !scans.isEmpty {
                            Section("\(kind.rawValue) Scans") {
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
        .navigationTitle("My Scans")
        .onAppear(perform: store.reload)
        .quickLookPreview($previewURL)
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
        .fileExporter(isPresented: $showsExporter, item: stlFile, contentTypes: [STLFile.contentType],
                      defaultFilename: stlFile?.url.lastPathComponent) { result in
            stlFile = nil
            if case .failure(let failure) = result {
                error = ("Couldn't export STL", failure.localizedDescription)
            }
        } onCancellation: {
            stlFile = nil
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
                previewURL = scan.url
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

            Menu {
                ShareLink(item: scan.url) {
                    Label("Share USDZ", systemImage: "square.and.arrow.up")
                }
                Button {
                    pendingExport = scan
                } label: {
                    Label("Export as STL", systemImage: "square.and.arrow.down")
                }
                .disabled(pendingExport != nil)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share or export \(scan.name)")
            .accessibilityIdentifier("share-\(scan.name)")
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
            showsExporter = true
        } catch {
            if !Task.isCancelled {
                self.error = ("Couldn't export STL", error.localizedDescription)
            }
        }
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
