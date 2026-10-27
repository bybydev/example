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

/// Compact project identity; the navigation link and action menu are siblings.
struct ProjectRow: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let project: ProjectSummary
    let status: ProjectCardStatus
    let cacheGeneration: Int
    var isFavorite = false
    var isCompact = false
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if !typeSize.isAccessibilitySize { artwork }
            VStack(alignment: .leading, spacing: isCompact ? 5 : 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(project.title).font(.headline)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .foregroundStyle(.primary)
                    if isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(theme.accentColor)
                            .accessibilityLabel("Favorite")
                    }
                }
                HStack(spacing: 4) {
                    Text("\(project.mediaKind == .audio ? "Audio" : "Video") · \(duration)")
                    if isCompact {
                        Text("·")
                        updatedDate
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Label(status.title, systemImage: status.icon)
                    .font(.caption).foregroundStyle(theme.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                if status.isWorking, let progress = status.progress {
                    ProgressView(value: progress).accessibilityLabel("Transcription progress")
                }
                if !isCompact { updatedDate.font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: isCompact ? 64 : 84, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var updatedDate: some View {
        Text(project.updatedAt, format: .dateTime.month(.abbreviated).day())
            .accessibilityLabel("Updated \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))")
    }

    private var artworkSize: CGSize {
        let side: CGFloat = isCompact ? 64 : 80
        return CGSize(width: side, height: side)
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: isCompact ? 10 : 14).fill(Color(uiColor: .secondarySystemFill))
            .frame(width: artworkSize.width, height: artworkSize.height)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .frame(width: artworkSize.width, height: artworkSize.height).clipped()
                } else {
                    Image(systemName: project.mediaKind == .audio ? "waveform" : "film")
                        .font(isCompact ? .title3 : .title2).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isCompact ? 10 : 14))
            .accessibilityHidden(true)
            .task(id: "\(project.thumbnailURL?.path ?? "")-\(cacheGeneration)") {
                thumbnail = nil
                let data = await ProjectThumbnailData.shared.load(project.thumbnailURL)
                guard !Task.isCancelled else { return }
                thumbnail = data.flatMap { UIImage(data: $0) }
            }
    }

    private var duration: String {
        let seconds = CMTimeGetSeconds(project.duration.cmTime)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

actor ProjectThumbnailData {
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


