import SwiftUI

@main
struct LidarScannerApp: App {
    @StateObject private var store: ScanStore

    init() {
        let store = ScanStore()
        LaunchArguments.apply(to: store)
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
