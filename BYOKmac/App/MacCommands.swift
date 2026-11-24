import AppKit
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

    CommandGroup(replacing: .sidebar) {
      Button("Toggle Sidebar") {
        model.requestSidebarToggle()
      }
      .keyboardShortcut("s", modifiers: [.command, .control])
      .disabled(!model.isReady)

      Button("Toggle Full Screen") {
        NSApp.keyWindow?.toggleFullScreen(nil)
      }
      .keyboardShortcut("f", modifiers: [.command, .control])
    }

    CommandMenu("Conversation") {
      Button("Search Conversations") {
        model.requestConversationSearch()
      }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(!model.isReady)

      Button("Export Conversation as Markdown…") {
        model.requestExportMarkdown()
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(!model.isReady || model.chats?.conversationSummaries.isEmpty != false)

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
