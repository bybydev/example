import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct TelemetryDiagnosticsView: View {
  @State private var statistics = TelemetryStoreStatistics.empty
  @State private var health = TelemetryRecorderHealth(
    isAvailable: true,
    consecutiveFailureCount: 0,
    lastFailureDescription: nil,
    lastFailureAt: nil
  )
  @State private var isWorking = false
  @State private var confirmClearDiagnostics = false
  @State private var confirmClearAll = false
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme

  private let configuration = TelemetryStoreConfiguration.default
  private var recorder: TelemetryRecorder { model.telemetryRecorder }

  var body: some View {
    List {
      Section {
        NavigationLink {
          TelemetryLogsView()
        } label: {
          Label("Event Log", systemImage: "list.bullet.rectangle")
        }
      } header: {
        Text("Logs")
          .foregroundStyle(theme.secondaryForegroundColor)
      } footer: {
        Text("Shows the latest local analytics and diagnostic lifecycle events. Event payloads are sanitized before storage.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      Section("Health") {
        LabeledContent("Recorder", value: health.isAvailable ? "Available" : "Disabled for this session")
        if health.consecutiveFailureCount > 0 {
          LabeledContent("Recent failures", value: health.consecutiveFailureCount.formatted())
        }
        if let date = health.lastFailureAt {
          LabeledContent("Last failure") {
            Text(date, format: .dateTime.month().day().hour().minute().second())
              .multilineTextAlignment(.trailing)
          }
        }
        if !health.isAvailable {
          Button("Retry Telemetry", systemImage: "arrow.clockwise") {
            Task { await retryTelemetry() }
          }
          .disabled(isWorking)
        }
      }
      .listRowBackground(theme.surfaceColor)

      Section("Storage") {
        LabeledContent("Events", value: statistics.eventCount.formatted())
        LabeledContent("Analytics", value: statistics.analyticsEventCount.formatted())
        LabeledContent("Diagnostic", value: statistics.diagnosticEventCount.formatted())
        LabeledContent(
          "Database",
          value: ByteCountFormatter.string(fromByteCount: statistics.databaseBytes, countStyle: .file)
        )
        LabeledContent("Schema", value: statistics.schemaVersion.formatted())
        if let oldest = statistics.oldestEventAt {
          LabeledContent("Oldest") {
            Text(oldest, format: .dateTime.month().day().hour().minute())
              .multilineTextAlignment(.trailing)
          }
        }
        if let newest = statistics.newestEventAt {
          LabeledContent("Newest") {
            Text(newest, format: .dateTime.month().day().hour().minute())
              .multilineTextAlignment(.trailing)
          }
        }
      }
      .listRowBackground(theme.surfaceColor)

      Section {
        LabeledContent("Maximum age", value: retentionDays)
        LabeledContent("Maximum events", value: configuration.maximumEventCount.formatted())
        LabeledContent(
          "Maximum size",
          value: ByteCountFormatter.string(
            fromByteCount: configuration.maximumDatabaseBytes,
            countStyle: .file
          )
        )

        Button("Run Cleanup", systemImage: "sparkles") {
          Task { await runMaintenance() }
        }
        .disabled(isWorking)
      } header: {
        Text("Retention")
          .foregroundStyle(theme.secondaryForegroundColor)
      } footer: {
        Text("Oldest telemetry is removed automatically when any retention cap is reached. Usage and cost stored with chat messages are unaffected.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)

      Section {
        Button("Clear Diagnostic Logs", systemImage: "eraser") {
          confirmClearDiagnostics = true
        }
        .disabled(isWorking || statistics.diagnosticEventCount == 0)

        Button("Clear All Telemetry", systemImage: "trash", role: .destructive) {
          confirmClearAll = true
        }
        .disabled(isWorking || statistics.eventCount == 0)
      } header: {
        Text("Clear")
          .foregroundStyle(theme.secondaryForegroundColor)
      } footer: {
        Text("Clearing telemetry never deletes conversations, billing metadata, API credentials, projects, or provider configuration.")
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .task { await reload() }
    .refreshable { await reload() }
    .confirmationDialog(
      "Clear diagnostic logs?",
      isPresented: $confirmClearDiagnostics,
      titleVisibility: .visible
    ) {
      Button("Clear Diagnostic Logs", role: .destructive) {
        Task { await clearDiagnostics() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Analytics events are preserved.")
    }
    .confirmationDialog(
      "Clear all telemetry?",
      isPresented: $confirmClearAll,
      titleVisibility: .visible
    ) {
      Button("Clear All Telemetry", role: .destructive) {
        Task { await clearAll() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The telemetry database will be recreated empty. Historical chat usage and spend remain available from conversations.")
    }
  }

  private var retentionDays: String {
    let days = Int(configuration.maximumAge / (24 * 60 * 60))
    return "\(days) days"
  }

  @MainActor
  private func reload() async {
    statistics = await recorder.statistics()
    health = await recorder.health()
  }

  @MainActor
  private func retryTelemetry() async {
    isWorking = true
    await recorder.retryAfterFailure()
    await recorder.performMaintenance()
    isWorking = false
    await reload()
  }

  @MainActor
  private func runMaintenance() async {
    isWorking = true
    await recorder.performMaintenance()
    isWorking = false
    await reload()
  }

  @MainActor
  private func clearDiagnostics() async {
    isWorking = true
    await recorder.clearDiagnosticLogs()
    isWorking = false
    await reload()
  }

  @MainActor
  private func clearAll() async {
    isWorking = true
    await recorder.clearAllTelemetry()
    isWorking = false
    await reload()
  }
}
