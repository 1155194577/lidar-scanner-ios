import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var activeMode: ScanKind?
    @State private var showsSettings = false
    @State private var showsPhotoPrint = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ModeRow(
                        systemImage: ScanKind.room.systemImage,
                        title: "Room Scan",
                        subtitle: "Walls, doors, windows and furniture as a 3D floor model (RoomPlan).",
                        identifier: "roomScanButton"
                    ) { activeMode = .room }
                    ModeRow(
                        systemImage: ScanKind.object.systemImage,
                        title: "Object Scan",
                        subtitle: "A textured, photoreal 3D model of an object you walk around (Object Capture).",
                        identifier: "objectScanButton"
                    ) { activeMode = .object }
                    ModeRow(
                        systemImage: "camera.viewfinder",
                        title: "Photo Print",
                        subtitle: "One photo plus the object's LiDAR-measured height, turned into a printable STL.",
                        identifier: "photoPrintButton"
                    ) { showsPhotoPrint = true }
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
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showsPhotoPrint) {
            if DeviceSupport.photoPrint {
                PhotoPrintView()
            } else {
                UnsupportedView(feature: "Photo Print", requirement: "an iPhone or iPad with a LiDAR sensor")
            }
        }
        .fullScreenCover(item: $activeMode, onDismiss: store.reload) { kind in
            switch kind {
            case .room:
                if DeviceSupport.roomScan {
                    RoomScanView()
                } else {
                    UnsupportedView(feature: "Room Scan", requirement: "an iPhone or iPad with a LiDAR sensor")
                }
            case .object:
                ObjectScanEntryView()
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
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
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
