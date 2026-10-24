import SwiftUI

struct MediaPanel: View {
    let session: EditorSession
    @FocusState.Binding var focused: EditorField?
    @State private var start = ""
    @State private var end = ""
    @State private var trimError: String?
    private var edits: MediaEdits { session.document?.effectiveMediaEdits ?? .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let document = session.document {
                Text("Media").font(.headline)
                Text("Changes apply to this project's output. Your originals are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Trim").font(.headline)
                Group {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Choose start and end seconds on the original timeline. The retained video starts at 0.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Start (s)").font(.caption)
                                TextField("Start", text: trimField(isStart: true)).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                                    .focused($focused, equals: .trimStart).accessibilityLabel("Trim start seconds")
                                    .id(EditorField.trimStart)
                            }
                            VStack(alignment: .leading) {
                                Text("End (s)").font(.caption)
                                TextField("End", text: trimField(isStart: false)).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                                    .focused($focused, equals: .trimEnd).accessibilityLabel("Trim end seconds")
                                    .id(EditorField.trimEnd)
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { trimButtons }
                            VStack(alignment: .leading) { trimButtons }
                        }
                        Text("Output length: \(EditorTime.display(document.outputDuration))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let trimError { Text(trimError).font(.footnote).foregroundStyle(.red) }
                    }
                    .padding(.top, 8)
                }
                Divider()
                Text("Framing").font(.headline)
                Menu {
                    if let original = originalCanvas(document) {
                        Button("Original video aspect") { aspect(original, preset: .original) }
                    }
                    Button("Portrait · 9:16") { aspect(ProjectCanvas(width: 1080, height: 1920), preset: .portrait) }
                    Button("Square · 1:1") { aspect(ProjectCanvas(width: 1080, height: 1080), preset: .square) }
                    Button("Landscape · 16:9") { aspect(ProjectCanvas(width: 1920, height: 1080), preset: .landscape) }
                } label: { Label("Aspect ratio · \(document.canvas.width) × \(document.canvas.height)", systemImage: "aspectratio") }
                Picker("Framing", selection: value(\.fit)) {
                    ForEach(MediaFit.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Zoom", key: \.zoom, control: .zoom, range: 1...3, display: String(format: "%.2f×", edits.zoom))
                slider("Horizontal crop", key: \.positionX, control: .x, range: 0...1,
                    display: "\(Int((edits.positionX * 100).rounded()))%")
                slider("Vertical crop", key: \.positionY, control: .y, range: 0...1,
                    display: "\(Int((edits.positionY * 100).rounded()))%")
                Text("Position moves the part that extends beyond the frame. Fit keeps the whole image; Fill crops to the chosen aspect. Captions stay positioned on the output canvas.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset crop", systemImage: "arrow.counterclockwise") {
                    var next = edits
                    next.fit = .fit; next.zoom = 1; next.positionX = 0.5; next.positionY = 0.5
                    session.setMediaPresentation(next)
                }
                Divider()
                Text("Original audio").font(.headline)
                slider("Volume", key: \.volume, control: .volume, range: 0...1,
                    display: edits.volume == 0 ? "Muted" : "\(Int((edits.volume * 100).rounded()))%")
                Button("Reset volume") {
                    var next = edits; next.volume = 1
                    session.setMediaPresentation(next)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { resetFields() }
        .onChange(of: edits.trim) { _, _ in resetFields() }
        .onChange(of: session.workspace.fieldResetGeneration) { _, _ in resetFields() }
        .onDisappear { session.endMediaEditing() }
    }

    private var trimButtons: some View {
        Group {
            Button("Apply trim") {
                guard let document = session.document else { return }
                do {
                    let currentStart = edits.trim?.start ?? .zero
                    let currentEnd = edits.trim?.end ?? document.sourceDuration
                    func parse(_ text: String, preserving current: MediaTime) throws -> MediaTime {
                        if text == EditorTime.field(current) { return current }
                        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { throw MediaEditError.invalidSettings }
                        return try EditorTime.stamp(value)
                    }
                    let interval = try MediaInterval(start: parse(start, preserving: currentStart), end: parse(end, preserving: currentEnd))
                    var next = edits
                    next.trim = interval.start == .zero && interval.end == document.sourceDuration ? nil : interval
                    try next.validate(sourceDuration: document.sourceDuration)
                    focused = nil; trimError = nil
                    session.setMediaPresentation(next)
                } catch { trimError = MediaEditError.invalidSettings.localizedDescription }
            }
            Button("Reset trim") {
                focused = nil; trimError = nil
                var next = edits; next.trim = nil
                session.setMediaPresentation(next)
            }
            .disabled(edits.trim == nil)
        }
        .buttonStyle(.bordered)
    }
    private var trimInterval: MediaInterval? {
        guard let document = session.document else { return nil }
        return edits.trim ?? (try? MediaInterval(start: .zero, end: document.sourceDuration))
    }
    private func trimField(isStart: Bool) -> Binding<String> {
        Binding(get: { isStart ? start : end }, set: { value in
            if isStart { start = value } else { end = value }
            if let interval = trimInterval {
                session.workspace.trimDraft = EditorTimingDraft(id: session.projectID, interval: interval, start: start, end: end)
            }
        })
    }
    private func resetFields() {
        if let draft = session.workspace.trimDraft, draft.interval == trimInterval {
            start = draft.start; end = draft.end
        } else {
            start = EditorTime.field(edits.trim?.start ?? .zero)
            end = EditorTime.field(edits.trim?.end ?? session.document?.sourceDuration ?? .zero)
        }
        trimError = nil
    }
    private func slider(_ title: String, key: WritableKeyPath<MediaEdits, Double>, control: MediaControl,
                        range: ClosedRange<Double>, display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(display).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value(key, control: control), in: range, onEditingChanged: { _ in session.endMediaEditing() })
                .accessibilityLabel(title).accessibilityValue(display)
        }
    }
    private func value<T>(_ key: WritableKeyPath<MediaEdits, T>, control: MediaControl? = nil) -> Binding<T> {
        Binding(get: { edits[keyPath: key] }, set: { value in
            var next = edits; next[keyPath: key] = value
            session.setMediaPresentation(next, coalescing: control)
        })
    }
    private func aspect(_ canvas: ProjectCanvas, preset: CanvasPreset) {
        focused = nil
        session.setMediaPresentation(edits, canvas: canvas, preset: preset)
    }
    private func originalCanvas(_ document: ProjectDocument) -> ProjectCanvas? {
        let timeline = OutputTimeline(document)
        let used = Set(document.clips.filter { timeline.retained($0.timelineInterval) != nil }.map(\.sourceAssetID))
        guard let source = document.assets.first(where: { used.contains($0.id) && $0.metadata.videoTrackCount > 0 }) else { return nil }
        let canvas = ProjectCanvas(width: source.metadata.displayedWidth, height: source.metadata.displayedHeight)
        do { try canvas.validate(); return canvas }
        catch { return nil }
    }
}
