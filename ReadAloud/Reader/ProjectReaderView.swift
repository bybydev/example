import AppFoundation
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
        .readAloudThemeSurface()
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
                let loaded = try await runtimeManager.activate(
                    projectID: projectID
                )
                try Task.checkCancellation()
                runtime = loaded
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
    @Environment(PurchaseManager.self) private var purchases
    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var displayedItemID: UUID?
    @State private var followsPlaybackContext = true
    @State private var followsParagraph = true
    @State private var chaptersPresented = false
    @State private var appearancePresented = false
    @State private var listeningOptionsPresented = false
    @State private var infoPresented = false
    @State private var offlineGenerationUpsellPresented = false
    @State private var errorMessage: String?

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
        .readAloudThemeSurface()
        .parsedOutputPreparationPresenter(priority: 3)
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
                if needsListeningAction, let displayedItemID {
                    Button {
                        do {
                            guard try runtime.listen(itemID: displayedItemID) else { return }
                            followPlayer()
                        } catch {
                            errorMessage = Self.message(for: error)
                        }
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .accessibilityLabel("Listen to this chapter")
                    .disabled(runtime.isApplyingPDFReadingPolicy)
                }

                Button {
                    chaptersPresented = true
                } label: {
                    Image(
                        systemName: "list.bullet"
                    )
                }
                .accessibilityLabel("Chapters")

                if runtime.project?.source.type == .pdf {
                    Button {
                        listeningOptionsPresented = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Listening Options")
                }

                moreMenu
            }
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
            isPresented: $listeningOptionsPresented
        ) {
            PDFListeningOptionsSheet(runtime: runtime)
        }
        .sheet(isPresented: $offlineGenerationUpsellPresented) {
            ReadAloudProUpsell(reason: .offlineGeneration)
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
        .onChange(of: runtimeManager.readerFollowRevision) { _, _ in
            if runtimeManager.playerRuntime === runtime { followPlayer() }
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
                        highlightedText(paragraph, itemID: state.id)
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
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    listenFromHere(
                                        paragraph,
                                        itemID: state.id,
                                        proxy: proxy
                                    )
                                } label: {
                                    Label(
                                        "Listen from Here",
                                        systemImage: "play.circle.fill"
                                    )
                                }
                            }
                            .accessibilityAction(
                                named: Text("Listen from Here")
                            ) {
                                listenFromHere(
                                    paragraph,
                                    itemID: state.id,
                                    proxy: proxy
                                )
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

                if reduceMotion {
                    proxy.scrollTo(
                        index,
                        anchor: .center
                    )
                } else {
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
                        ReadAloudOfflineGenerateLabel(
                            title: "Generate Current",
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

    private var needsListeningAction: Bool {
        runtimeManager.playerRuntime !== runtime
            || runtime.playerControlItemID() != displayedItemID
            || runtime.isPlayerDismissed
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

    /// Highlight the actual audible source chunk within the layout paragraph.
    /// This does not depend on which chunk ONNX is generating ahead.
    private func highlightedText(
        _ paragraph: ReaderParagraph,
        itemID: UUID
    ) -> Text {
        guard runtime.isPlaybackActive,
              runtime.activity.activeItemID == itemID,
              let range = runtime.activity.currentChunkRange else {
            return Text(paragraph.text)
        }
        let start = max(range.startUTF16, paragraph.sourceRange.startUTF16)
        let end = min(range.endUTF16, paragraph.sourceRange.endUTF16)
        guard end > start else { return Text(paragraph.text) }

        let ns = paragraph.text as NSString
        let localStart = start - paragraph.sourceRange.startUTF16
        let localEnd = end - paragraph.sourceRange.startUTF16
        guard localStart >= 0, localEnd <= ns.length else {
            return Text(paragraph.text)
        }
        let prefix = ns.substring(to: localStart)
        let current = ns.substring(with: NSRange(
            location: localStart, length: localEnd - localStart
        ))
        let suffix = ns.substring(from: localEnd)
        return Text(prefix)
            + Text(current).foregroundColor(.accentColor)
            + Text(suffix)
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

    private func followPlayer() {
        if let itemID = runtime.playerControlItemID(fallback: displayedItemID) {
            displayedItemID = itemID
        }
        followsPlaybackContext = true
        followsParagraph = true
    }

    private func listenFromHere(
        _ paragraph: ReaderParagraph,
        itemID: UUID,
        proxy: ScrollViewProxy
    ) {
        do {
            // The source range is derived from the original chapter text,
            // not the trimmed display string or a fabricated audio time.
            try runtime.playFromUser(
                itemID: itemID,
                fromOffsetUTF16: paragraph.sourceRange.startUTF16
            )
            displayedItemID = itemID
            followsPlaybackContext = true
            followsParagraph = true

            if reduceMotion {
                proxy.scrollTo(paragraph.id, anchor: .center)
            } else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(paragraph.id, anchor: .center)
                }
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func seek(by seconds: Double) {
        do {
            try runtime.seekPlayback(
                by: seconds
            )
            followPlayer()
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

        if !regenerate {
            guard ReadAloudOfflineGenerationGate.allowsRequest(
                purchases: purchases, isUpsellPresented: $offlineGenerationUpsellPresented
            ) else { return }
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
    @Environment(PurchaseManager.self) private var purchases
    @State private var searchText = ""
    @State private var offlineGenerationUpsellPresented = false

    let runtime: ProjectRuntime
    let selectedItemID: UUID?
    let onSelect: (UUID) -> Void
    let onError: (String) -> Void

    var body: some View {
        NavigationStack {
            ReadAloudThemedList {
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
                        guard ReadAloudOfflineGenerationGate.allowsRequest(
                            purchases: purchases, isUpsellPresented: $offlineGenerationUpsellPresented
                        ) else { return }
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
                        ReadAloudOfflineGenerateLabel(
                            title: "Generate Remaining",
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
            .readAloudThemeSurface()
            .parsedOutputPreparationPresenter(priority: 4)
            .navigationTitle("Chapters")
            .sheet(isPresented: $offlineGenerationUpsellPresented) {
                ReadAloudProUpsell(reason: .offlineGeneration)
            }
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
            .readAloudThemeSurface()
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
            ReadAloudThemedList {
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
            .readAloudThemeSurface()
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


