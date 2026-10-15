import Foundation
import PDFKitAudio
import SwiftUI

/// Listening policy is kept per PDF project and immediately recomputed from
/// the in-memory typed PdfBook, just like the PDFKitAudio iOS demo.
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
            } catch {
                draft = runtime.pdfReadingPolicy
                localError = ProjectRuntime.message(for: error)
            }
            isSaving = false
        }
    }
}
