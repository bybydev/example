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
      .disabled(!model.isReady || !model.canExportActiveConversation)

      Divider()

      Button("Stop Generating") {
        Task { await model.stopAllGenerations() }
      }
      .keyboardShortcut(".", modifiers: .command)
      .disabled(model.chats?.activeConversationIDs.isEmpty != false)
    }

    CommandGroup(after: .help) {
      Divider()
      Button("BYOKchat Website") {
        NSWorkspace.shared.open(MacPurchaseStore.websiteURL)
      }
      Button("Contact Support") {
        NSWorkspace.shared.open(MacPurchaseStore.contactURL)
      }
      Button("Privacy Policy") {
        NSWorkspace.shared.open(MacPurchaseStore.privacyURL)
      }
      Button("Terms of Use") {
        NSWorkspace.shared.open(MacPurchaseStore.termsURL)
      }
      Divider()
      Button("Reveal BYOKchat Data in Finder") {
        model.revealDataDirectory()
      }
    }
  }
}
