import SwiftUI
import UIKit

struct ProjectArtworkView: View {
    let url: URL?
    let sourceType: ProjectSourceType
    let width: CGFloat
    let height: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)

                    VStack(spacing: 5) {
                        Image(systemName: sourceIcon)
                            .font(.title3)
                        Text(sourceLabel)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            image = await loadImage()
        }
    }

    private var sourceIcon: String {
        switch sourceType {
        case .epub: "book.closed"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .paste: "doc.on.clipboard"
        }
    }

    private var sourceLabel: String {
        switch sourceType {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .document: "DOC"
        case .paste: "TEXT"
        }
    }

    private func loadImage() async -> UIImage? {
        guard let url else { return nil }

        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value

        guard let data, !data.isEmpty else {
            return nil
        }
        return UIImage(data: data)
    }
}
