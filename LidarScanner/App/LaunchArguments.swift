import Foundation

/// Launch arguments used by the UI tests to put the app in a known state.
enum LaunchArguments {
    static let resetScans = "-UITestResetScans"
    static let seedSampleScans = "-UITestSeedSampleScans"
    static let forceUnsupported = "-UITestForceUnsupported"

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
            store.seedSamples(contents: fixture ?? Data("sample".utf8))
        }
    }
}
