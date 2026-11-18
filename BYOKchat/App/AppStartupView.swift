import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AppStartupLoadingView: View {
  var body: some View {
    BYOKBrand.background
      .ignoresSafeArea()
      .preferredColorScheme(.dark)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Starting BYOKchat")
  }
}

struct AppStartupFailureView: View {
  let failure: AppBootstrapFailure
  let restartApp: () -> Void

  @Environment(AppModel.self) private var model
  @State private var recoveryDocument: AppRecoveryPackageDocument?
  @State private var showRecoveryExporter = false
  @State private var showResetConfirmation = false
  @State private var isWorking = false
  @State private var recoveryError: String?

  var body: some View {
    ZStack {
      BYOKBrand.background.ignoresSafeArea()

      ScrollView {
        VStack(spacing: 24) {
          Spacer(minLength: 72)

          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 48, weight: .medium))
            .foregroundStyle(.white)
            .accessibilityHidden(true)

          VStack(spacing: 10) {
            Text(failure.title)
              .font(.system(size: 28, weight: .bold))
              .multilineTextAlignment(.center)
              .foregroundStyle(.white)

            Text(failure.message)
              .font(.system(size: 15))
              .multilineTextAlignment(.center)
              .foregroundStyle(.white.opacity(0.82))
              .frame(maxWidth: 440)

            Text("Your existing local data has not been deleted.")
              .font(.footnote.weight(.medium))
              .multilineTextAlignment(.center)
              .foregroundStyle(.white.opacity(0.72))
          }

          Button {
            restartApp()
          } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(BYOKBrand.background)
              .frame(maxWidth: 320)
              .padding(.vertical, 13)
              .background(.white, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(isWorking)

          VStack(spacing: 0) {
            recoveryButton("Export Recovery Data", systemImage: "square.and.arrow.up") {
              exportRecoveryData()
            }
            Divider().overlay(.white.opacity(0.16))
            recoveryButton("Copy Error Details", systemImage: "doc.on.doc") {
              UIPasteboard.general.string = failure.diagnosticText
            }
            Divider().overlay(.white.opacity(0.16))
            recoveryButton(
              "Start Fresh on This Device",
              systemImage: "trash",
              destructive: true
            ) {
              showResetConfirmation = true
            }
          }
          .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(.white.opacity(0.14), lineWidth: 1)
          }
          .frame(maxWidth: 440)

          Text("Recovery exports never include API keys or MCP credentials stored in Keychain.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.58))
            .frame(maxWidth: 400)

          Spacer(minLength: 44)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
      }

      if isWorking {
        ProgressView()
          .tint(.white)
          .padding(18)
          .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
    }
    .preferredColorScheme(.dark)
    .fileExporter(
      isPresented: $showRecoveryExporter,
      document: recoveryDocument,
      contentType: .package,
      defaultFilename: "BYOKchat-Recovery"
    ) { result in
      recoveryDocument = nil
      if case .failure(let error) = result {
        recoveryError = error.localizedDescription
      }
    }
    .confirmationDialog(
      "Start fresh on this device?",
      isPresented: $showResetConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset Local Data", role: .destructive) {
        resetLocalData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "BYOKchat will make a local recovery backup, then remove chats, connections, projects, tools, and saved credentials from this device."
      )
    }
    .alert(
      "Recovery Action Failed",
      isPresented: Binding(
        get: { recoveryError != nil },
        set: { if !$0 { recoveryError = nil } }
      )
    ) {
      Button("OK") { recoveryError = nil }
    } message: {
      Text(recoveryError ?? "Unknown error")
    }
  }

  private func recoveryButton(
    _ title: String,
    systemImage: String,
    destructive: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .frame(width: 22)
        Text(title)
          .font(.system(size: 15, weight: .medium))
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .opacity(0.55)
      }
      .foregroundStyle(destructive ? Color(red: 1.0, green: 0.76, blue: 0.76) : .white)
      .padding(.horizontal, 16)
      .frame(minHeight: 54)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isWorking)
  }

  private func exportRecoveryData() {
    guard !isWorking else { return }
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      do {
        recoveryDocument = try await AppStorageBootstrap.makeRecoveryDocument(
          failure: failure,
          environment: model.storageEnvironment
        )
        showRecoveryExporter = true
      } catch {
        BYOKAppAnalytics.reportError("data_export_failed", component: "data")
        recoveryError = error.localizedDescription
      }
    }
  }

  private func resetLocalData() {
    guard !isWorking else { return }
    isWorking = true
    Task { @MainActor in
      do {
        try await AppStorageBootstrap.resetLocalData(
          environment: model.storageEnvironment,
          telemetryRecorder: model.telemetryRecorder
        )
        isWorking = false
        restartApp()
      } catch {
        BYOKAppAnalytics.reportError(
          "reset_application_failed", component: "data", severity: .fatal
        )
        isWorking = false
        recoveryError = error.localizedDescription
      }
    }
  }
}
