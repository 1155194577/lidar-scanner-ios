import Foundation

/// Launch arguments used by the UI tests to put the app in a known state.
enum LaunchArguments {
    static let resetScans = "-UITestResetScans"
    static let seedSampleScans = "-UITestSeedSampleScans"
    static let forceUnsupported = "-UITestForceUnsupported"
    static let fakePhotoCapture = "-UITestFakePhotoCapture"
    static let fakeFaceCapture = "-UITestFakeFaceCapture"
    /// With turn-your-head capture on, the fake head stays facing front after the first view, so only Print Now finishes.
    static let fakeFaceNoTurn = "-UITestFakeFaceNoTurn"
    /// Object Scan skips capture and reconstruction and "builds" the base64 USDZ in `UITestObjectModelFixture`; a rescan builds `UITestObjectRescanFixture`.
    static let fakeObjectCapture = "-UITestFakeObjectCapture"
    /// Pass as `-UITestFakePitch <degrees>`; launch arguments in this form land in UserDefaults.
    static let fakePitchKey = "UITestFakePitch"

    static func contains(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    @MainActor
    static func apply(to store: ScanStore) {
        if contains(resetScans) {
            store.deleteAll()
        }
        if contains(seedSampleScans) {
            let fixture = ProcessInfo.processInfo.environment["UITestUSDZFixture"]
                .flatMap { Data(base64Encoded: $0) }
            store.seedSamples(contents: fixture)
        }
    }
}
