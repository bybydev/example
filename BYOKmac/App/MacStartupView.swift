import AppKit
import SwiftUI

struct MacStartupView: View {
  let model: MacAppModel

  @State private var confirmStartFresh = false

  var body: some View {
    Group {
      switch model.startupState {
      case .idle:
        loadingView(stage: .preparingStorage)
      case .loading(let stage):
        loadingView(stage: stage)
      case .ready:
        MacSecondarySurfacesView(model: model)
      case .failed(let failure):
        failureView(failure: failure)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func loadingView(stage: MacStartupStage) -> some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text("BYOKchat")
        .font(.title2.weight(.semibold))
      Text(stage.rawValue)
        .foregroundStyle(.secondary)
    }
    .padding(40)
  }

  private func failureView(failure: MacStartupFailure) -> some View {
    VStack(spacing: 18) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)

      VStack(spacing: 6) {
        Text(failure.title)
          .font(.title2.weight(.semibold))
        Text(failure.stage.rawValue)
          .font(.callout)
          .foregroundStyle(.secondary)
        Text(failure.message)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .frame(maxWidth: 520)

      HStack(spacing: 10) {
        Button("Try Again") {
          Task { await model.retryStartup() }
        }
        .keyboardShortcut(.defaultAction)

        Button("Show Data in Finder") {
          model.revealDataDirectory()
        }

        Button("Copy Diagnostics") {
          copyDiagnostics(failure.diagnosticText)
        }

        Button("Start Fresh, Keep Backup") {
          confirmStartFresh = true
        }
      }

      if model.lastRecoveryBackupURL != nil {
        Button("Show Recovery Backup", systemImage: "clock.arrow.circlepath") {
          model.revealRecoveryBackup()
        }
      }

      DisclosureGroup("Technical Details") {
        Text(failure.diagnosticText)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: 600, alignment: .leading)
          .padding(.top, 8)
      }
      .frame(maxWidth: 600)
    }
    .padding(40)
    .confirmationDialog(
      "Start with a fresh workspace?",
      isPresented: $confirmStartFresh,
      titleVisibility: .visible
    ) {
      Button("Start Fresh and Keep Backup", role: .destructive) {
        Task { await model.startFreshKeepingBackup() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The current workspace is moved to a recovery folder rather than deleted. Keychain credentials and telemetry are left untouched by startup recovery.")
    }
  }

  private func copyDiagnostics(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
