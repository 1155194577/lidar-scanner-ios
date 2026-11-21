import QuickLook
import SwiftUI

struct ScansListView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var printingScan: ScanFile?
    @State private var printTask: Task<Void, Never>?
    @State private var printedModel: PrintedModel?
    @State private var printError: String?

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
        .disabled(printingScan != nil)
        .overlay {
            if let scan = printingScan {
                PrintProgressView(scanName: scan.name) { cancelPrint() }
            }
        }
        .navigationTitle("My Scans")
        .onAppear(perform: store.reload)
        .quickLookPreview($previewURL)
        .sheet(item: $printedModel) { model in
            ActivityView(items: [model.url]) { printedModel = nil }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert("Couldn't print scan", isPresented: Binding(get: { printError != nil }, set: { if !$0 { printError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(printError ?? "")
        }
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
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button {
                    startPrint(scan)
                } label: {
                    Image(systemName: "printer")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Print")
                .accessibilityIdentifier("print-\(scan.name)")
                ShareLink(item: scan.url) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("share-\(scan.name)")
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scan-\(scan.name)")
        .swipeActions {
            Button(role: .destructive) {
                delete([scan])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func startPrint(_ scan: ScanFile) {
        printingScan = scan
        printTask = Task {
            do {
                let service = try PrintService()
                let url = try await service.requestSTL(for: .mesh(scan.url), name: scan.name)
                try Task.checkCancellation()
                printedModel = PrintedModel(url: url)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                printError = error.localizedDescription
            }
            printingScan = nil
            printTask = nil
        }
    }

    private func cancelPrint() {
        printTask?.cancel()
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

private struct PrintedModel: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct PrintProgressView: View {
    let scanName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing STL for printing")
                .font(.headline)
            Text(scanName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cancelPrintButton")
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("printProgress")
    }
}
