import BYOKchatProviderCore
import SwiftUI
import UIKit

/// Scroll-view-backed zoomable image with pinch zoom, double-tap zoom, and
/// proper contentLayoutGuide pan bounds.
struct ZoomableImageView: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.delegate = context.coordinator
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 6
    scrollView.bouncesZoom = true
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.backgroundColor = .clear

    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.isUserInteractionEnabled = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])

    let doubleTap = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleDoubleTap(_:))
    )
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    context.coordinator.scrollView = scrollView
    context.coordinator.imageView = imageView
    return scrollView
  }

  func updateUIView(_ scrollView: UIScrollView, context: Context) {
    if context.coordinator.imageView?.image !== image {
      context.coordinator.imageView?.image = image
      scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor
  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var scrollView: UIScrollView?
    weak var imageView: UIImageView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      imageView
    }

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard let scrollView, let imageView else { return }
      if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        return
      }
      let targetScale: CGFloat = min(2.5, scrollView.maximumZoomScale)
      let tapPoint = recognizer.location(in: imageView)
      let width = scrollView.bounds.width / targetScale
      let height = scrollView.bounds.height / targetScale
      let zoomRect = CGRect(
        x: tapPoint.x - width / 2,
        y: tapPoint.y - height / 2,
        width: width,
        height: height
      )
      scrollView.zoom(to: zoomRect, animated: true)
    }
  }
}

/// Full-screen viewer for a saved library image.
struct LibraryImageViewerView: View {
  let entry: LibraryEntry
  let image: UIImage
  let shareFileURL: URL?
  var onSaveToPhotos: (() async throws -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var isSavingToPhotos = false
  @State private var didSaveToPhotos = false
  @State private var saveErrorMessage: String?

  var body: some View {
    NavigationStack {
      ZStack(alignment: .bottom) {
        ZoomableImageView(image: image)
          .ignoresSafeArea(edges: .bottom)

        if didSaveToPhotos {
          Label("Saved to Photos", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.2), value: didSaveToPhotos)
      .background(Color.black.ignoresSafeArea())
      .navigationTitle(entry.filename)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", systemImage: "xmark") {
            dismiss()
          }
          .labelStyle(.iconOnly)
        }
        ToolbarItemGroup(placement: .primaryAction) {
          if let onSaveToPhotos {
            if isSavingToPhotos {
              ProgressView()
                .controlSize(.small)
                .tint(.white)
                .accessibilityLabel("Saving to Photos")
            } else {
              Button(
                "Save to Photos",
                systemImage: didSaveToPhotos ? "checkmark" : "square.and.arrow.down"
              ) {
                Task { await saveToPhotos(using: onSaveToPhotos) }
              }
              .labelStyle(.iconOnly)
              .accessibilityLabel("Save to Photos")
            }
          }

          if let shareFileURL {
            ShareLink(
              item: shareFileURL,
              preview: SharePreview(entry.filename, image: Image(uiImage: image))
            ) {
              Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
          }
        }
      }
      .alert(
        "Could Not Save Image",
        isPresented: Binding(
          get: { saveErrorMessage != nil },
          set: { if !$0 { saveErrorMessage = nil } }
        )
      ) {
        Button("OK") { saveErrorMessage = nil }
      } message: {
        Text(saveErrorMessage ?? "Unknown error")
      }
      .preferredColorScheme(.dark)
    }
  }

  private func saveToPhotos(using action: () async throws -> Void) async {
    guard !isSavingToPhotos else { return }
    isSavingToPhotos = true
    do {
      try await action()
      isSavingToPhotos = false
      didSaveToPhotos = true
      try? await Task.sleep(for: .seconds(1.8))
      if !Task.isCancelled {
        didSaveToPhotos = false
      }
    } catch {
      isSavingToPhotos = false
      saveErrorMessage = error.localizedDescription
    }
  }
}
