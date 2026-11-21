import SwiftUI

extension View {
    func printJobBanner(visible: Bool = true) -> some View { modifier(PrintJobBannerModifier(visible: visible)) }
}

private struct PrintJobBannerModifier: ViewModifier {
    let visible: Bool
    @EnvironmentObject private var manager: PrintJobManager
    @State private var selected: PrintedModel?

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
                if visible, !manager.jobs.isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(manager.jobs) { job in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(job.name).font(.subheadline.bold()).lineLimit(1)
                                        Spacer()
                                        if job.isFinished {
                                            Button("Dismiss") { manager.dismiss(job) }
                                        }
                                    }
                                    if let error = job.error {
                                        Text(error).font(.subheadline).foregroundStyle(.red)
                                            .accessibilityIdentifier("printError")
                                        if manager.canRetry(job) {
                                            Button("Retry") { manager.retry(job) }
                                                .accessibilityIdentifier("retryPrintButton")
                                        }
                                    } else if job.result != nil {
                                        Button { selected = manager.printedModel(for: job) } label: {
                                            Label("STL ready — Share", systemImage: "square.and.arrow.up")
                                        }
                                        .accessibilityIdentifier("printResultButton")
                                    } else {
                                        HStack {
                                            Text(job.progress.message)
                                                .accessibilityIdentifier("printStage")
                                            Spacer()
                                            if let fraction = job.progress.progress {
                                                Text(fraction, format: .percent.precision(.fractionLength(0)))
                                                    .accessibilityIdentifier("printPercent")
                                            }
                                        }
                                        .font(.caption)
                                        ProgressView(value: job.progress.progress)
                                            .accessibilityIdentifier("printProgressBar")
                                    }
                                }
                                .padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("printProgress")
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: manager.jobs.count > 1 ? 220 : 130)
                    .accessibilityIdentifier("printJobBanner")
                }
        }
            .sheet(item: $selected) { model in
                PrintResultView(model: model)
            }
    }
}
