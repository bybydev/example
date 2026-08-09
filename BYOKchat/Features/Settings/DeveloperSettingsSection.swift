import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct TelemetrySettingsSection: View {
  var body: some View {
    Section {
      NavigationLink {
        TelemetryDiagnosticsView()
      } label: {
        Label("Diagnostics & Logs", systemImage: "waveform.path.ecg")
      }
    } header: {
      Text("Diagnostics")
    } footer: {
      Text("Telemetry stays on this device, is bounded and disposable, and never contains prompts, responses, credentials, or tool payloads by default.")
    }
  }
}

#if DEBUG
struct DeveloperSettingsSection: View {
  let purchases: BYOKPurchaseStore
  let replayOnboarding: () -> Void

  @State private var simulatedPurchasesEnabled = false

  var body: some View {
    Section("Developer") {
      Toggle(
        "Simulated Purchases",
        isOn: Binding(
          get: { simulatedPurchasesEnabled },
          set: { enabled in
            simulatedPurchasesEnabled = enabled
            Task { @MainActor in
              await purchases.setSimulatedPurchasesEnabled(enabled)
            }
          }
        )
      )
      .disabled(purchases.manager.isBusy)

      Button("Replay Onboarding", systemImage: "rectangle.portrait.and.arrow.forward") {
        replayOnboarding()
      }
    }
    .onAppear {
      simulatedPurchasesEnabled = purchases.isUsingSimulatedPurchases
    }
  }
}
#endif
