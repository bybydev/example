import SwiftUI

struct ProjectVoicePicker: View {
    @Environment(\.dismiss) private var dismiss
    let model: ProjectDetailModel
    let onChanged: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Project Voice") {
                    selectionRow(
                        title: "App Default",
                        detail: ReadAloudNarrationCatalog.voiceName(
                            ReadAloudNarrationCatalog.appDefaultVoiceID
                        ),
                        selected: model.project?.settings.voiceID == nil
                    ) {
                        update(nil)
                    }

                    ForEach(ReadAloudNarrationCatalog.voices) { voice in
                        selectionRow(
                            title: voice.name,
                            detail: nil,
                            selected:
                                model.project?.settings.voiceID == voice.id
                        ) {
                            update(voice.id)
                        }
                    }
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionRow(
        title: String,
        detail: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func update(_ voiceID: String?) {
        Task {
            if await model.setProjectVoice(voiceID) {
                onChanged()
            }
        }
    }
}

struct ProjectSpeedPicker: View {
    @Environment(\.dismiss) private var dismiss
    let model: ProjectDetailModel
    let onChanged: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Narration Speed") {
                    speedRow(
                        title: "App Default",
                        speed: ReadAloudNarrationCatalog.appDefaultSpeed,
                        selected: model.project?.settings.speed == nil
                    ) {
                        update(nil)
                    }

                    ForEach(
                        ReadAloudNarrationCatalog.synthesisSpeeds,
                        id: \.self
                    ) { speed in
                        speedRow(
                            title: speedLabel(speed),
                            speed: nil,
                            selected: model.project?.settings.speed == speed
                        ) {
                            update(speed)
                        }
                    }
                }

                Section {
                    Text("This is synthesis speed. Changing it makes existing generated audio incompatible until it is regenerated.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Narration Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func speedRow(
        title: String,
        speed: Double?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let speed {
                        Text(speedLabel(speed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func update(_ speed: Double?) {
        Task {
            if await model.setProjectSpeed(speed) {
                onChanged()
            }
        }
    }

    private func speedLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}

struct ItemVoicePicker: View {
    @Environment(\.dismiss) private var dismiss
    let model: ProjectDetailModel
    let itemID: UUID
    let onChanged: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let entry = model.itemEntry(itemID) {
                    Section("Use") {
                        selectionRow(
                            title: "Project Default",
                            detail: ReadAloudNarrationCatalog.voiceName(
                                model.resolvedProjectSettings.voiceID
                            ),
                            selected: entry.item.settings.voice.mode == .inherit
                        ) {
                            setMode(.inherit)
                        }

                        let remembered =
                            entry.item.settings.voice.customValue
                                ?? entry.resolved.voiceID
                        selectionRow(
                            title: "Custom",
                            detail:
                                ReadAloudNarrationCatalog.voiceName(remembered),
                            selected: entry.item.settings.voice.mode == .custom
                        ) {
                            setMode(.custom)
                        }
                    }

                    Section("Custom Voice") {
                        ForEach(ReadAloudNarrationCatalog.voices) { voice in
                            selectionRow(
                                title: voice.name,
                                detail: nil,
                                selected:
                                    entry.item.settings.voice.mode == .custom
                                    && entry.item.settings.voice.customValue
                                        == voice.id
                            ) {
                                setVoice(voice.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionRow(
        title: String,
        detail: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func setMode(_ mode: ItemSettingMode) {
        Task {
            if await model.setItemVoiceMode(
                itemID: itemID,
                mode: mode
            ) {
                onChanged()
            }
        }
    }

    private func setVoice(_ voiceID: String) {
        Task {
            if await model.setItemVoice(
                itemID: itemID,
                voiceID: voiceID
            ) {
                onChanged()
            }
        }
    }
}

struct ItemSpeedPicker: View {
    @Environment(\.dismiss) private var dismiss
    let model: ProjectDetailModel
    let itemID: UUID
    let onChanged: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let entry = model.itemEntry(itemID) {
                    Section("Use") {
                        selectionRow(
                            title: "Project Default",
                            detail: speedLabel(
                                model.resolvedProjectSettings.speed
                            ),
                            selected: entry.item.settings.speed.mode == .inherit
                        ) {
                            setMode(.inherit)
                        }

                        let remembered =
                            entry.item.settings.speed.customValue
                                ?? entry.resolved.speed
                        selectionRow(
                            title: "Custom",
                            detail: speedLabel(remembered),
                            selected: entry.item.settings.speed.mode == .custom
                        ) {
                            setMode(.custom)
                        }
                    }

                    Section("Custom Speed") {
                        ForEach(
                            ReadAloudNarrationCatalog.synthesisSpeeds,
                            id: \.self
                        ) { speed in
                            selectionRow(
                                title: speedLabel(speed),
                                detail: nil,
                                selected:
                                    entry.item.settings.speed.mode == .custom
                                    && entry.item.settings.speed.customValue
                                        == speed
                            ) {
                                setSpeed(speed)
                            }
                        }
                    }

                    Section {
                        Text("This changes Kokoro synthesis speed, not a separate playback-rate control.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Narration Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionRow(
        title: String,
        detail: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func setMode(_ mode: ItemSettingMode) {
        Task {
            if await model.setItemSpeedMode(
                itemID: itemID,
                mode: mode
            ) {
                onChanged()
            }
        }
    }

    private func setSpeed(_ speed: Double) {
        Task {
            if await model.setItemSpeed(
                itemID: itemID,
                speed: speed
            ) {
                onChanged()
            }
        }
    }

    private func speedLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}
