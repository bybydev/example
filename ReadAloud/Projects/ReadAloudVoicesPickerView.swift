import AppFoundation
import AVFoundation
import Observation
import SwiftUI

/// Voice selection follows Spokio iOS's searchable Voices sheet and list-row
/// interactions, adapted to Riidrr's fixed, offline English Kokoro catalog.
@MainActor
struct ReadAloudVoicesPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    @Environment(PurchaseManager.self) private var purchases
    @Environment(ProjectRuntimeManager.self) private var runtimeManager

    let selectedVoiceID: String?
    let inheritTitle: String?
    let inheritDetail: String?
    let onSelect: @MainActor (String?) async -> Bool

    @State private var searchText = ""
    @State private var scope: VoiceScope = .all
    @State private var sort: VoiceSort = .name
    @State private var ascending = true
    @State private var genderFilter: String?
    @State private var accentFilter: String?
    @State private var showingFilters = false
    @State private var showingPaywall = false
    @State private var showingPreviewText = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    @AppStorage("riidrr.voices.favorites") private var favoritesStorage = ""
    @AppStorage("riidrr.voices.recent") private var recentStorage = ""

    private var previews: VoicePreviewController { runtimeManager.voicePreviews }

    @State private var detent: PresentationDetent = .large

    private var favorites: Set<String> {
        Set(favoritesStorage.split(separator: ",").map(String.init))
    }

    private var recent: [String] {
        recentStorage.split(separator: ",").map(String.init)
    }

    private var activeFilterCount: Int {
        (genderFilter == nil ? 0 : 1) + (accentFilter == nil ? 0 : 1)
    }

    private var visibleVoices: [SpeechVoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentOrder = Dictionary(uniqueKeysWithValues: recent.enumerated().map {
            ($0.element, $0.offset)
        })

        let filtered = SpeechVoice.all.filter { voice in
            switch scope {
            case .all: break
            case .recent: guard recentOrder[voice.id] != nil else { return false }
            case .favorites: guard favorites.contains(voice.id) else { return false }
            case .american: guard voice.locale == "American English" else { return false }
            case .british: guard voice.locale == "British English" else { return false }
            }

            if let genderFilter, voice.gender != genderFilter { return false }
            if let accentFilter, voice.locale != accentFilter { return false }

            return query.isEmpty
                || voice.name.localizedCaseInsensitiveContains(query)
                || voice.locale.localizedCaseInsensitiveContains(query)
                || voice.gender.localizedCaseInsensitiveContains(query)
        }

        if scope == .recent {
            return filtered.sorted {
                (recentOrder[$0.id] ?? Int.max) < (recentOrder[$1.id] ?? Int.max)
            }
        }

        return filtered.sorted { lhs, rhs in
            let primary: ComparisonResult
            switch sort {
            case .name:
                primary = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .accent:
                primary = lhs.locale.localizedCaseInsensitiveCompare(rhs.locale)
            }
            let value = primary == .orderedSame
                ? lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                : primary
            if value == .orderedSame { return lhs.id < rhs.id }
            return ascending ? value == .orderedAscending : value == .orderedDescending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                scopeStrip
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 14, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                if let inheritTitle {
                    Section {
                        Button {
                            choose(nil)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .font(.title2)
                                    .frame(width: 38, height: 38)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(inheritTitle)
                                        .font(.body.weight(.semibold))
                                    if let inheritDetail {
                                        Text(inheritDetail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedVoiceID == nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(theme.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }
                }

                Section {
                    if visibleVoices.isEmpty {
                        ContentUnavailableView(
                            "No Matches",
                            systemImage: "person.wave.2",
                            description: Text("Try changing the search or voice filters.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(visibleVoices) { voice in
                            voiceRow(voice)
                                .listRowInsets(
                                    .init(top: 4, leading: 16, bottom: 4, trailing: 16)
                                )
                                .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(theme.backgroundColor.ignoresSafeArea())
            .navigationTitle("Voices")
            .navigationBarTitleDisplayMode(.large)
            .navigationSubtitle("\(visibleVoices.count) voices · \(sort.title)")
            .searchable(text: $searchText, prompt: "Search voices")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Preview Text", systemImage: "text.quote") {
                            showingPreviewText = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Voice Options")
                    if scope != .recent {
                        Menu {
                            Picker("Sort By", selection: $sort) {
                                ForEach(VoiceSort.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                            Picker("Order", selection: $ascending) {
                                Text("Ascending").tag(true)
                                Text("Descending").tag(false)
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    Button {
                        showingFilters = true
                    } label: {
                        Image(systemName: activeFilterCount == 0
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Voice Filters")
                    .accessibilityValue("\(activeFilterCount) active")
                }
            }
            .sheet(isPresented: $showingFilters) {
                VoiceFilterSheet(
                    gender: $genderFilter,
                    accent: $accentFilter
                )
            }
            .sheet(isPresented: $showingPaywall) {
                ReadAloudProPaywall()
            }
            .sheet(isPresented: $showingPreviewText) {
                VoicePreviewTextSheet {
                    stopPreview()
                }
            }
            .alert(
                "Voice Preview",
                isPresented: Binding(
                    get: { previews.errorMessage != nil },
                    set: { if !$0 { previews.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { previews.errorMessage = nil }
            } message: {
                Text(previews.errorMessage ?? "Preview unavailable. Please try again.")
            }
            .alert(
                "Voice Selection",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "This voice could not be selected.")
            }
            .onDisappear { stopPreview() }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var scopeStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                scopeTile(.all, icon: "rectangle.stack.fill", count: SpeechVoice.all.count)
                scopeTile(.recent, icon: "clock", count: recent.count)
                scopeTile(.favorites, icon: "star.fill", count: favorites.count)
                scopeTile(.american, icon: "waveform", count: 20)
                scopeTile(.british, icon: "waveform", count: 8)
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func scopeTile(_ target: VoiceScope, icon: String, count: Int) -> some View {
        Button {
            scope = target
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(target.title)
                    .font(.subheadline.weight(scope == target ? .semibold : .regular))
                Text("\(count)")
                    .font(.caption)
            }
            .foregroundStyle(scope == target ? theme.accentColor : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .overlay {
                Capsule().strokeBorder(
                    scope == target ? theme.accentColor.opacity(0.55) : theme.borderColor,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scope == target ? .isSelected : [])
    }

    private func voiceRow(_ voice: SpeechVoice) -> some View {
        HStack(spacing: 8) {
            Button {
                choose(voice.id)
            } label: {
                HStack(spacing: 12) {
                    Text(String(voice.name.prefix(1)))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(avatarGradient(voice), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(voice.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if voice.id == SpeechVoice.heart.id {
                                Text("Default")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(theme.accentColor)
                            }
                        }
                        Text("\(voice.gender) · \(voice.locale)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if isLocked(voice) {
                            Label("Pro", systemImage: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 4)
                    if selectedVoiceID == voice.id {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(theme.accentColor)
                            .accessibilityLabel("Selected")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving)

            Button {
                runtimeManager.previewVoice(voice)
            } label: {
                Group {
                    if previews.activeVoiceID == voice.id && previews.isPreparing {
                        ProgressView()
                    } else {
                        Image(systemName: previews.activeVoiceID == voice.id
                              ? "stop.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isSaving)
            .accessibilityLabel(previews.activeVoiceID == voice.id ? "Stop preview" : "Preview \(voice.name)")

            Button {
                toggleFavorite(voice.id)
            } label: {
                Image(systemName: favorites.contains(voice.id) ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(favorites.contains(voice.id) ? Color.orange : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorites.contains(voice.id)
                                ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.vertical, 2)
        .listRowSeparatorTint(Color.primary.opacity(0.15))
    }

    private func avatarGradient(_ voice: SpeechVoice) -> LinearGradient {
        let palettes: [[Color]] = [
            [.blue, .indigo], [.orange, .pink], [.mint, .blue],
            [.yellow, .purple], [.green, .teal],
        ]
        let seed = voice.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return LinearGradient(
            colors: palettes[seed % palettes.count],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func isLocked(_ voice: SpeechVoice) -> Bool {
        !ReadAloudAccessPolicy.canUseVoice(
            voice.id, hasPro: purchases.hasPro
        )
    }

    private func choose(_ id: String?) {
        guard !isSaving else { return }
        if let id,
           let voice = SpeechVoice.all.first(where: { $0.id == id }),
           isLocked(voice) {
            showingPaywall = true
            return
        }
        stopPreview()
        isSaving = true
        Task { @MainActor in
            let success = await onSelect(id)
            isSaving = false
            if success {
                if let id { markRecent(id) }
                dismiss()
            } else {
                errorMessage = "Unable to save this voice selection."
            }
        }
    }

    private func toggleFavorite(_ id: String) {
        var ids = favorites
        if !ids.insert(id).inserted { ids.remove(id) }
        favoritesStorage = ids.sorted().joined(separator: ",")
    }

    private func markRecent(_ id: String) {
        var ids = recent.filter { $0 != id }
        ids.insert(id, at: 0)
        recentStorage = Array(ids.prefix(SpeechVoice.all.count)).joined(separator: ",")
    }

    private func stopPreview() {
        previews.stop()
    }
}

/// Lives beside the existing picker to keep owner-managed project files intact.
/// The runtime manager owns this controller, but previews never own a book.
@Observable
@MainActor
final class VoicePreviewController {
    private(set) var activeVoiceID: String?
    private(set) var isPreparing = false
    var errorMessage: String?

    @ObservationIgnored private let cache: VoicePreviewCache
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: VoicePreviewPlayerDelegate?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(cache: VoicePreviewCache = VoicePreviewCache()) {
        self.cache = cache
    }

    func preview(
        _ voice: SpeechVoice, text: String,
        beforePlayback: @escaping @MainActor () -> Void
    ) {
        if activeVoiceID == voice.id {
            stop()
            return
        }
        stop()
        errorMessage = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.utf16.count <= ReadAloudPreferences.maximumVoicePreviewUTF16 else {
            errorMessage = "Use a short preview text of up to \(ReadAloudPreferences.maximumVoicePreviewUTF16) characters."
            return
        }

        let id = UUID()
        requestID = id
        activeVoiceID = voice.id
        isPreparing = true
        installObservers(for: id)
        let request = VoicePreviewRequest(
            voice: voice, text: text,
            pronunciationMode: ReadAloudPreferences.pronunciationFallbackMode
        )
        task = Task { @MainActor [weak self, cache] in
            do {
                let url = try await cache.audioURL(for: request)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                let player = try AVAudioPlayer(contentsOf: url)
                guard player.prepareToPlay() else {
                    throw SpeechEngineError.synthesisFailed("Preview could not be prepared.")
                }
                // No suspension between pausing a preparing/playing book and
                // starting the sample. All starts/resumes invalidate this ID.
                beforePlayback()
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                self.player = player
                let delegate = VoicePreviewPlayerDelegate { [weak self] success in
                    guard let self, self.requestID == id else { return }
                    self.stop()
                    if !success {
                        self.errorMessage = "Preview could not be played. Please try again."
                    }
                }
                self.playerDelegate = delegate
                player.delegate = delegate
                guard player.play() else {
                    throw SpeechEngineError.synthesisFailed("Preview could not start.")
                }
                self.isPreparing = false
                self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                let wasCancelled = Task.isCancelled || error is CancellationError
                self.stop()
                if !wasCancelled {
                    self.errorMessage = "Preview unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        requestID = nil
        task?.cancel()
        task = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        playerDelegate = nil
        activeVoiceID = nil
        isPreparing = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        // The audio session is shared with the paused book. Do not deactivate it.
    }

    func shutdown() {
        stop()
        errorMessage = nil
    }

    private nonisolated enum SessionNotice: Sendable {
        case interruption, routeChange, reset
    }

    private func installObservers(for id: UUID) {
        let notices: [(Notification.Name, SessionNotice)] = [
            (AVAudioSession.interruptionNotification, .interruption),
            (AVAudioSession.routeChangeNotification, .routeChange),
            (AVAudioSession.mediaServicesWereResetNotification, .reset),
        ]
        for (name, notice) in notices {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: AVAudioSession.sharedInstance(), queue: .main,
                using: Self.sessionHandler(self, requestID: id, notice: notice)
            ))
        }
    }

    nonisolated private static func sessionHandler(
        _ controller: VoicePreviewController, requestID: UUID, notice: SessionNotice
    ) -> @Sendable (Notification) -> Void {
        { [weak controller] notification in
            switch notice {
            case .interruption:
                guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                        == AVAudioSession.InterruptionType.began.rawValue else { return }
            case .routeChange:
                guard notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                        == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            case .reset:
                break
            }
            Task { @MainActor [weak controller] in
                guard controller?.requestID == requestID else { return }
                controller?.stop()
            }
        }
    }
}

/// Each player gets a delegate bound to its immutable request ID via onFinish.
/// Forward only Sendable values from audio callbacks, never player/error objects.
@MainActor
private final class VoicePreviewPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    nonisolated let onFinish: @MainActor @Sendable (Bool) -> Void

    init(onFinish: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let onFinish = onFinish
        Task { @MainActor in onFinish(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let onFinish = onFinish
        Task { @MainActor in onFinish(false) }
    }
}

nonisolated struct VoicePreviewRequest: Sendable {
    let voice: SpeechVoice
    let text: String
    let pronunciationMode: PronunciationFallbackMode

    var cacheKey: String {
        get throws {
            let key = try ProjectGenerationKey.make(GenerationKeyInput(
                contentRevision: ProjectDigest.sha256(text),
                resolvedVoiceID: voice.id,
                canonicalSpeed: 1.0,
                kokoroRuntimeRevision: ReadAloudSynthesisContract.generationRuntimeRevision(
                    base: ReadAloudSynthesisContract.runtimeRevision(),
                    pronunciationMode: pronunciationMode
                ),
                synthesisConfigVersion: ReadAloudNarrationCatalog.synthesisConfigVersion
            ))
            return ProjectDigest.sha256("readaloud-voice-preview-wav-v1\n" + key)
        }
    }
}

/// Disk IO/PCM encoding stay off the main actor. Inference uses the same ONNX
/// actor as book generation; no private engine or global cancellation/unload.
actor VoicePreviewCache {
    private let rootURL: URL?
    private let engine: any SpeechSynthesisEngine

    init(rootURL: URL? = nil, engine: any SpeechSynthesisEngine = KokoroONNXEngine.shared) {
        self.rootURL = rootURL
        self.engine = engine
    }

    func audioURL(for request: VoicePreviewRequest) async throws -> URL {
        try Task.checkCancellation()
        guard SpeechVoice.all.contains(request.voice),
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.utf16.count <= ReadAloudPreferences.maximumVoicePreviewUTF16 else {
            throw SpeechEngineError.synthesisFailed("Invalid preview text or voice.")
        }
        let directory: URL
        if let rootURL {
            directory = rootURL
        } else {
            directory = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("VoicePreviews", isDirectory: true)
        }
        let url = directory.appendingPathComponent(try request.cacheKey).appendingPathExtension("wav")
        if validAudio(at: url) { return url }

        let result = try await engine.synthesize(
            text: request.text, voice: request.voice, speed: 1.0,
            maxChunkSeconds: 15, pronunciationMode: request.pronunciationMode
        )
        try Task.checkCancellation()
        try ReadAloudSafety.validate(result.audio, maximumSamples: ReadAloudSafety.maximumParagraphSamples)
        let data = try ProjectWAVCodec.encode(
            samples: result.audio.samples, sampleRate: result.audio.sampleRate
        )
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func validAudio(at url: URL) -> Bool {
        do {
            // Bound the read before allocating/decoding even a corrupt cache file.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue >= 44,
                  size.intValue <= 44 + ReadAloudSafety.maximumParagraphSamples * 2 else { return false }
            let data = try Data(contentsOf: url)
            let audio = try ProjectWAVCodec.decode(data)
            try ReadAloudSafety.validate(audio, maximumSamples: ReadAloudSafety.maximumParagraphSamples)
            return true
        } catch {
            return false
        }
    }
}

private struct VoicePreviewTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    @State private var text = ReadAloudPreferences.voicePreviewText
    let onSave: @MainActor () -> Void

    private var savedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !savedText.isEmpty && savedText.utf16.count <= ReadAloudPreferences.maximumVoicePreviewUTF16
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Preview text", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityLabel("Preview text")
                } footer: {
                    Text("Used for every voice at normal speed. Keep it short (up to \(ReadAloudPreferences.maximumVoicePreviewUTF16) characters).")
                }
                Section {
                    Button("Reset to Default") {
                        text = ReadAloudPreferences.defaultVoicePreviewText
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.backgroundColor.ignoresSafeArea())
            .tint(theme.accentColor)
            .navigationTitle("Preview Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard canSave else { return }
                        if savedText != ReadAloudPreferences.voicePreviewText {
                            onSave()
                            UserDefaults.standard.set(savedText, forKey: ReadAloudPreferences.Key.voicePreviewText)
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private enum VoiceScope: String, CaseIterable, Identifiable {
    case all, recent, favorites, american, british
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .american: "American"
        case .british: "British"
        }
    }
}

private enum VoiceSort: String, CaseIterable, Identifiable {
    case name, accent
    var id: Self { self }
    var title: String {
        switch self {
        case .name: "Name"
        case .accent: "Accent"
        }
    }
}

private extension SpeechVoice {
    var gender: String {
        id.dropFirst(1).first == "f" ? "Female" : "Male"
    }
}

private struct VoiceFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    @Binding var gender: String?
    @Binding var accent: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("Accent") {
                        filterRow(
                            values: ["American English", "British English"],
                            selected: $accent
                        )
                    }
                    group("Gender") {
                        filterRow(values: ["Female", "Male"], selected: $gender)
                    }
                }
                .padding(20)
            }
            .background(theme.backgroundColor.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        accent = nil
                        gender = nil
                    }
                    .disabled(accent == nil && gender == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterRow(values: [String], selected: Binding<String?>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                filterChip("All", selected: selected.wrappedValue == nil) {
                    selected.wrappedValue = nil
                }
                ForEach(values, id: \.self) { value in
                    filterChip(value, selected: selected.wrappedValue == value) {
                        selected.wrappedValue = value
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                filterChip("All", selected: selected.wrappedValue == nil) {
                    selected.wrappedValue = nil
                }
                ForEach(values, id: \.self) { value in
                    filterChip(value, selected: selected.wrappedValue == value) {
                        selected.wrappedValue = value
                    }
                }
            }
        }
    }

    private func filterChip(
        _ text: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.accentColor : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    selected ? theme.accentColor.opacity(0.14) : theme.elevatedSurfaceColor,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

