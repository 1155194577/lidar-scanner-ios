import QuickLook
import SwiftUI

struct ScansListView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var previewURL: URL?
    @State private var errorMessage: String?

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
        .alert("Couldn't delete scan", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(for scan: ScanFile) -> some View {
        Button {
            previewURL = scan.url
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(scan.name).foregroundStyle(.primary)
                        Text(ByteCountFormatter.string(fromByteCount: scan.byteCount, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: scan.kind.systemImage)
                }
                Spacer()
                ShareLink(item: scan.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("share-\(scan.name)")
            }
        }
        .accessibilityIdentifier("scan-\(scan.name)")
        .swipeActions {
            Button(role: .destructive) {
                delete([scan])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func delete(_ scans: [ScanFile]) {
        do {
            for scan in scans {
                try store.delete(scan)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
