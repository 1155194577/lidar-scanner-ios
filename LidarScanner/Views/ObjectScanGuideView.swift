import SwiftUI

struct ObjectScanEntryView: View {
    @State private var started = false

    var body: some View {
        if started {
            if DeviceSupport.objectScan {
                ObjectScanView()
            } else {
                UnsupportedView(feature: "Object Scan", requirement: "an iPhone or iPad with a LiDAR sensor and an A14 chip or newer")
            }
        } else {
            ObjectScanGuideView { started = true }
        }
    }
}

struct ObjectScanGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    var start: (() -> Void)? = nil

    private let steps: [(String, String, String)] = [
        ("shippingbox", "Pick the right object", "Choose a fist-size to chair-size object that is matte and textured. Avoid shiny, transparent, very thin or plain single-colour objects."),
        ("sun.max", "Set up", "Use bright, even, indirect light with no harsh shadows. Put the object on a plain surface that contrasts with it. Leave room to walk all the way round, with nothing else nearby."),
        ("viewfinder", "Fit the box", "Point at the object and tap Continue. Drag the box handles so it fits snugly. Then tap Start Capture."),
        ("figure.walk", "Capture", "Hold the phone about 30–60 cm away. Walk slowly in a full circle, keeping the object centred. The ring around the object fills in as you go. Don't move the object during a pass."),
        ("arrow.triangle.2.circlepath", "Do 3 passes", "Pass 1: chest height. Pass 2: lower, near object height. Pass 3: flip the object onto its side if it is rigid, or scan from high above. Then tap Finish. The model builds on the phone in a few minutes. Keep the app open and the phone plugged in.")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ScrollView {
                    VStack(spacing: 24) {
                        Image(systemName: steps[step].0)
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Step \(step + 1) of \(steps.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("guideStepLabel")
                        Text(steps[step].1).font(.title.bold())
                        Text(steps[step].2).font(.title3)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                }
                HStack {
                    if step > 0 {
                        Button("Back") { step -= 1 }
                            .accessibilityIdentifier("guideBackButton")
                    }
                    Spacer()
                    if step < steps.count - 1 {
                        Button("Next") { step += 1 }
                            .accessibilityIdentifier("guideNextButton")
                    } else if let start {
                        Button("Start Scanning", action: start)
                            .accessibilityIdentifier("guideStartButton")
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .navigationTitle("How to scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(start == nil ? "Done" : "Close") { dismiss() }
                        .accessibilityIdentifier("guideCloseButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    if let start {
                        Button("Skip", action: start)
                            .accessibilityIdentifier("guideSkipButton")
                    }
                }
            }
        }
        .accessibilityIdentifier("objectScanGuide")
    }
}
