import AppFoundation
import AVFoundation
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
    @State private var isSaving = false
    @State private var errorMessage: String?

    @AppStorage("riidrr.voices.favorites") private var favoritesStorage = ""
    @AppStorage("riidrr.voices.recent") private var recentStorage = ""

    @State private var previewTask: Task<Void, Never>?
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewVoiceID: String?

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
            .onChange(of: runtimeManager.hasActiveAudioWork) { _, active in
                if active { stopPreview() }
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
                preview(voice)
            } label: {
                Group {
                    if previewVoiceID == voice.id && previewTask != nil {
                        ProgressView()
                    } else {
                        Image(systemName: previewVoiceID == voice.id
                              && previewPlayer?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isSaving || runtimeManager.hasActiveAudioWork
                      || (previewTask != nil && previewVoiceID != voice.id))
            .accessibilityLabel(previewVoiceID == voice.id ? "Stop preview" : "Preview \(voice.name)")

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
        previewTask?.cancel()
        previewPlayer?.stop()
        previewPlayer = nil
        if previewTask == nil { previewVoiceID = nil }
    }

    /// Spokio plays bundled clips; Riidrr synthesizes a short preview locally,
    /// only while no project playback or generation is active.
    private func preview(_ voice: SpeechVoice) {
        if previewVoiceID == voice.id {
            if previewTask != nil {
                previewTask?.cancel()
                return
            }
            if previewPlayer?.isPlaying == true {
                previewPlayer?.stop()
                previewPlayer = nil
                previewVoiceID = nil
                return
            }
        }
        guard previewTask == nil, !runtimeManager.hasActiveAudioWork else { return }
        previewPlayer?.stop()
        previewPlayer = nil
        previewVoiceID = voice.id
        previewTask = Task { @MainActor in
            let engine = KokoroONNXEngine.shared
            defer {
                previewTask = nil
                if previewPlayer == nil { previewVoiceID = nil }
            }
            do {
                let result = try await engine.synthesize(
                    text: "Hello, welcome to your next chapter.",
                    voice: voice,
                    speed: 1,
                    maxChunkSeconds: 15
                )
                try Task.checkCancellation()
                await engine.unload()
                try Task.checkCancellation()
                guard !runtimeManager.hasActiveAudioWork else { return }
                let wav = try ProjectWAVCodec.encode(
                    samples: result.audio.samples,
                    sampleRate: result.audio.sampleRate
                )
                try AVAudioSession.sharedInstance().setCategory(
                    .playback, mode: .spokenAudio
                )
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(data: wav)
                guard player.prepareToPlay(), player.play() else {
                    throw SpeechEngineError.synthesisFailed("Preview could not start.")
                }
                previewPlayer = player
            } catch is CancellationError {
                await engine.unload()
            } catch {
                await engine.unload()
                if !Task.isCancelled {
                    errorMessage = "Preview unavailable: \(error.localizedDescription)"
                }
            }
        }
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
