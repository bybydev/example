import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack {
                    LibraryView()
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerSlot()
        }
    }
}

/// Phase 3 reserves the global placement for the persistent player without
/// introducing a second playback state before ProjectRuntime exists.
private struct MiniPlayerSlot: View {
    var body: some View {
        EmptyView()
    }
}
