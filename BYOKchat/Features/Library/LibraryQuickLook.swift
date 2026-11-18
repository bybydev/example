import QuickLook
import SwiftUI

/// QuickLook preview over materialized temp files. Files must stay alive for
/// the lifetime of the preview, so the coordinator owns them.
struct LibraryQuickLookView: UIViewControllerRepresentable {
  /// (filename with extension, bytes) pairs; extensions drive the preview.
  let files: [(filename: String, data: Data)]
  let onDismiss: () -> Void

  func makeUIViewController(context: Context) -> UINavigationController {
    let controller = DismissibleQuickLookController()
    controller.dataSource = context.coordinator
    controller.onDismiss = onDismiss
    return UINavigationController(rootViewController: controller)
  }

  func updateUIViewController(_ navigation: UINavigationController, context: Context) {
    guard let controller = navigation.viewControllers.first as? DismissibleQuickLookController
    else { return }
    context.coordinator.update(files: files)
    controller.reloadData()
  }

  func makeCoordinator() -> Coordinator { Coordinator(files: files) }

  /// Quick Look adds its own Done button only when presented modally by UIKit;
  /// inside a SwiftUI sheet it is a child controller, so supply one explicitly.
  final class DismissibleQuickLookController: QLPreviewController {
    var onDismiss: (() -> Void)?

    override func viewDidLoad() {
      super.viewDidLoad()
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .done, target: self, action: #selector(done))
    }

    @objc private func done() {
      onDismiss?()
    }
  }

  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    private var urls: [URL] = []

    init(files: [(filename: String, data: Data)]) {
      super.init()
      update(files: files)
    }

    func update(files: [(filename: String, data: Data)]) {
      guard files.map(\.filename) != urls.map(\.lastPathComponent) else { return }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LibraryPreviews", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      urls = files.compactMap { file in
        let url = directory.appendingPathComponent(file.filename)
        do {
          try file.data.write(to: url, options: .atomic)
          return url
        } catch {
          Task { @MainActor in
            BYOKAppAnalytics.reportError("library_preview_failed", component: "library")
          }
          return nil
        }
      }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
      urls.count
    }

    func previewController(
      _ controller: QLPreviewController,
      previewItemAt index: Int
    ) -> QLPreviewItem {
      urls[index] as NSURL
    }
  }
}
