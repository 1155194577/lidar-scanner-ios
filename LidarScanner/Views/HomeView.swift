import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var activeMode: ScanKind?
    @State private var showsSettings = false

    var body: some View {
        GeometryReader { geometry in
            home(compact: geometry.size.height < 700)
        }
    }

    private func home(compact: Bool) -> some View {
        NavigationStack {
            List {
                Section {
                    ModeRow(
                        systemImage: ScanKind.room.systemImage,
                        title: "Room Scan",
                        subtitle: "Walls, doors, windows and furniture as a 3D floor model (RoomPlan).",
                        identifier: "roomScanButton", compact: compact
                    ) { activeMode = .room }
                    ModeRow(
                        systemImage: ScanKind.object.systemImage,
                        title: "Object Scan",
                        subtitle: "A textured, photoreal 3D model of an object you walk around (Object Capture).",
                        identifier: "objectScanButton", compact: compact
                    ) { activeMode = .object }
                    ModeRow(
                        systemImage: "camera.viewfinder",
                        title: "Photo Print",
                        subtitle: "One photo plus the object's LiDAR-measured height, turned into a printable STL.",
                        identifier: "photoPrintButton", compact: compact
                    ) { activeMode = .photo }
                    ModeRow(
                        systemImage: ScanKind.face.systemImage,
                        title: "Face Scan",
                        subtitle: "Your face from the front TrueDepth camera, made into a printable bust STL.",
                        identifier: "faceScanButton", compact: compact
                    ) { activeMode = .face }
                } header: {
                    Text("New Scan")
                } footer: {
                    if !DeviceSupport.hasLiDAR {
                        Text("This device has no LiDAR sensor. Scanning needs an iPhone or iPad Pro with LiDAR.")
                            .accessibilityIdentifier("noLidarFooter")
                    }
                }

                Section("Library") {
                    NavigationLink {
                        ScansListView()
                    } label: {
                        LabeledContent {
                            Text("\(store.scans.count)")
                                .accessibilityIdentifier("scanCount")
                        } label: {
                            Label("My Scans", systemImage: "square.stack.3d.up")
                        }
                    }
                    .accessibilityIdentifier("myScansLink")
                }
            }
            .navigationTitle("LiDAR Scanner")
            .navigationBarTitleDisplayMode(compact ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                }
            }
        }
        .printJobBanner(visible: activeMode == nil && !showsSettings)
        .sheet(isPresented: $showsSettings) { SettingsView().printJobBanner() }
        .fullScreenCover(item: $activeMode, onDismiss: store.reload) { kind in
            ScanModeView(kind: kind)
                .printJobBanner()
        }
    }
}

private struct ScanModeView: View {
    let kind: ScanKind

    var body: some View {
        switch kind {
        case .room:
            if DeviceSupport.roomScan {
                RoomScanView()
            } else {
                UnsupportedView(feature: "Room Scan", requirement: "an iPhone or iPad with a LiDAR sensor")
            }
        case .object:
            ObjectScanEntryView()
        case .photo:
            if DeviceSupport.photoPrint {
                PhotoPrintView()
            } else {
                UnsupportedView(feature: "Photo Print", requirement: "an iPhone or iPad with a LiDAR sensor")
            }
        case .face:
            if DeviceSupport.faceScan {
                FaceScanView()
            } else {
                UnsupportedView(feature: "Face Scan", requirement: "an iPhone or iPad with Face ID (TrueDepth camera)")
            }
        }
    }
}

extension ScanKind: Identifiable {
    var id: String { rawValue }
}

private struct ModeRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let identifier: String
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(compact ? 2 : nil)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.vertical, compact ? 2 : 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

struct UnsupportedView: View {
    @Environment(\.dismiss) private var dismiss
    let feature: String
    let requirement: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("\(feature) Unavailable", systemImage: "sensor.tag.radiowaves.forward")
            } description: {
                Text("\(feature) needs \(requirement). Open the app on an iPhone Pro to scan.")
            }
            .accessibilityIdentifier("unsupportedView")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("closeButton")
                }
            }
        }
    }
}
