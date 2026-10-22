import SwiftUI
import UIKit

/// Copy a completed file through a provider without reading the movie into Data.
struct ExportFilesPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: @MainActor (Bool) -> Void
        init(completion: @escaping @MainActor (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(!urls.isEmpty)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}

struct ExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor (Bool, String?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // SwiftUI owns presentation. Give UIKit an anchor if it chooses a popover.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        let callback = completion
        controller.completionWithItemsHandler = { _, completed, _, error in
            let message = error?.localizedDescription
            Task { @MainActor in callback(completed, message) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
