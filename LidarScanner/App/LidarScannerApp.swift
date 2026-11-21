import SwiftUI

@main
struct LidarScannerApp: App {
    @UIApplicationDelegateAdaptor(PrintAppDelegate.self) private var appDelegate
    @StateObject private var store: ScanStore
    @StateObject private var printJobs = PrintJobManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = ScanStore()
        LaunchArguments.apply(to: store)
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(printJobs)
                .onChange(of: scenePhase, initial: true) { _, phase in printJobs.sceneChanged(phase) }
        }
    }
}
