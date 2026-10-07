import SwiftUI

struct ProjectStorageUsageSection: View {
    let storage: ProjectStorageBreakdown

    var body: some View {
        Section("Usage") {
            row(
                "Total",
                storage.totalBytes
            )
            row(
                "Source",
                storage.sourceBytes
            )
            row(
                "Generated Audio",
                storage.generatedAudioBytes
            )
            row(
                "Temporary Cache",
                storage.temporaryCacheBytes
            )
            row(
                "Artwork",
                storage.artworkBytes
            )
            row(
                "Project Data",
                storage.projectDataBytes
            )

            if storage.workingBytes > 0 {
                row(
                    "Working Data",
                    storage.workingBytes
                )
            }
        }
    }

    private func row(
        _ title: String,
        _ bytes: Int64
    ) -> some View {
        LabeledContent(
            title,
            value:
                ReadAloudDisplay.byteCount(
                    bytes
                )
        )
    }
}
