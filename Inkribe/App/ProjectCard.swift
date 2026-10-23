import AppFoundation
import CoreMedia
import Foundation
import SwiftUI
import UIKit

struct ProjectCardStatus {
    let title: String
    let icon: String
    var progress: Double? = nil
    var isWorking = false
    var needsAttention = false
}

/// Card imagery loads once per URL/cache generation, never from the view body.
struct ProjectCard: View {
    @Environment(\.appFoundationTheme) private var theme
    let project: ProjectSummary
    let status: ProjectCardStatus
    let cacheGeneration: Int
    @State private var thumbnail: UIImage?

    private struct ImageKey: Hashable {
        let url: URL?
        let generation: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            theme.accentColor.opacity(0.12)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                        } else {
                            Image(systemName: project.mediaKind == .audio ? "waveform" : "film")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(theme.accentColor)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(duration)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .task(id: ImageKey(url: project.thumbnailURL, generation: cacheGeneration)) {
                    thumbnail = nil
                    let data = await ProjectThumbnailData.shared.load(project.thumbnailURL)
                    guard !Task.isCancelled else { return }
                    thumbnail = data.flatMap { UIImage(data: $0) }
                }
            Text(project.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Label(status.title, systemImage: status.icon)
                .font(.caption)
                .foregroundStyle(status.needsAttention ? .orange : theme.accentColor)
                .lineLimit(2)
            if status.isWorking {
                if let progress = status.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(project.updatedAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var duration: String {
        let seconds = CMTimeGetSeconds(project.duration.cmTime)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private actor ProjectThumbnailData {
    static let shared = ProjectThumbnailData()

    func load(_ url: URL?) -> Data? {
        guard let url, url.isFileURL,
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes <= 2 * 1024 * 1024 else { return nil }
        // A cache file is optional; missing/invalid data keeps the placeholder.
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 2 * 1024 * 1024 + 1),
              data.count <= 2 * 1024 * 1024 else { return nil }
        return data
    }
}
