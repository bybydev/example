#if DEBUG
import AppFoundation
import SwiftUI

enum InkribeScreenshotFeature: String, CaseIterable {
    case captioning, styles, editing, music, export

    var title: String {
        switch self {
        case .captioning: "Captions in seconds"
        case .styles: "A style for every word"
        case .editing: "Every word, editable"
        case .music: "Give it a soundtrack"
        case .export: "Ready for anywhere"
        }
    }

    var eyebrow: String {
        switch self {
        case .captioning: "On-device captions"
        case .styles: "10 caption styles"
        case .editing: "Word-level editing"
        case .music: "Music & audio"
        case .export: "Export & share"
        }
    }

    var headline: (String, String) {
        switch self {
        case .captioning: ("Captions in", "seconds.")
        case .styles: ("A style for", "every word.")
        case .editing: ("Every word,", "editable.")
        case .music: ("Give it a", "soundtrack.")
        case .export: ("Ready for", "anywhere.")
        }
    }

    var subtitle: String {
        switch self {
        case .captioning: "Transcribed on your iPhone.\nNo cloud required."
        case .styles: "10 presets, plus fonts,\ncolors, and animation."
        case .editing: "Fix a typo, split a line,\nor nudge the timing."
        case .music: "Add music, loop it to fit,\nand fade it in."
        case .export: "Save a captioned MP4\nor a clean SRT file."
        }
    }
}

/// A fixed 440-point artboard scales as a unit to either catalog preset.
/// Everything here is a synchronous composition: no repository, player,
/// session, `.task` or animation is created during preview or export.
@MainActor
struct InkribeScreenshotScene: View {
    let feature: InkribeScreenshotFeature
    let theme: AppTheme
    let backgroundStyle: ScreenshotBackgroundStyle
    let backgroundIntensity: Double

    private var palette: InkribeScreenshotPalette { .init(theme: theme) }

    var body: some View {
        GeometryReader { proxy in
            let scale = max(proxy.size.width, 1) / 440
            ZStack(alignment: .topLeading) {
                ScreenshotBackground(
                    style: backgroundStyle,
                    colors: [
                        palette.background,
                        theme.appearance.gradientStart.color,
                        theme.appearance.gradientEnd.color,
                    ],
                    intensity: backgroundIntensity
                ) {
                    LinearGradient(
                        stops: [
                            .init(color: palette.background.opacity(0.72), location: 0),
                            .init(color: palette.background.opacity(0.28), location: 0.45),
                            .init(color: .clear, location: 0.8),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.background)

                VStack(alignment: .leading, spacing: 0) {
                    InkribeScreenshotPosterHeader(
                        eyebrow: feature.eyebrow,
                        headline: feature.headline,
                        subtitle: feature.subtitle,
                        palette: palette
                    )

                    InkribeScreenshotPhone(palette: palette) {
                        screen
                    }
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity)

                    Spacer(minLength: 0)
                }
                .padding(.top, 38)
                .padding(.horizontal, 34)
                .frame(width: 440, height: proxy.size.height / scale, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var screen: some View {
        switch feature {
        case .captioning: InkribeScreenshotCaptionsScreen(palette: palette)
        case .styles: InkribeScreenshotStylesScreen(palette: palette)
        case .editing: InkribeScreenshotEditingScreen(palette: palette)
        case .music: InkribeScreenshotMusicScreen(palette: palette)
        case .export: InkribeScreenshotExportScreen(palette: palette)
        }
    }
}

// MARK: - Captions

@MainActor
private struct InkribeScreenshotCaptionsScreen: View {
    let palette: InkribeScreenshotPalette

    private let captionLines: [(time: String, text: String)] = [
        ("00:00.000", "A new day brings new possibilities."),
        ("00:04.000", "Take a moment to enjoy the view."),
        ("00:08.000", "The best stories start with you."),
        ("00:12.000", "Slow down and look around."),
        ("00:16.000", "Make time for what matters."),
        ("00:20.000", "Every walk is a fresh start."),
        ("00:24.000", "The little things add up."),
        ("00:28.000", "Keep going."),
    ]

    var body: some View {
        InkribeScreenshotAppScreen(
            palette: palette,
            title: "Captions",
            trailing: "Done"
        ) {
            VStack(spacing: 0) {
                InkribeScreenshotSampleFrame(
                    style: CaptionPreset.basic.resolved,
                    seconds: 7.7
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 13)
                .padding(.top, 6)

                playbackControls

                HStack(spacing: 5) {
                    Text("Captions")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text("8")
                        .font(.system(size: 9.5))
                        .foregroundStyle(palette.secondary)
                    Spacer(minLength: 4)
                    Label("Re-transcribe", systemImage: "arrow.clockwise")
                        .foregroundStyle(palette.accent)
                    Label("Add caption", systemImage: "plus")
                        .foregroundStyle(palette.accent)
                }
                .font(.system(size: 9))
                .padding(.horizontal, 12)
                .frame(height: 34)

                VStack(spacing: 6) {
                    ForEach(Array(captionLines.enumerated()), id: \.offset) { item in
                        captionRow(
                            time: item.element.time,
                            text: item.element.text,
                            selected: item.offset == 1
                        )
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 0) {
            Image(systemName: "play.fill")
                .font(.system(size: 13))
                .foregroundStyle(palette.text)
                .frame(width: 32, height: 34)
            Spacer(minLength: 6)
            Text("0:07 / 0:32")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(palette.secondary)
            Spacer(minLength: 6)
            Image(systemName: "arrow.uturn.backward")
                .foregroundStyle(palette.text)
                .frame(width: 28, height: 34)
            Image(systemName: "arrow.uturn.forward")
                .foregroundStyle(palette.secondary)
                .frame(width: 28, height: 34)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func captionRow(time: String, text: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if selected {
                HStack(spacing: 4) {
                    Label("Edit caption", systemImage: "pencil")
                        .foregroundStyle(palette.accent)
                    Spacer(minLength: 4)
                    Text("00:04.000–00:08.000")
                        .monospacedDigit()
                        .foregroundStyle(palette.secondary)
                }
                .font(.system(size: 8.5))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !selected {
                    Text(time)
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(palette.secondary)
                }
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
            }
            .frame(minHeight: 26)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, selected ? 7 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? palette.accent.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(palette.accent)
                    .frame(width: 2.5)
                    .padding(.vertical, 5)
            }
        }
    }
}

// MARK: - Styles

@MainActor
private struct InkribeScreenshotStylesScreen: View {
    let palette: InkribeScreenshotPalette
    private let presets = CaptionPreset.catalog

    var body: some View {
        InkribeScreenshotAppScreen(
            palette: palette,
            title: "Templates",
            leading: .back("Style")
        ) {
            VStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            if index < presets.count {
                                let preset = presets[index]
                                InkribeScreenshotTemplateTile(
                                    preset: preset,
                                    palette: palette,
                                    selected: preset.id == "karaoke"
                                )
                            } else {
                                Color.clear.frame(width: 90, height: 90)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Editing

@MainActor
private struct InkribeScreenshotEditingScreen: View {
    let palette: InkribeScreenshotPalette

    private let words = ["Take", "a", "moment", "to", "enjoy", "the", "view."]

    var body: some View {
        InkribeScreenshotAppScreen(
            palette: palette,
            title: "Edit caption",
            leading: .back("Captions"),
            trailing: "Done"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                editorCard
                wordsSection
                timingPanel(
                    title: "Caption timing",
                    detail: "Applying caption timing scales its word intervals as a manual correction.",
                    start: "4.000",
                    end: "8.000"
                )
                timingPanel(
                    title: "Selected word timing",
                    detail: "Extending a word expands the caption if needed.",
                    start: "4.514",
                    end: "5.102"
                )

                HStack(spacing: 8) {
                    actionButton("Split before word", symbol: "scissors")
                    actionButton("Merge next", symbol: "arrow.triangle.merge")
                }

                Text("Tap Done to return to the timeline and play back your changes.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(palette.secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Label("Editing caption", systemImage: "pencil")
                    .foregroundStyle(palette.accent)
                Spacer(minLength: 4)
                Text("00:04.000–00:08.000")
                    .monospacedDigit()
                    .foregroundStyle(palette.secondary)
            }
            .font(.system(size: 8.5))

            Text("Take a moment to enjoy the view.")
                .font(.system(size: 12))
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

            Label("Phrase timing", systemImage: "text.alignleft")
                .font(.system(size: 8.5))
                .foregroundStyle(palette.secondary)
        }
        .padding(9)
        .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Words & phrases")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.text)
            Text("Select a word to correct it. Clear its text to hide it; timing stays unchanged.")
                .font(.system(size: 8))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                ForEach(Array(words.enumerated()), id: \.offset) { item in
                    wordChip(item.element, selected: item.element == "moment")
                }
            }
        }
    }

    private func wordChip(_ word: String, selected: Bool) -> some View {
        Text(word)
            .font(.system(size: 9))
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 27)
            .background(
                selected ? palette.accent.opacity(0.25) : palette.surface,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }

    private func timingPanel(
        title: String,
        detail: String,
        start: String,
        end: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(palette.secondary)
            }
            Text(detail)
                .font(.system(size: 8))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                timingField("Start (s)", value: start)
                timingField("End (s)", value: end)
            }

            HStack {
                Spacer(minLength: 0)
                Text("Apply timing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(9)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func timingField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(palette.secondary)
            Text(value)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .background(palette.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 0.6)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionButton(_ title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(title).font(.system(size: 9.5))
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.6)
        }
    }
}

// MARK: - Music

@MainActor
private struct InkribeScreenshotMusicScreen: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        InkribeScreenshotAppScreen(
            palette: palette,
            title: "Music",
            leading: .text("Cancel"),
            trailing: "Done"
        ) {
            VStack(spacing: 10) {
                InkribeScreenshotFormSection("Audio file", palette: palette) {
                    InkribeScreenshotFormRow(
                        palette: palette,
                        label: "File",
                        icon: "music.note",
                        value: "Golden Hour.mp3"
                    )
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotFormRow(palette: palette, label: "Duration", value: "03:12.000")
                    InkribeScreenshotFormDivider(palette: palette)
                    actionRow("Replace music", symbol: "arrow.triangle.2.circlepath")
                }

                InkribeScreenshotFormSection("Audio", palette: palette) {
                    InkribeScreenshotSliderRow(
                        palette: palette,
                        label: "Volume",
                        value: "35%",
                        fraction: 0.35
                    )
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotToggleRow(palette: palette, label: "Mute music", isOn: false)
                }

                InkribeScreenshotFormSection("Timing", palette: palette) {
                    InkribeScreenshotFormRow(palette: palette, label: "Song start", value: "12.000")
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotFormRow(palette: palette, label: "Song end", value: "84.000")
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotFormRow(palette: palette, label: "Start in video", value: "0.000")
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotToggleRow(palette: palette, label: "Loop to fit video", isOn: true)
                    Text("Times are in seconds. The selected song section repeats when looping is on. Music stops at the video’s end.")
                        .font(.system(size: 8))
                        .lineSpacing(1)
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                }

                InkribeScreenshotFormSection("Fades", palette: palette) {
                    InkribeScreenshotSliderRow(
                        palette: palette,
                        label: "Fade in",
                        value: "1.0 s",
                        fraction: 0.20
                    )
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotSliderRow(
                        palette: palette,
                        label: "Fade out",
                        value: "1.5 s",
                        fraction: 0.30
                    )
                }

                InkribeScreenshotFormSection(palette: palette) {
                    actionRow("Remove music", symbol: "trash", destructive: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func actionRow(_ title: String, symbol: String, destructive: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(title).font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(destructive ? Color.red : palette.accent)
        .padding(.horizontal, 11)
        .frame(height: 32)
    }
}

// MARK: - Export

@MainActor
private struct InkribeScreenshotExportScreen: View {
    let palette: InkribeScreenshotPalette

    var body: some View {
        InkribeScreenshotAppScreen(
            palette: palette,
            title: "Export",
            trailing: "Done"
        ) {
            VStack(spacing: 10) {
                InkribeScreenshotFormSection("Export this project", palette: palette) {
                    Text("Morning walk")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotFormRow(
                        palette: palette,
                        label: "Format",
                        value: "Captioned video",
                        showsChevron: true
                    )
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotFormRow(
                        palette: palette,
                        label: "Resolution",
                        value: "1080p",
                        showsChevron: true
                    )
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotFormRow(
                        palette: palette,
                        label: "Frame rate",
                        value: "30 fps",
                        showsChevron: true
                    )
                    InkribeScreenshotFormDivider(palette: palette)
                    InkribeScreenshotFormRow(
                        palette: palette,
                        label: "Output",
                        value: "1920 × 1080 · 30 fps"
                    )

                    Text("H.264 MP4 with burned-in captions and original audio.")
                        .font(.system(size: 8.5))
                        .lineSpacing(1)
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.top, 2)

                    InkribeScreenshotPrimaryButton(
                        palette: palette,
                        title: "Create Export",
                        symbol: "square.and.arrow.up"
                    )
                    .padding(.horizontal, 9)
                    .padding(.top, 7)
                    .padding(.bottom, 8)
                }

                InkribeScreenshotFormSection("Exports", palette: palette) {
                    exportRow(
                        icon: "film",
                        title: "Captioned video",
                        metadata: "1080p · 30 fps · 00:24 · 84.2 MB",
                        note: "Completed · Nov 12, 9:41 AM"
                    )
                    InkribeScreenshotFormDivider(palette: palette)
                    exportRow(
                        icon: "doc.text",
                        title: "SRT subtitles",
                        metadata: "00:24 · 2 KB",
                        note: "Completed · Nov 12, 9:42 AM"
                    )
                }

                Text("Each export keeps its own saved version and file. Progress and completed videos or subtitles appear below while you continue editing.")
                    .font(.system(size: 8))
                    .lineSpacing(1)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func exportRow(icon: String, title: String, metadata: String, note: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(palette.soft)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text(metadata)
                    .font(.system(size: 8.5))
                    .foregroundStyle(palette.secondary)
                Text(note)
                    .font(.system(size: 8.5))
                    .foregroundStyle(palette.secondary)
            }

            Spacer(minLength: 4)
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
    }
}
#endif
