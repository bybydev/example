import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("ReadAloud", systemImage: "book.pages") {
                NavigationStack {
                    ContentUnavailableView(
                        "ReadAloud",
                        systemImage: "book.pages",
                        description: Text("The 1.0 product experience is being built on the new project architecture.")
                    )
                    .navigationTitle("ReadAloud")
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }
}
