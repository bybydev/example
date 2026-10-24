import SwiftUI
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct ClipStrip: View {
    let session: EditorSession
    let onRename: (ProjectClip) -> Void
    var body: some View {
        if let document = session.document {
            let current = session.currentClip
            VStack(alignment: .leading, spacing: 8) {
                if let current, let index = document.orderedClips.firstIndex(where: { $0.id == current.id }) {
                    Text("Clip \(index + 1) of \(document.clips.count) · \(document.clipName(current))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(document.orderedClips.enumerated()), id: \.element.id) { index, clip in
                            clipCard(clip, index: index, current: current, document: document)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
    }

    private func clipCard(_ clip: ProjectClip, index: Int, current: ProjectClip?, document: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { session.seekToClip(clip.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    ClipThumbnail(projectID: document.id, clip: clip,
                        source: document.assets.first { $0.id == clip.sourceAssetID })
                    Text("\(index + 1) · \(EditorTime.display(clip.timelineInterval.durationTime))")
                        .font(.caption2).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .disabled(OutputTimeline(document).outputInterval(clip.timelineInterval) == nil)
                .accessibilityLabel("Clip \(index + 1), \(document.clipName(clip))")
                .accessibilityAddTraits(current?.id == clip.id ? .isSelected : [])
            HStack(spacing: 2) {
                Text(document.clipName(clip)).font(.caption2).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("Rename clip", systemImage: "pencil") { onRename(clip) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Actions for clip \(index + 1), \(document.clipName(clip))")
            }
        }.padding(6).frame(width: 136)
            .background(current?.id == clip.id ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10))
    }
}

extension MediaInterval {
    var durationTime: MediaTime { (try? MediaTime(validating: duration)) ?? .zero }
}

struct ClipThumbnail: View {
    let projectID: UUID
    let clip: ProjectClip
    let source: SourceAsset?
    @State private var data: Data?
    var body: some View {
        MediaThumbnail(data: data, audio: source?.kind == .audio)
            .task(id: "\(projectID)-\(clip.id)-\(source?.sha256 ?? "")") {
                data = await ClipThumbnailStore.shared.image(projectID: projectID, clip: clip, source: source)
            }
    }
}

/// Small, bounded derived cache. Each request yields at most a 180px thumbnail.
actor ClipThumbnailStore {
    static let shared = ClipThumbnailStore()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var active: Task<Void, Never>?
    private var activeID = UUID()

    func image(projectID: UUID, clip: ProjectClip, source: SourceAsset?) async -> Data? {
        guard let source, source.kind == .video else { return nil }
        let key = "\(projectID)-\(clip.id)-\(source.sha256)"
        if let data = cache[key] { return data }
        guard !Task.isCancelled else { return nil }
        let previous = active
        let token = UUID()
        let task = Task {
            if let previous { await previous.value }
            if self.cache[key] == nil { await self.generate(projectID: projectID, clip: clip, key: key) }
        }
        active = task; activeID = token
        await task.value
        if activeID == token { active = nil }
        return cache[key]
    }
    private func generate(projectID: UUID, clip: ProjectClip, key: String) async {
        do {
            let url = try await ProjectRepository.shared.sourceURL(projectID: projectID, assetID: clip.sourceAssetID)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 180)
            let sample = CMTimeAdd(clip.sourceInterval.start.cmTime, CMTimeMinimum(CMTime(value: 1, timescale: 2),
                CMTimeMultiplyByFloat64(clip.sourceInterval.duration, multiplier: 0.5)))
            let (image, _) = try await generator.image(at: sample)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(destination), data.length <= 262_144 else { return }
            cache[key] = data as Data; order.append(key)
            while order.count > 32 { cache.removeValue(forKey: order.removeFirst()) }
        } catch { /* Derived artwork is optional; the media error remains in the editor. */ }
    }
}
