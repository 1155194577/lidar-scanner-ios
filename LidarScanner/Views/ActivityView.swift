import SwiftUI
import UIKit

/// The system share sheet, presented programmatically (ShareLink needs a tap on itself).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
