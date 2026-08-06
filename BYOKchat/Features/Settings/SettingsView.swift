import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    NavigationStack {
      Form {
        Section("AI Providers") {
          NavigationLink {
            ProviderListView(model: model.providers)
          } label: {
            Label("Providers & Accounts", systemImage: "key.horizontal")
          }

          NavigationLink {
            ProviderConsoleView(model: model.providers)
          } label: {
            Label("Provider Console", systemImage: "terminal")
          }
        }

        Section("New Chats") {
          NavigationLink {
            DefaultSystemPromptView(preferences: model.preferences)
          } label: {
            LabeledContent("Default System Prompt") {
              Text(model.preferences.defaultSystemPrompt.isEmpty ? "None" : "Configured")
                .foregroundStyle(.secondary)
            }
          }
        }

        Section("About") {
          LabeledContent("Storage", value: "Local on this iPhone")
          LabeledContent("Credentials", value: "Keychain")
          Text("Requests go directly to the provider account selected for each conversation.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Settings")
    }
  }
}

private struct DefaultSystemPromptView: View {
  @Bindable var preferences: AppPreferencesModel
  @State private var text: String

  init(preferences: AppPreferencesModel) {
    self.preferences = preferences
    _text = State(initialValue: preferences.defaultSystemPrompt)
  }

  var body: some View {
    Form {
      Section {
        TextEditor(text: $text)
          .frame(minHeight: 220)
      } footer: {
        Text("This prompt is copied into new conversations. Existing conversations are unchanged.")
      }

      Section {
        Button("Clear", role: .destructive) { text = "" }
      }
    }
    .navigationTitle("Default Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: text) { _, value in preferences.defaultSystemPrompt = value }
  }
}
