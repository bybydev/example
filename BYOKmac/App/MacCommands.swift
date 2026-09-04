import SwiftUI

struct MacCommands: Commands {
  let model: MacAppModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Chat") {
        model.requestNewChat()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(!model.isReady)
    }

    CommandMenu("Conversation") {
      Button("Search Conversations") {
        model.requestConversationSearch()
      }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(!model.isReady)

      Divider()

      Button("Stop Generating") {
        Task { await model.stopAllGenerations() }
      }
      .keyboardShortcut(".", modifiers: .command)
      .disabled(model.chats?.activeConversationIDs.isEmpty != false)
    }

    CommandGroup(after: .help) {
      Divider()
      Button("Reveal BYOKchat Data in Finder") {
        model.revealDataDirectory()
      }
      .disabled(!model.isReady)
    }
  }
}
