import AppFoundation
import SwiftUI

/// Adapted from Spokio iOS's synthesis-speed sheet.
/// The slider edits a local draft; saving once avoids repeatedly invalidating
/// Riidrr's generated audio while the user drags between speeds.
@MainActor
struct ReadAloudSpeedPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme

    let initialSpeed: Double?
    let inheritTitle: String?
    let inheritedSpeed: Double?
    let onCommit: @MainActor (Double?) async -> Bool

    @State private var draftSpeed: Double
    @State private var useInherited: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var detent: PresentationDetent = .medium

    init(
        speed: Double?,
        customDraftSpeed: Double? = nil,
        inheritTitle: String? = nil,
        inheritedSpeed: Double? = nil,
        onCommit: @escaping @MainActor (Double?) async -> Bool
    ) {
        self.initialSpeed = speed
        self.inheritTitle = inheritTitle
        self.inheritedSpeed = inheritedSpeed
        self.onCommit = onCommit

        let startingSpeed = speed ?? customDraftSpeed ?? inheritedSpeed ?? 1.0
        _draftSpeed = State(
            initialValue: ReadAloudNarrationCatalog.roundedSpeed(startingSpeed)
        )
        _useInherited = State(initialValue: inheritTitle != nil && speed == nil)
    }

    private var currentValue: Double {
        useInherited
            ? (inheritedSpeed ?? 1.0)
            : draftSpeed
    }

    private var isUnchanged: Bool {
        if useInherited {
            return inheritTitle != nil && initialSpeed == nil
        }
        guard let initialSpeed else { return false }
        return abs(initialSpeed - draftSpeed) < 0.000_001
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                if let inheritTitle {
                    Picker("Use", selection: $useInherited) {
                        Text(inheritTitle).tag(true)
                        Text("Custom").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isSaving)

                    if useInherited {
                        Text("\(inheritTitle) · \(Self.speedLabel(currentValue))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Synthesis speed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.speedLabel(currentValue))
                        .font(
                            .system(.title2, design: .monospaced)
                                .weight(.semibold)
                        )
                        .contentTransition(.numericText())
                }

                HStack(spacing: 12) {
                    stepButton(systemName: "minus", delta: -0.1)
                        .accessibilityHidden(true)

                    Slider(
                        value: $draftSpeed,
                        in: ReadAloudNarrationCatalog.speedRange,
                        step: ReadAloudNarrationCatalog.speedStep
                    )
                    .accessibilityLabel("Synthesis speed")
                    .accessibilityValue(Self.speedLabel(currentValue))

                    stepButton(systemName: "plus", delta: 0.1)
                        .accessibilityHidden(true)
                }
                .disabled(useInherited || isSaving)

                HStack(spacing: 8) {
                    ForEach(ReadAloudNarrationCatalog.speedPresets, id: \.self) { preset in
                        presetButton(preset)
                    }
                }
                .disabled(useInherited || isSaving)

                Text("This changes Kokoro synthesis speed, not a separate playback rate. Changing it makes previously generated audio incompatible until regenerated.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(theme.backgroundColor.ignoresSafeArea())
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                }
            }
            .alert(
                "Speed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unable to save synthesis speed.")
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private func stepButton(systemName: String, delta: Double) -> some View {
        Button {
            draftSpeed = ReadAloudNarrationCatalog.roundedSpeed(draftSpeed + delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .disabled(delta < 0
            ? draftSpeed <= ReadAloudNarrationCatalog.speedRange.lowerBound
            : draftSpeed >= ReadAloudNarrationCatalog.speedRange.upperBound)
    }

    private func presetButton(_ value: Double) -> some View {
        let selected = abs(draftSpeed - value) < 0.01

        return Button {
            draftSpeed = value
        } label: {
            Text(Self.speedLabel(value))
                .font(
                    .system(size: 13, weight: selected ? .semibold : .regular)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? theme.accentColor : Color.primary)
        .background(
            selected ? theme.accentColor.opacity(0.15) : theme.elevatedSurfaceColor,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        guard !isSaving else { return }
        if isUnchanged {
            dismiss()
            return
        }

        isSaving = true
        let selection: Double? = useInherited ? nil : draftSpeed
        Task { @MainActor in
            let saved = await onCommit(selection)
            isSaving = false
            if saved {
                dismiss()
            } else {
                errorMessage = "Unable to save this speed selection."
            }
        }
    }

    static func speedLabel(_ value: Double) -> String {
        value == floor(value)
            ? String(format: "%.0fx", value)
            : String(format: "%.1fx", value)
    }
}
