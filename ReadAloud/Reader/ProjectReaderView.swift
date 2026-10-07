import Foundation
import SwiftUI

struct ProjectReaderRuntimeHost: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager
    @State private var runtime: ProjectRuntime?
    @State private var errorMessage: String?
    @State private var isLoading = true

    let projectID: UUID
    let initialItemID: UUID?
    let initialTitle: String
    let onProjectChanged: () -> Void

    init(
        projectID: UUID,
        initialItemID: UUID?,
        initialTitle: String,
        onProjectChanged: @escaping () -> Void = {}
    ) {
        self.projectID = projectID
        self.initialItemID = initialItemID
        self.initialTitle = initialTitle
        self.onProjectChanged = onProjectChanged
    }

    var body: some View {
        Group {
            if let runtime {
                ProjectReaderView(
                    runtime: runtime,
                    initialItemID:
                        initialItemID
                        ?? runtime.continueItemID
                        ?? runtime.itemStates.first?.id
                )
            } else if isLoading {
                ProgressView("Opening Reader…")
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            } else {
                ContentUnavailableView(
                    "Reader Unavailable",
                    systemImage:
                        "exclamationmark.triangle",
                    description: Text(
                        errorMessage
                            ?? "This project could not be opened."
                    )
                )
            }
        }
        .navigationTitle(
            runtime?.project?.title ?? initialTitle
        )
        .navigationBarTitleDisplayMode(.inline)
        .task(id: projectID) {
            if let runtime {
                runtimeManager.makeActive(runtime)
                return
            }

            isLoading = true
            defer { isLoading = false }

            do {
                runtime =
                    try await runtimeManager.activate(
                        projectID: projectID
                    )
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
        .onDisappear {
            onProjectChanged()
        }
    }

    nonisolated private static func message(
        for error: Error
    ) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

struct ProjectReaderView: View {
    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

    @State private var displayedItemID: UUID?
    @State private var followsPlaybackContext = true
    @State private var followsParagraph = true
    @State private var chaptersPresented = false
    @State private var voicePresented = false
    @State private var speedPresented = false
    @State private var appearancePresented = false
    @State private var infoPresented = false
    @State private var errorMessage: String?
    @State private var settingsModel:
        ProjectDetailModel

    @AppStorage(
        "com.hoangbkit.readaloud.reader-font-size"
    )
    private var readerFontSize = 20.0

    @AppStorage(
        "com.hoangbkit.readaloud.reader-line-spacing"
    )
    private var readerLineSpacing = 7.0

    let runtime: ProjectRuntime

    init(
        runtime: ProjectRuntime,
        initialItemID: UUID?
    ) {
        self.runtime = runtime
        _displayedItemID = State(
            initialValue:
                initialItemID
                ?? runtime.continueItemID
                ?? runtime.itemStates.first?.id
        )
        _settingsModel = State(
            initialValue:
                ProjectDetailModel(runtime: runtime)
        )
    }

    var body: some View {
        Group {
            if let item = displayedState {
                reader(item)
            } else {
                ContentUnavailableView(
                    "Nothing to Read",
                    systemImage: "text.book.closed",
                    description: Text(
                        "This project has no readable sections."
                    )
                )
            }
        }
        .navigationTitle(
            displayedState?.item.title
                ?? runtime.project?.title
                ?? "Reader"
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(
                placement: .topBarTrailing
            ) {
                Button {
                    chaptersPresented = true
                } label: {
                    Image(
                        systemName: "list.bullet"
                    )
                }
                .accessibilityLabel("Chapters")

                moreMenu
            }
        }
        .safeAreaInset(
            edge: .bottom,
            spacing: 0
        ) {
            readerControls
        }
        .sheet(
            isPresented: $chaptersPresented
        ) {
            ReaderChaptersSheet(
                runtime: runtime,
                selectedItemID: displayedItemID,
                onSelect: { itemID in
                    selectItem(itemID)
                    chaptersPresented = false
                },
                onError: {
                    errorMessage = $0
                }
            )
        }
        .sheet(
            isPresented: $voicePresented
        ) {
            if let displayedItemID {
                ItemVoicePicker(
                    model: settingsModel,
                    itemID: displayedItemID,
                    onChanged: {
                        handleNarrationChange()
                    }
                )
            }
        }
        .sheet(
            isPresented: $speedPresented
        ) {
            if let displayedItemID {
                ItemSpeedPicker(
                    model: settingsModel,
                    itemID: displayedItemID,
                    onChanged: {
                        handleNarrationChange()
                    }
                )
            }
        }
        .sheet(
            isPresented: $appearancePresented
        ) {
            ReaderAppearanceSheet(
                fontSize: $readerFontSize,
                lineSpacing:
                    $readerLineSpacing
            )
        }
        .sheet(
            isPresented: $infoPresented
        ) {
            if let displayedState {
                ReaderItemInfoSheet(
                    entry: displayedState
                )
            }
        }
        .alert(
            "Reader Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { presented in
                    if !presented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            runtimeManager.beginReader(runtime)
            runtimeManager.makeActive(runtime)
        }
        .onDisappear {
            runtimeManager.endReader(runtime)
        }
        .onChange(
            of: runtime.activity.activeItemID
        ) { oldValue, newValue in
            guard followsPlaybackContext,
                  let newValue,
                  oldValue != newValue
            else {
                return
            }
            displayedItemID = newValue
            followsParagraph = true
        }
    }

    private func reader(
        _ state: ProjectRuntimeItemState
    ) -> some View {
        let paragraphs =
            runtime.readerParagraphs(
                itemID: state.id
            )

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: 22
                ) {
                    readerHeader(state)

                    ForEach(paragraphs) {
                        paragraph in
                        Text(paragraph.text)
                            .font(
                                .system(
                                    size: readerFontSize
                                )
                            )
                            .lineSpacing(
                                readerLineSpacing
                            )
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(
                                .horizontal,
                                12
                            )
                            .padding(
                                .vertical,
                                8
                            )
                            .background {
                                if isCurrent(
                                    paragraph,
                                    itemID: state.id
                                ) {
                                    RoundedRectangle(
                                        cornerRadius: 10
                                    )
                                    .fill(
                                        Color.secondary
                                            .opacity(0.10)
                                    )
                                }
                            }
                            .id(paragraph.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .simultaneousGesture(
                DragGesture(
                    minimumDistance: 4
                )
                .onChanged { _ in
                    if runtime.activity
                        .activeItemID
                        == state.id,
                       runtime.activity
                        .currentParagraphRange
                        != nil
                    {
                        followsParagraph = false
                    }
                }
            )
            .overlay(
                alignment: .bottomTrailing
            ) {
                if shouldShowReturnToCurrent {
                    Button {
                        returnToCurrent(
                            proxy: proxy
                        )
                    } label: {
                        Label(
                            "Current",
                            systemImage:
                                "location.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
            .task(id: state.id) {
                guard let index =
                    restoredParagraphIndex(
                        state: state,
                        paragraphs: paragraphs
                    )
                else {
                    return
                }
                await Task.yield()
                proxy.scrollTo(
                    index,
                    anchor: .center
                )
            }
            .onChange(
                of: runtime.activity
                    .currentParagraphIndex
            ) { _, index in
                guard followsParagraph,
                      runtime.activity
                        .activeItemID
                        == state.id,
                      let index
                else {
                    return
                }

                withAnimation(
                    .easeInOut(duration: 0.25)
                ) {
                    proxy.scrollTo(
                        index,
                        anchor: .center
                    )
                }
            }
        }
    }

    private func readerHeader(
        _ state: ProjectRuntimeItemState
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 12
        ) {
            Text(
                runtime.project?.title
                    ?? "ReadAloud"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(state.item.title)
                .font(.title.bold())

            HStack(spacing: 12) {
                Button {
                    navigateDisplayedItem(
                        delta: -1
                    )
                } label: {
                    Label(
                        "Previous",
                        systemImage:
                            "chevron.left"
                    )
                }
                .disabled(
                    previousDisplayedItemID
                        == nil
                )

                Spacer()

                Text(
                    chapterPositionLabel
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    navigateDisplayedItem(
                        delta: 1
                    )
                } label: {
                    HStack(spacing: 5) {
                        Text("Next")
                        Image(
                            systemName:
                                "chevron.right"
                        )
                    }
                }
                .disabled(
                    nextDisplayedItemID == nil
                )
            }
            .font(.subheadline)
        }
        .padding(.bottom, 6)
    }

    private var readerControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(controlTitle)
                    .font(
                        .subheadline.weight(
                            .semibold
                        )
                    )
                    .lineLimit(1)

                Spacer()

                Text(
                    controlProgress,
                    format:
                        .percent.precision(
                            .fractionLength(0)
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ProgressView(
                value: controlProgress
            )

            if let playbackStatusText {
                Text(playbackStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }

            HStack(spacing: 34) {
                Button {
                    seek(by: -15)
                } label: {
                    Image(
                        systemName:
                            "gobackward.15"
                    )
                    .font(.title2)
                }
                .disabled(
                    runtime.activity
                        .activeItemID
                        != displayedItemID
                        || !runtime.isPlaybackActive
                )
                .accessibilityLabel(
                    "Seek backward"
                )

                Button {
                    togglePlayback()
                } label: {
                    Image(
                        systemName:
                            playPauseSystemImage
                    )
                    .font(
                        .system(
                            size: 32,
                            weight: .semibold
                        )
                    )
                    .frame(
                        width: 52,
                        height: 44
                    )
                }
                .accessibilityLabel(
                    playPauseAccessibilityLabel
                )

                Button {
                    seek(by: 15)
                } label: {
                    Image(
                        systemName:
                            "goforward.15"
                    )
                    .font(.title2)
                }
                .disabled(
                    runtime.activity
                        .activeItemID
                        != displayedItemID
                        || !runtime.isPlaybackActive
                )
                .accessibilityLabel(
                    "Seek forward"
                )
            }

            HStack(spacing: 18) {
                Button {
                    voicePresented = true
                } label: {
                    Label(
                        currentVoiceLabel,
                        systemImage: "waveform"
                    )
                }

                Spacer()

                Button {
                    speedPresented = true
                } label: {
                    Label(
                        currentSpeedLabel,
                        systemImage:
                            "speedometer"
                    )
                }
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.regularMaterial)
    }

    private var moreMenu: some View {
        Menu {
            if displayedState != nil {
                if displayedState?.generationStatus.state
                    != .readyOffline {
                    Button {
                        generateCurrent(
                            regenerate: false
                        )
                    } label: {
                        Label(
                            "Generate Current",
                            systemImage:
                                "arrow.down.circle"
                        )
                    }
                }
    
                if displayedState?.generationStatus.state
                    != .notGenerated {
                    Button {
                        generateCurrent(
                            regenerate: true
                        )
                    } label: {
                        Label(
                            "Regenerate Current",
                            systemImage:
                                "arrow.clockwise"
                        )
                    }
                }
    
                if currentGenerationHasAudio {
                    Button(
                        role: .destructive
                    ) {
                        clearCurrentAudio()
                    } label: {
                        Label(
                            "Clear Current Audio",
                            systemImage: "trash"
                        )
                    }
                }
    
    
            }

            Divider()

            Button {
                appearancePresented = true
            } label: {
                Label(
                    "Reader Appearance",
                    systemImage: "textformat"
                )
            }

            Button {
                infoPresented = true
            } label: {
                Label(
                    "Chapter Info",
                    systemImage: "info.circle"
                )
            }

            if runtime.isPlaybackActive {
                Divider()
                Button {
                    runtime.stopPlayback()
                } label: {
                    Label(
                        "Stop Playback",
                        systemImage:
                            "stop.fill"
                    )
                }
            }
        } label: {
            Image(
                systemName: "ellipsis.circle"
            )
        }
        .accessibilityLabel("Reader Actions")
    }

    private var displayedState:
        ProjectRuntimeItemState?
    {
        guard let displayedItemID else {
            return nil
        }
        return runtime.itemState(
            displayedItemID
        )
    }

    private var controlState:
        ProjectRuntimeItemState?
    {
        displayedState
    }

    private var controlTitle: String {
        controlState?.item.title
            ?? "Reader"
    }

    private var controlProgress: Double {
        if runtime.activity.activeItemID
            == controlState?.id,
           runtime.isPlaybackActive
        {
            return runtime.activity.itemProgress
        }

        guard let state = controlState,
              runtime.project?.playback?
                .currentItemID == state.id,
              runtime.project?.playback?
                .contentBookmark?
                .contentRevision
                == state.item.contentRevision
        else {
            return 0
        }

        let length = max(
            1,
            state.item.text.utf16.count
        )
        let offset =
            runtime.project?.playback?
                .contentBookmark?
                .textOffsetUTF16
            ?? 0
        return min(
            1,
            max(
                0,
                Double(offset)
                    / Double(length)
            )
        )
    }

    private var playPauseSystemImage:
        String
    {
        guard runtime.isPlaybackActive,
              runtime.activity.activeItemID
                == displayedItemID
        else {
            return "play.fill"
        }
        return runtime.isPlaybackPaused
            ? "play.fill"
            : "pause.fill"
    }

    private var playPauseAccessibilityLabel:
        String
    {
        guard runtime.isPlaybackActive,
              runtime.activity.activeItemID
                == displayedItemID
        else {
            return "Play"
        }
        return runtime.isPlaybackPaused
            ? "Resume"
            : "Pause"
    }

    private var playbackStatusText: String? {
        if runtime.isPlaybackActive,
           runtime.activity.activeItemID
            != displayedItemID,
           let activeItemID =
            runtime.activity.activeItemID,
           let active =
            runtime.itemState(activeItemID) {
            return "Playback continues in \(active.item.title)."
        }

        if case .failed(let message) =
            runtime.activity.playbackState {
            return message
        }

        guard runtime.activity.activeItemID
                == displayedItemID
        else {
            return nil
        }

        switch runtime.activity.playbackState {
        case .idle, .finished:
            return nil
        case .loading:
            return "Loading voice models…"
        case .warmingUp:
            return "Preparing speech…"
        case .synthesizing(let current, let total):
            return "Preparing audio \(current) of \(total)…"
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .failed(let message):
            return message
        }
    }

    private var currentVoiceLabel: String {
        guard let state = displayedState
        else {
            return "Voice"
        }
        return ReadAloudNarrationCatalog
            .voiceName(
                state.resolved.voiceID
            )
    }

    private var currentSpeedLabel: String {
        guard let state = displayedState
        else {
            return "Speed"
        }
        return state.resolved.speed
            .formatted(
                .number.precision(
                    .fractionLength(1)
                )
            ) + "×"
    }

    private var previousDisplayedItemID:
        UUID?
    {
        adjacentDisplayedItemID(
            delta: -1
        )
    }

    private var nextDisplayedItemID:
        UUID?
    {
        adjacentDisplayedItemID(
            delta: 1
        )
    }

    private var chapterPositionLabel:
        String
    {
        guard let displayedItemID,
              let index =
                runtime.itemStates
                    .firstIndex(where: {
                        $0.id
                            == displayedItemID
                    })
        else {
            return ""
        }

        return "\(index + 1) of \(runtime.itemStates.count)"
    }

    private var shouldShowReturnToCurrent:
        Bool
    {
        guard runtime.isPlaybackActive,
              let activeItemID =
                runtime.activity.activeItemID
        else {
            return false
        }

        if activeItemID != displayedItemID {
            return !followsPlaybackContext
        }

        return !followsParagraph
            && runtime.activity
                .currentParagraphIndex
                != nil
    }

    private var currentGenerationHasAudio:
        Bool
    {
        guard let state = displayedState
        else {
            return false
        }

        return state.generationStatus
            .audioBytes != nil
            || state.generationStatus.state
                == .readyOffline
            || state.generationStatus.state
                == .needsAttention
    }

    private func restoredParagraphIndex(
        state: ProjectRuntimeItemState,
        paragraphs: [ReaderParagraph]
    ) -> Int? {
        guard runtime.project?.playback?
                .currentItemID == state.id,
              runtime.project?.playback?
                .contentBookmark?
                .contentRevision
                == state.item.contentRevision,
              let offset =
                runtime.project?.playback?
                    .contentBookmark?
                    .textOffsetUTF16
        else {
            return nil
        }

        return ReaderTextLayout.paragraphIndex(
            forUTF16Offset: offset,
            in: paragraphs
        )
    }

    private func isCurrent(
        _ paragraph: ReaderParagraph,
        itemID: UUID
    ) -> Bool {
        runtime.isPlaybackActive
            && runtime.activity.activeItemID
                == itemID
            && runtime.activity
                .currentParagraphRange
                == paragraph.sourceRange
    }

    private func returnToCurrent(
        proxy: ScrollViewProxy
    ) {
        guard let itemID =
                runtime.activity.activeItemID
        else {
            return
        }

        let wasDisplayingCurrent =
            displayedItemID == itemID

        displayedItemID = itemID
        followsPlaybackContext = true
        followsParagraph = true

        if wasDisplayingCurrent,
           let index =
            runtime.activity
                .currentParagraphIndex
        {
            withAnimation(
                .easeInOut(duration: 0.25)
            ) {
                proxy.scrollTo(
                    index,
                    anchor: .center
                )
            }
        }
    }

    private func selectItem(
        _ itemID: UUID
    ) {
        displayedItemID = itemID
        followsParagraph = true
        followsPlaybackContext =
            runtime.activity.activeItemID
                == nil
                || runtime.activity
                    .activeItemID
                    == itemID
    }

    private func navigateDisplayedItem(
        delta: Int
    ) {
        guard let itemID =
                adjacentDisplayedItemID(
                    delta: delta
                )
        else {
            return
        }
        selectItem(itemID)
    }

    private func adjacentDisplayedItemID(
        delta: Int
    ) -> UUID? {
        guard let displayedItemID,
              let index =
                runtime.itemStates
                    .firstIndex(where: {
                        $0.id
                            == displayedItemID
                    })
        else {
            return nil
        }

        let candidate = index + delta
        guard runtime.itemStates.indices
            .contains(candidate)
        else {
            return nil
        }

        return runtime.itemStates[
            candidate
        ].id
    }

    private func togglePlayback() {
        do {
            guard let displayedItemID else {
                return
            }

            if runtime.isPlaybackActive,
               runtime.activity.activeItemID
                    == displayedItemID {
                if runtime.isPlaybackPaused {
                    runtime.resumePlayback()
                } else {
                    runtime.pausePlayback()
                }
                return
            }

            try runtime.play(
                itemID: displayedItemID
            )
            followsPlaybackContext = true
            followsParagraph = true
        } catch {
            errorMessage =
                Self.message(for: error)
        }
    }

    private func seek(by seconds: Double) {
        do {
            try runtime.seekPlayback(
                by: seconds
            )
            followsPlaybackContext = true
            followsParagraph = true
        } catch {
            errorMessage =
                Self.message(for: error)
        }
    }

    private func generateCurrent(
        regenerate: Bool
    ) {
        guard let displayedItemID
        else {
            return
        }

        Task {
            do {
                try await runtime
                    .enqueueGeneration(
                        itemID:
                            displayedItemID,
                        regenerate: regenerate
                    )
            } catch {
                errorMessage =
                    Self.message(
                        for: error
                    )
            }
        }
    }

    private func clearCurrentAudio() {
        guard let displayedItemID
        else {
            return
        }

        Task {
            do {
                try await runtime
                    .clearGeneratedAudio(
                        itemIDs: [
                            displayedItemID
                        ]
                    )
            } catch {
                errorMessage =
                    Self.message(
                        for: error
                    )
            }
        }
    }

    private func handleNarrationChange() {
        if runtime.activity.activeItemID
            == displayedItemID
        {
            runtime.stopPlayback()
        }
    }

    nonisolated private static func message(
        for error: Error
    ) -> String {
        if let localized = error
            as? LocalizedError,
           let description =
            localized.errorDescription
        {
            return description
        }
        return String(describing: error)
    }
}

private struct ReaderChaptersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let runtime: ProjectRuntime
    let selectedItemID: UUID?
    let onSelect: (UUID) -> Void
    let onError: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredItems) { state in
                    Button {
                        onSelect(state.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(
                                systemName:
                                    chapterStatusIcon(
                                        state
                                    )
                            )
                            .frame(width: 20)
                            .foregroundStyle(
                                .secondary
                            )

                            VStack(
                                alignment: .leading,
                                spacing: 3
                            ) {
                                Text(
                                    state.item.title
                                )
                                .foregroundStyle(
                                    .primary
                                )
                                .lineLimit(2)

                                Text(
                                    chapterStatusLabel(
                                        state
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    .secondary
                                )
                            }

                            Spacer()

                            if state.id
                                == selectedItemID
                            {
                                Image(
                                    systemName:
                                        "checkmark"
                                )
                            }
                        }
                        .padding(
                            .leading,
                            CGFloat(
                                chapterDepth(
                                    state.id
                                )
                            ) * 14
                        )
                    }
                }

                Section {
                    Button {
                        Task {
                            do {
                                try await runtime
                                    .enqueueRemainingGeneration()
                            } catch {
                                onError(
                                    Self.message(
                                        for: error
                                    )
                                )
                            }
                        }
                    } label: {
                        Label(
                            "Generate Remaining",
                            systemImage:
                                "arrow.down.circle"
                        )
                    }
                }
            }
            .searchable(
                text: $searchText,
                prompt: "Search Chapters"
            )
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {
                ToolbarItem(
                    placement:
                        .confirmationAction
                ) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredItems:
        [ProjectRuntimeItemState]
    {
        let query = searchText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .lowercased()

        guard !query.isEmpty else {
            return runtime.itemStates
        }

        return runtime.itemStates.filter {
            $0.item.title
                .lowercased()
                .contains(query)
        }
    }

    private func chapterDepth(
        _ itemID: UUID
    ) -> Int {
        guard let manifest =
                runtime.manifest
        else {
            return 0
        }

        let parentByID = Dictionary(
            uniqueKeysWithValues:
                manifest.items.map {
                    ($0.id, $0.parentID)
                }
        )

        var depth = 0
        var cursor = parentByID[itemID] ?? nil
        var visited = Set<UUID>()

        while let parentID = cursor,
              visited.insert(parentID).inserted {
            depth += 1
            cursor =
                parentByID[parentID]
                ?? nil
        }

        return min(depth, 4)
    }

    private func chapterStatusIcon(
        _ state: ProjectRuntimeItemState
    ) -> String {
        if runtime.activity.activeItemID
            == state.id,
           runtime.isPlaybackActive
        {
            return runtime.isPlaybackPaused
                ? "pause.circle.fill"
                : "play.circle.fill"
        }

        switch state.generationStatus.state {
        case .readyOffline:
            return "checkmark.circle.fill"
        case .generating:
            return "waveform"
        case .waiting:
            return "clock"
        case .notGenerated:
            return "circle"
        case .needsAttention:
            return "exclamationmark.triangle"
        }
    }

    private func chapterStatusLabel(
        _ state: ProjectRuntimeItemState
    ) -> String {
        if runtime.activity.activeItemID
            == state.id,
           runtime.isPlaybackActive
        {
            return runtime.isPlaybackPaused
                ? "Paused"
                : "Playing"
        }

        switch state.generationStatus.state {
        case .readyOffline:
            return "Ready Offline"
        case .generating:
            return "Generating"
        case .waiting:
            return "Waiting"
        case .notGenerated:
            return "Not Generated"
        case .needsAttention:
            return "Needs Attention"
        }
    }

    nonisolated private static func message(
        for error: Error
    ) -> String {
        if let localized = error
            as? LocalizedError,
           let description =
            localized.errorDescription
        {
            return description
        }
        return String(describing: error)
    }
}

private struct ReaderAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double

    var body: some View {
        NavigationStack {
            Form {
                Section("Text Size") {
                    HStack {
                        Text("A")
                            .font(.caption)
                        Slider(
                            value: $fontSize,
                            in: 16...30,
                            step: 1
                        )
                        Text("A")
                            .font(.title2)
                    }

                    Text(
                        fontSize,
                        format:
                            .number.precision(
                                .fractionLength(0)
                            )
                    )
                    .foregroundStyle(.secondary)
                }

                Section("Line Spacing") {
                    Slider(
                        value: $lineSpacing,
                        in: 2...14,
                        step: 1
                    )
                }
            }
            .navigationTitle(
                "Reader Appearance"
            )
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {
                ToolbarItem(
                    placement:
                        .confirmationAction
                ) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ReaderItemInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ProjectRuntimeItemState

    var body: some View {
        NavigationStack {
            List {
                Section("Chapter") {
                    LabeledContent(
                        "Title",
                        value: entry.item.title
                    )
                    LabeledContent(
                        "Order",
                        value:
                            String(
                                entry.item.order
                                    + 1
                            )
                    )
                    LabeledContent(
                        "Characters",
                        value:
                            String(
                                entry.item.text
                                    .count
                            )
                    )
                }

                Section("Narration") {
                    LabeledContent(
                        "Voice",
                        value:
                            ReadAloudNarrationCatalog
                                .voiceName(
                                    entry.resolved
                                        .voiceID
                                )
                    )
                    LabeledContent(
                        "Speed",
                        value:
                            entry.resolved.speed
                                .formatted(
                                    .number
                                        .precision(
                                            .fractionLength(
                                                1
                                            )
                                        )
                                )
                                + "×"
                    )
                }

                Section("Source") {
                    Text(
                        entry.item
                            .sourceLocator.value
                    )
                    .font(.footnote)
                }
            }
            .navigationTitle("Chapter Info")
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {
                ToolbarItem(
                    placement:
                        .confirmationAction
                ) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
