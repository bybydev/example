import Foundation
import Observation
import PDFKitAudio
import SwiftUI

/// Headless state for an explicitly offered sheet. Constructing it performs no
/// processing; only start() invokes the operation. Tokens reject late callbacks.
@Observable
@MainActor
final class ParsedOutputPreparation: Identifiable {
    enum Phase: Equatable { case offered, processing, failed(String), finished, cancelled }
    let id = UUID()
    let title: String
    private(set) var phase: Phase = .offered
    private(set) var progress = ReadAloudImportProgress(stage: .preparing, fractionCompleted: nil)
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let process: @MainActor (@escaping ParsedOutputProgress) async throws -> Void
    @ObservationIgnored private let retry: ParsedOutputRetry

    init(
        title: String,
        process: @escaping @MainActor (@escaping ParsedOutputProgress) async throws -> Void,
        retry: @escaping ParsedOutputRetry
    ) {
        self.title = title
        self.process = process
        self.retry = retry
    }

    func start() {
        guard task == nil, phase != .finished, phase != .cancelled else { return }
        let token = UUID()
        operationID = token
        progress = ReadAloudImportProgress(stage: .preparing, fractionCompleted: nil)
        phase = .processing
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if operationID == token { task = nil } }
            do {
                try Task.checkCancellation()
                try await process { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.operationID == token, self.phase == .processing else { return }
                        self.progress = value
                    }
                }
                try Task.checkCancellation()
                guard operationID == token else { return }
                // Do not replay the pending action after foregrounding. The
                // cache can finish saving, but listening/generation needs a
                // visible, active app when the requested action resumes.
                if ProjectGenerationExecutionRegistry.shared.isApplicationActive {
                    try await retry()
                }
                try Task.checkCancellation()
                guard operationID == token else { return }
                phase = .finished
            } catch is CancellationError {
                if operationID == token { phase = .cancelled }
            } catch {
                if operationID == token { phase = .failed(ProjectRuntime.message(for: error)) }
            }
        }
    }

    func cancel() {
        guard phase != .finished, phase != .cancelled else { return }
        operationID = nil
        task?.cancel()
        phase = .cancelled
    }

    // Retained for orderly teardown/tests; cancellation does not block dismissal.
    func waitForCompletion() async { await task?.value }
}

private struct ParsedOutputPreparationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preparation: ParsedOutputPreparation

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "text.book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                Text(preparation.title).font(.headline)
                switch preparation.phase {
                case .offered:
                    Text("Prepared reading data is missing or unavailable. Process this book’s saved source to continue with your requested action. Your saved text will stay available.")
                        .foregroundStyle(.secondary)
                    Button("Start Processing") { preparation.start() }
                        .buttonStyle(.borderedProminent)
                case .processing:
                    Text(stageLabel).foregroundStyle(.secondary)
                    if let fraction = preparation.progress.fractionCompleted {
                        ProgressView(value: fraction)
                        Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit())
                    } else {
                        ProgressView()
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                    Button("Try Again") { preparation.start() }
                        .buttonStyle(.borderedProminent)
                case .finished, .cancelled:
                    EmptyView()
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .readAloudThemeSurface()
            .navigationTitle("Prepare Book Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(preparation.phase == .processing ? "Cancel" : "Not Now") {
                        preparation.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: preparation.phase) { _, phase in
            if phase == .finished || phase == .cancelled { dismiss() }
        }
        .onDisappear { preparation.cancel() }
    }

    private var stageLabel: String {
        switch preparation.progress.stage {
        case .preparing: "Preparing saved source…"
        case .extracting: "Processing content…"
        case .normalizing: "Preparing reading options…"
        case .persisting: "Saving prepared content…"
        case .finished: "Ready"
        }
    }
}

/// Registers a visible presenter only. Appearance, loading and scene changes
/// cannot create a request. The deepest modal/screen handles its own user action.
private struct ParsedOutputPreparationPresenter: ViewModifier {
    @Environment(ProjectRuntimeManager.self) private var manager
    @State private var presenterID = UUID()
    @State private var preparation: ParsedOutputPreparation?
    let priority: Int

    func body(content: Content) -> some View {
        content
            .sheet(item: $preparation) { request in
                ParsedOutputPreparationSheet(preparation: request)
            }
            .onAppear {
                manager.registerPreparationPresenter(id: presenterID, priority: priority) { runtime, retry in
                    guard preparation == nil else { return false }
                    preparation = ParsedOutputPreparation(
                        title: runtime.project?.title ?? "Book",
                        process: { progress in try await runtime.prepareParsedOutputFromUser(progress: progress) },
                        retry: retry
                    )
                    return true
                }
            }
            .onDisappear {
                manager.unregisterPreparationPresenter(id: presenterID)
                preparation?.cancel()
                preparation = nil
            }
    }
}

extension View {
    func parsedOutputPreparationPresenter(priority: Int) -> some View {
        modifier(ParsedOutputPreparationPresenter(priority: priority))
    }
}

/// Listening policy is kept per PDF project and immediately recomputed from
/// cached typed blocks without reparsing or rewriting saved chapter text.
struct PDFListeningOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let runtime: ProjectRuntime

    @State private var draft: PdfReadingPolicy
    @State private var isSaving = false
    @State private var localError: String?

    init(runtime: ProjectRuntime) {
        self.runtime = runtime
        _draft = State(initialValue: runtime.pdfReadingPolicy)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Include in Reading") {
                    Toggle("Footnotes", isOn: option(\.includesFootnotes))
                    Toggle("Captions", isOn: option(\.includesCaptions))
                    Toggle("Tables", isOn: option(\.includesTables))
                    Toggle(
                        "Confirmed Headers and Footers",
                        isOn: option(\.includesRunningMatter)
                    )
                }
                .disabled(isSaving)
                Section {
                    Text(
                        "Confirmed page numbers and running matter are skipped by default. " +
                        "Uncertain content remains readable. Changing filters does not " +
                        "extract or OCR the PDF again."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Button("Reset to Listening Defaults") {
                        apply(.listening)
                    }
                    .disabled(draft == .listening || isSaving)
                }
            }
            .navigationTitle("Listening Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .parsedOutputPreparationPresenter(priority: 4)
        .interactiveDismissDisabled(isSaving)
        .alert(
            "Listening Options Error",
            isPresented: Binding(
                get: { localError != nil },
                set: { if !$0 { localError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "")
        }
        .onChange(of: runtime.pdfReadingPolicy) { _, value in
            if !isSaving {
                draft = value
            }
        }
    }

    private func option(
        _ keyPath: WritableKeyPath<PdfReadingPolicy, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                var updated = draft
                updated[keyPath: keyPath] = value
                apply(updated)
            }
        )
    }

    private func apply(_ policy: PdfReadingPolicy) {
        guard !isSaving else { return }
        guard policy != draft else { return }

        draft = policy
        isSaving = true
        Task {
            do {
                try await runtime.applyPDFReadingPolicy(policy)
                // An offered preparation leaves the policy unchanged. Only a
                // successful explicit Start/retry applies the pending choice.
                draft = runtime.pdfReadingPolicy
            } catch {
                draft = runtime.pdfReadingPolicy
                localError = ProjectRuntime.message(for: error)
            }
            isSaving = false
        }
    }
}
