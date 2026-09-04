import SwiftUI

@main
struct BYOKmacApp: App {
  @State private var model = MacAppModel()

  var body: some Scene {
    WindowGroup("BYOKchat", id: "main") {
      MacStartupView(model: model)
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(model.theme.preferredColorScheme)
        .tint(MacDesignTokens.Colors.accent)
        .environment(\.macThemeRevision, model.theme.revision)
        .task {
          await model.start()
        }
    }
    .defaultSize(width: 1_180, height: 760)
    .windowResizability(.contentMinSize)
    .commands {
      SidebarCommands()
      MacCommands(model: model)
    }

    Settings {
      MacSettingsView(model: model)
    }
  }
}
