import Foundation
import QuickLook
import SwiftUI

/// Safe temp-file materialization for QuickLook previews and share sheets.
/// Keeps filenames flat (never interpreting `/` as a subdirectory) and isolates
/// each presentation in a disposable directory so temp files are cleaned up.
enum LibraryTempFileSupport {
  struct MaterializedFile: Sendable {
    let directory: URL
    let fileURL: URL
  }

  /// Strips path separators, null bytes, and dot-only names so temp URLs
  /// always land directly inside the target directory while preserving extensions.
  static func safeFilename(_ raw: String, fallbackName: String = "file") -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let sanitized = trimmed
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "\0", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
      return fallbackName
    }
    if sanitized.hasPrefix(".") {
      let stripped = sanitized.drop(while: { $0 == "." })
      if stripped.isEmpty { return fallbackName }
      return "\(fallbackName).\(stripped)"
    }
    return sanitized
  }

  /// Writes a single file into a unique temp directory so the share sheet or
  /// viewer sees its real filename without colliding with other entries.
  static func materializeTempFile(
    directoryPrefix: String,
    filename: String,
    data: Data
  ) throws -> MaterializedFile {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(directoryPrefix, isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let safeName = safeFilename(filename)
    let fileURL = directory.appendingPathComponent(safeName, isDirectory: false)
    try data.write(to: fileURL, options: .atomic)
    return MaterializedFile(directory: directory, fileURL: fileURL)
  }

  static func cleanupDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
  }
}

struct LibraryQuickLookItem: Identifiable, Sendable {
  let id: String
  let filename: String
  let data: Data
}

/// QuickLook preview over materialized temp files. Files must stay alive for
/// the lifetime of the preview, so the coordinator owns and cleans them up.
struct LibraryQuickLookView: UIViewControllerRepresentable {
  /// Files to preview; extensions drive the QuickLook renderer.
  let files: [LibraryQuickLookItem]
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
    controller.onDismiss = onDismiss
    if context.coordinator.update(files: files) {
      controller.reloadData()
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(files: files) }

  /// Quick Look adds its own Done button only when presented modally by UIKit;
  /// inside a SwiftUI sheet it is a child controller, so supply one on the left
  /// to preserve QuickLook's native right-side Share/Markup buttons.
  final class DismissibleQuickLookController: QLPreviewController {
    var onDismiss: (() -> Void)?

    override func viewDidLoad() {
      super.viewDidLoad()
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .done, target: self, action: #selector(done))
    }

    @objc private func done() {
      onDismiss?()
    }
  }

  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    private var urls: [URL] = []
    private var renderedKeys: [String] = []
    private var sessionDirectory: URL?

    init(files: [LibraryQuickLookItem]) {
      super.init()
      _ = update(files: files)
    }

    deinit {
      if let sessionDirectory {
        LibraryTempFileSupport.cleanupDirectory(sessionDirectory)
      }
    }

    @discardableResult
    func update(files: [LibraryQuickLookItem]) -> Bool {
      let keys = files.map { "\($0.id)::\($0.filename)" }
      guard keys != renderedKeys else { return false }

      if let previous = sessionDirectory {
        LibraryTempFileSupport.cleanupDirectory(previous)
        sessionDirectory = nil
      }

      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LibraryPreviews", isDirectory: true)
        .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        Task { @MainActor in
          BYOKAppAnalytics.reportError("library_preview_failed", component: "library")
        }
        urls = []
        renderedKeys = keys
        return true
      }
      sessionDirectory = directory

      var usedNames: Set<String> = []
      urls = files.compactMap { file in
        let uniqueName = Self.uniqueFilename(
          for: LibraryTempFileSupport.safeFilename(file.filename),
          used: &usedNames
        )
        let url = directory.appendingPathComponent(uniqueName, isDirectory: false)
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
      renderedKeys = keys
      return true
    }

    private static func uniqueFilename(for candidate: String, used: inout Set<String>) -> String {
      if used.insert(candidate.lowercased()).inserted {
        return candidate
      }
      let nsName = candidate as NSString
      let ext = nsName.pathExtension
      let stem = ext.isEmpty ? candidate : nsName.deletingPathExtension
      var index = 2
      while true {
        let next = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
        if used.insert(next.lowercased()).inserted {
          return next
        }
        index += 1
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
