import BYOKchatProviderCore
import SwiftUI
import UIKit

/// Scroll-view-backed zoomable image. UIScrollView gives the expected
/// pinch/double-tap/bounce behavior without hand-rolled gesture state.
struct ZoomableImageView: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.delegate = context.coordinator
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 6
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.backgroundColor = .clear

    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])
    context.coordinator.imageView = imageView
    return scrollView
  }

  func updateUIView(_ scrollView: UIScrollView, context: Context) {
    if context.coordinator.imageView?.image !== image {
      context.coordinator.imageView?.image = image
      scrollView.zoomScale = 1
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    var imageView: UIImageView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      imageView
    }

    func scrollViewDidEndZooming(
      _ scrollView: UIScrollView,
      with view: UIView?,
      atScale scale: CGFloat
    ) {
      // Keep the default post-zoom pan bounds behavior.
    }
  }
}

/// Full-screen viewer for a saved library image.
struct LibraryImageViewerView: View {
  let entry: LibraryEntry
  let image: UIImage
  var shareData: () -> Data?

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZoomableImageView(image: image)
        .ignoresSafeArea(edges: .bottom)
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
          ToolbarItem(placement: .primaryAction) {
            if let data = shareData() {
              ShareLink(item: data, preview: SharePreview(entry.filename)) {
                Image(systemName: "square.and.arrow.up")
              }
              .labelStyle(.iconOnly)
            }
          }
        }
        .preferredColorScheme(.dark)
    }
  }
}
