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
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if !typeSize.isAccessibilitySize { artwork }
            VStack(alignment: .leading, spacing: 7) {
                Text(project.title).font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .foregroundStyle(.primary)
                Text("\(project.mediaKind == .audio ? "Audio" : "Video") · \(duration)")
                    .font(.caption).foregroundStyle(.secondary)
                Label(status.title, systemImage: status.icon)
                    .font(.caption).foregroundStyle(theme.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                if status.isWorking, let progress = status.progress {
                    ProgressView(value: progress).accessibilityLabel("Transcription progress")
                }
                Text(project.updatedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Updated \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: 14).fill(theme.accentColor.opacity(0.12))
            .frame(width: 72, height: 90)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                        .frame(width: 72, height: 90).clipped()
                } else {
                    Image(systemName: project.mediaKind == .audio ? "waveform" : "film")
                        .font(.title2).foregroundStyle(theme.accentColor)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
