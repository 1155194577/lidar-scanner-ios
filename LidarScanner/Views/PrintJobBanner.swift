import SwiftUI

extension View {
    func printJobBanner(visible: Bool = true) -> some View { modifier(PrintJobBannerModifier(visible: visible)) }
}

private struct PrintJobBannerModifier: ViewModifier {
    let visible: Bool
    @EnvironmentObject private var manager: PrintJobManager
    @State private var selected: Presentation?

    private enum Presentation: Identifiable {
        case upload(PrintJob, [String: PrintService.UploadReference])
        case result(PrintedModel)

        var id: String {
            switch self {
            case .upload(let job, _): return "upload-\(job.id)"
            case .result(let model): return "result-\(model.id)"
            }
        }
    }

    private func show(_ job: PrintJob) {
        if let references = manager.uploadConfirmations[job.id] {
            manager.markPresented(job.id)
            selected = .upload(job, references)
        } else if let model = manager.printedModel(for: job) {
            manager.markPresented(job.id)
            selected = .result(model)
        }
    }

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
                                        if job.isFinished || manager.uploadConfirmations[job.id] != nil {
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
                                    } else if manager.uploadConfirmations[job.id] != nil {
                                        Button { show(job) } label: {
                                            Label("Review upload", systemImage: "checkmark.icloud")
                                        }
                                        .accessibilityIdentifier("reviewPrintUpload")
                                    } else if job.result != nil {
                                        Button { show(job) } label: {
                                            Label("STL ready — View", systemImage: "cube")
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
                    .frame(height: manager.jobs.count > 1 ? 180 : 96)
                    .accessibilityIdentifier("printJobBanner")
                }
        }
            .onChange(of: visible && selected == nil ? manager.pendingPresentation : nil, initial: true) { _, id in
                if let id, let job = manager.jobs.first(where: { $0.id == id }) { show(job) }
            }
            .sheet(item: $selected) { presentation in
                switch presentation {
                case .upload(let job, let references):
                    PrintUploadPreview(job: job, references: references) {
                        selected = nil
                        manager.confirmPrint(job)
                    }
                case .result(let model):
                    PrintResultView(model: model)
                }
            }
    }
}
