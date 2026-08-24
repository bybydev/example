import QuickLook
import SwiftUI

/// QuickLook preview over materialized temp files. Files must stay alive for
/// the lifetime of the preview, so the coordinator owns them.
struct LibraryQuickLookView: UIViewControllerRepresentable {
  /// (filename with extension, bytes) pairs; extensions drive the preview.
  let files: [(filename: String, data: Data)]

  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: QLPreviewController, context: Context) {
    context.coordinator.update(files: files)
    controller.reloadData()
  }

  func makeCoordinator() -> Coordinator { Coordinator(files: files) }

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
