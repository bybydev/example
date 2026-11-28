import AppKit
import SwiftUI

struct MacStartupView: View {
  let model: MacAppModel

  @State private var confirmStartFresh = false
  @State private var copiedDiagnostics = false
  @State private var copyFeedbackTask: Task<Void, Never>?

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
    .background(MacDesignTokens.Colors.canvas, ignoresSafeAreaEdges: .all)
    .onDisappear {
      copyFeedbackTask?.cancel()
      copyFeedbackTask = nil
    }
  }

  private func loadingView(stage: MacStartupStage) -> some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text("BYOK Chat")
        .font(.title2.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      Text(stage.rawValue)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
    .padding(40)
  }

  private func failureView(failure: MacStartupFailure) -> some View {
    ScrollView {
      VStack(spacing: 18) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 34))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        VStack(spacing: 6) {
          Text(failure.title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Text(failure.stage.rawValue)
            .font(.callout)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Text(failure.message)
            .multilineTextAlignment(.center)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .textSelection(.enabled)
        }
        .frame(maxWidth: 520)

        HStack(spacing: 10) {
          Button("Try Again") {
            Task { await model.retryStartup() }
          }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)

          Button("Show Data in Finder") {
            model.revealDataDirectory()
          }
          .buttonStyle(MacActionButtonStyle(.secondary))

          Button(copiedDiagnostics ? "Copied Diagnostics" : "Copy Diagnostics") {
            copyDiagnostics(failure.diagnosticText)
          }
          .buttonStyle(MacActionButtonStyle(.secondary))

          Button("Start Fresh, Keep Backup") {
            confirmStartFresh = true
          }
          .buttonStyle(MacActionButtonStyle(.destructive))
        }

        if model.lastRecoveryBackupURL != nil {
          Button("Show Recovery Backup", systemImage: "clock.arrow.circlepath") {
            model.revealRecoveryBackup()
          }
          .buttonStyle(MacActionButtonStyle(.secondary))
        }

        DisclosureGroup("Technical Details") {
          Text(failure.diagnosticText)
            .font(.caption.monospaced())
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .textSelection(.enabled)
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.top, 8)
        }
        .frame(maxWidth: 600)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 56)
      .padding(.horizontal, 40)
      .padding(.bottom, 40)
    }
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
    copiedDiagnostics = true
    copyFeedbackTask?.cancel()
    copyFeedbackTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      copiedDiagnostics = false
    }
  }
}
