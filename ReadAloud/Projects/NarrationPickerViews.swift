import AppFoundation
import SwiftUI

struct ProjectVoicePicker: View {
    let model: ProjectDetailModel
    let onChanged: () -> Void

    var body: some View {
        ReadAloudVoicesPickerView(
            selectedVoiceID: model.project?.settings.voiceID,
            inheritTitle: "App Default",
            inheritDetail: ReadAloudNarrationCatalog.voiceName(
                ReadAloudAccessPolicy.effectiveVoiceID(
                    ReadAloudNarrationCatalog.appDefaultVoiceID,
                    hasPro: model.runtime.hasPro
                )
            )
        ) { voiceID in
            let changed = await model.setProjectVoice(voiceID)
            if changed { onChanged() }
            return changed
        }
    }
}

struct ProjectSpeedPicker: View {
    let model: ProjectDetailModel
    let onChanged: () -> Void

    var body: some View {
        ReadAloudSpeedPickerView(
            speed: model.project?.settings.speed,
            inheritTitle: "App Default",
            inheritedSpeed: ReadAloudNarrationCatalog.appDefaultSpeed
        ) { speed in
            let changed = await model.setProjectSpeed(speed)
            if changed { onChanged() }
            return changed
        }
    }
}

struct ItemVoicePicker: View {
    let model: ProjectDetailModel
    let itemID: UUID
    let onChanged: () -> Void

    var body: some View {
        if let entry = model.itemEntry(itemID) {
            ReadAloudVoicesPickerView(
                selectedVoiceID: entry.item.settings.voice.mode == .inherit
                    ? nil : entry.item.settings.voice.customValue,
                inheritTitle: "Project Default",
                inheritDetail: ReadAloudNarrationCatalog.voiceName(
                    model.resolvedProjectSettings.voiceID
                )
            ) { voiceID in
                let changed: Bool
                if let voiceID {
                    changed = await model.setItemVoice(
                        itemID: itemID, voiceID: voiceID
                    )
                } else {
                    changed = await model.setItemVoiceMode(
                        itemID: itemID, mode: .inherit
                    )
                }
                if changed { onChanged() }
                return changed
            }
        } else {
            ContentUnavailableView(
                "Chapter Unavailable",
                systemImage: "exclamationmark.triangle"
            )
        }
    }
}

struct ItemSpeedPicker: View {
    let model: ProjectDetailModel
    let itemID: UUID
    let onChanged: () -> Void

    var body: some View {
        if let entry = model.itemEntry(itemID) {
            ReadAloudSpeedPickerView(
                speed: entry.item.settings.speed.mode == .custom
                    ? entry.item.settings.speed.customValue : nil,
                customDraftSpeed: entry.item.settings.speed.customValue,
                inheritTitle: "Project Default",
                inheritedSpeed: model.resolvedProjectSettings.speed
            ) { speed in
                let changed: Bool
                if let speed {
                    changed = await model.setItemSpeed(itemID: itemID, speed: speed)
                } else {
                    changed = await model.setItemSpeedMode(itemID: itemID, mode: .inherit)
                }
                if changed { onChanged() }
                return changed
            }
        } else {
            ContentUnavailableView(
                "Chapter Unavailable",
                systemImage: "exclamationmark.triangle"
            )
        }
    }
}
