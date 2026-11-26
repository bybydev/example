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

      Divider()

      Button("Larger Text") {
        model.preferences.increaseTranscriptFontSize()
      }
      .keyboardShortcut("+", modifiers: .command)
      .disabled(!model.isReady || !model.preferences.canIncreaseTranscriptFontSize)

      Button("Smaller Text") {
        model.preferences.decreaseTranscriptFontSize()
      }
      .keyboardShortcut("-", modifiers: .command)
      .disabled(!model.isReady || !model.preferences.canDecreaseTranscriptFontSize)

      Button("Actual Size") {
        model.preferences.resetTranscriptFontSize()
      }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(
        !model.isReady
          || model.preferences.transcriptFontSize == MacPreferencesModel.defaultTranscriptFontSize
      )
    }

    CommandMenu("Conversation") {
      Button("Search Conversations") {
        model.requestConversationSearch()
      }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(!model.isReady)

      Divider()

      Button("Find in Conversation…") {
        model.requestInChatFind()
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(!model.isReady)

      Button("Find Next") {
        model.requestInChatFindNext()
      }
      .keyboardShortcut("g", modifiers: .command)
      .disabled(!model.isReady)

      Button("Find Previous") {
        model.requestInChatFindPrevious()
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])
      .disabled(!model.isReady)

      Divider()

      Button("Previous Chat") {
        model.requestPreviousChat()
      }
      .keyboardShortcut(.upArrow, modifiers: [.command, .option])
      .disabled(!model.isReady)

      Button("Next Chat") {
        model.requestNextChat()
      }
      .keyboardShortcut(.downArrow, modifiers: [.command, .option])
      .disabled(!model.isReady)

      Divider()

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
