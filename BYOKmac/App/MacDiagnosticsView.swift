import AppKit
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct MacDiagnosticsView: View {
  @Bindable var diagnostics: MacDiagnosticsModel

  @State private var showingLogs = false
  @State private var confirmClearDiagnostics = false
  @State private var confirmClearAll = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        GroupBox("Event Log") {
          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Local analytics and diagnostic lifecycle events")
              Text("Stored payloads are privacy-sanitized before they reach the telemetry database.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Spacer()
            Button("Open Event Log…", systemImage: "list.bullet.rectangle") {
              showingLogs = true
            }
          }
          .padding(8)
        }

        GroupBox("Health") {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Recorder", value: diagnostics.health.isAvailable ? "Available" : "Disabled for this session")
            if diagnostics.health.consecutiveFailureCount > 0 {
              LabeledContent("Recent failures", value: diagnostics.health.consecutiveFailureCount.formatted())
            }
            if let date = diagnostics.health.lastFailureAt {
              LabeledContent("Last failure", value: date.formatted(date: .abbreviated, time: .standard))
            }
            if let description = diagnostics.health.lastFailureDescription, !description.isEmpty {
              DisclosureGroup("Last failure details") {
                Text(description)
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
                  .padding(.top, 5)
              }
            }
            if !diagnostics.health.isAvailable {
              Button("Retry Telemetry", systemImage: "arrow.clockwise") {
                Task { await diagnostics.retryTelemetry() }
              }
              .disabled(diagnostics.isBusy)
            }
          }
          .padding(8)
        }

        GroupBox("Storage") {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Events", value: diagnostics.statistics.eventCount.formatted())
            LabeledContent("Analytics", value: diagnostics.statistics.analyticsEventCount.formatted())
            LabeledContent("Diagnostic", value: diagnostics.statistics.diagnosticEventCount.formatted())
            LabeledContent(
              "Database",
              value: ByteCountFormatter.string(fromByteCount: diagnostics.statistics.databaseBytes, countStyle: .file)
            )
            LabeledContent("Schema", value: diagnostics.statistics.schemaVersion.formatted())
            if let oldest = diagnostics.statistics.oldestEventAt {
              LabeledContent("Oldest", value: oldest.formatted(date: .abbreviated, time: .shortened))
            }
            if let newest = diagnostics.statistics.newestEventAt {
              LabeledContent("Newest", value: newest.formatted(date: .abbreviated, time: .shortened))
            }
          }
          .padding(8)
        }

        GroupBox("Retention") {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Maximum age", value: "\(diagnostics.retentionDays) days")
            LabeledContent("Maximum events", value: diagnostics.maximumEventCount.formatted())
            LabeledContent(
              "Maximum size",
              value: ByteCountFormatter.string(fromByteCount: diagnostics.maximumDatabaseBytes, countStyle: .file)
            )
            Button("Run Cleanup", systemImage: "sparkles") {
              Task { await diagnostics.runMaintenance() }
            }
            .disabled(diagnostics.isBusy)
            Text("Cleanup removes oldest telemetry when retention caps are reached. Usage and cost stored in conversations are unaffected.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .padding(8)
        }

        GroupBox("Clear Telemetry") {
          VStack(alignment: .leading, spacing: 10) {
            Button("Clear Diagnostic Logs", systemImage: "eraser") {
              confirmClearDiagnostics = true
            }
            .disabled(diagnostics.isBusy || diagnostics.statistics.diagnosticEventCount == 0)

            Button("Clear All Telemetry", systemImage: "trash", role: .destructive) {
              confirmClearAll = true
            }
            .disabled(diagnostics.isBusy || diagnostics.statistics.eventCount == 0)

            Text("Clearing telemetry never deletes conversations, usage/billing metadata, credentials, projects, Library items, or provider configuration.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .padding(8)
        }
      }
      .padding(20)
      .frame(maxWidth: 720, alignment: .leading)
    }
    .background(MacDesignTokens.Colors.canvas)
    .task { await diagnostics.load() }
    .sheet(isPresented: $showingLogs) {
      MacTelemetryLogsView(diagnostics: diagnostics)
    }
    .confirmationDialog(
      "Clear diagnostic logs?",
      isPresented: $confirmClearDiagnostics,
      titleVisibility: .visible
    ) {
      Button("Clear Diagnostic Logs", role: .destructive) {
        Task { await diagnostics.clearDiagnosticLogs() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Analytics telemetry is preserved.")
    }
    .confirmationDialog(
      "Clear all telemetry?",
      isPresented: $confirmClearAll,
      titleVisibility: .visible
    ) {
      Button("Clear All Telemetry", role: .destructive) {
        Task { await diagnostics.clearAllTelemetry() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The telemetry database is recreated empty. Historical chat usage and spend remain stored with conversations.")
    }
    .alert(
      "Diagnostics Error",
      isPresented: Binding(
        get: { diagnostics.errorMessage != nil },
        set: { if !$0 { diagnostics.errorMessage = nil } }
      )
    ) {
      Button("OK") { diagnostics.errorMessage = nil }
    } message: {
      Text(diagnostics.errorMessage ?? "Unknown error")
    }
  }
}

private struct MacTelemetryLogsView: View {
  @Bindable var diagnostics: MacDiagnosticsModel

  @Environment(\.dismiss) private var dismiss
  @State private var filter = TelemetryLogFilter()
  @State private var showingFilters = false
  @State private var selectedEvent: TelemetryEvent?

  private var filteredEvents: [TelemetryEvent] {
    diagnostics.filteredEvents(filter)
  }

  private var activeFilterCount: Int {
    var count = 0
    if filter.dataClass != nil { count += 1 }
    if filter.category != nil { count += 1 }
    if filter.severity != nil { count += 1 }
    if filter.providerID != nil { count += 1 }
    if filter.modelID != nil { count += 1 }
    if filter.conversationID != nil { count += 1 }
    return count
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Search events", text: $filter.searchText)
            .textFieldStyle(.plain)
          if !filter.searchText.isEmpty {
            Button {
              filter.searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))

        Button(activeFilterCount == 0 ? "Filter" : "Filter · \(activeFilterCount)", systemImage: "line.3.horizontal.decrease.circle") {
          showingFilters = true
        }

        Button("Export", systemImage: "square.and.arrow.up") {
          exportFilteredEvents()
        }
        .disabled(filteredEvents.isEmpty)

        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await diagnostics.load() }
        }

        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(12)

      Divider()

      if filteredEvents.isEmpty {
        ContentUnavailableView(
          diagnostics.events.isEmpty ? "No Telemetry Yet" : "No Matching Events",
          systemImage: diagnostics.events.isEmpty ? "waveform.path.ecg" : "line.3.horizontal.decrease.circle",
          description: Text(diagnostics.events.isEmpty ? "Lifecycle events appear here after you use providers, tools, or MCP." : "Change or clear the filters to show more events.")
        )
      } else {
        Table(filteredEvents) {
          TableColumn("Time") { event in
            Text(event.timestamp.formatted(date: .omitted, time: .standard))
              .font(.caption.monospacedDigit())
          }
          .width(min: 90, ideal: 105)

          TableColumn("Event") { event in
            Button {
              selectedEvent = event
            } label: {
              Text(eventTitle(event.name.rawValue))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
          }
          .width(min: 180, ideal: 280)

          TableColumn("Category") { event in
            Text(event.category.rawValue.capitalized)
          }
          .width(min: 80, ideal: 100)

          TableColumn("Severity") { event in
            Label(event.severity.rawValue.capitalized, systemImage: severityIcon(event.severity))
              .labelStyle(.titleAndIcon)
          }
          .width(min: 90, ideal: 110)

          TableColumn("Context") { event in
            Text(contextLine(event))
              .lineLimit(1)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .width(min: 180, ideal: 280)
        }
      }
    }
    .frame(width: 960, height: 640)
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingFilters) {
      MacTelemetryFilterView(filter: $filter, events: diagnostics.events)
    }
    .sheet(item: $selectedEvent) { event in
      MacTelemetryEventDetailView(event: event)
    }
  }

  private func exportFilteredEvents() {
    guard let bytes = diagnostics.exportData(events: filteredEvents) else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "BYOK-diagnostics-\(Self.fileDate).json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try bytes.write(to: url, options: .atomic)
    } catch {
      MacAppAnalytics.reportError("diagnostics_write_failed", component: "diagnostics")
      diagnostics.errorMessage = error.localizedDescription
    }
  }

  private static var fileDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: .now)
  }
}

private struct MacTelemetryFilterView: View {
  @Binding var filter: TelemetryLogFilter
  let events: [TelemetryEvent]

  @Environment(\.dismiss) private var dismiss

  private var providerIDs: [String] {
    Set(events.compactMap { $0.providerID?.rawValue }).sorted()
  }

  private var modelIDs: [String] {
    Set(events.compactMap { $0.modelID?.rawValue }).sorted()
  }

  private var conversationIDs: [String] {
    Set(events.compactMap { $0.conversationID?.rawValue }).sorted()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Telemetry Filters")
          .font(.headline)
        Spacer()
        Button("Clear") {
          let search = filter.searchText
          filter = TelemetryLogFilter(searchText: search)
        }
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)

      Divider()

      Form {
        Section("Event") {
          Picker("Data class", selection: dataClassSelection) {
            Text("All").tag("")
            ForEach(TelemetryDataClass.allCases, id: \.rawValue) { value in
              Text(value.rawValue.capitalized).tag(value.rawValue)
            }
          }
          Picker("Category", selection: categorySelection) {
            Text("All").tag("")
            ForEach(TelemetryCategory.allCases, id: \.rawValue) { value in
              Text(value.rawValue.capitalized).tag(value.rawValue)
            }
          }
          Picker("Severity", selection: severitySelection) {
            Text("All").tag("")
            ForEach(TelemetrySeverity.allCases, id: \.rawValue) { value in
              Text(value.rawValue.capitalized).tag(value.rawValue)
            }
          }
        }

        if !providerIDs.isEmpty {
          Section("Provider") {
            Picker("Provider", selection: providerSelection) {
              Text("All").tag("")
              ForEach(providerIDs, id: \.self) { Text($0).tag($0) }
            }
          }
        }

        if !modelIDs.isEmpty {
          Section("Model") {
            Picker("Model", selection: modelSelection) {
              Text("All").tag("")
              ForEach(modelIDs, id: \.self) { Text($0).tag($0) }
            }
          }
        }

        if !conversationIDs.isEmpty {
          Section("Conversation") {
            Picker("Conversation", selection: conversationSelection) {
              Text("All").tag("")
              ForEach(conversationIDs, id: \.self) { value in
                Text(shortIdentifier(value)).tag(value)
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      .padding(10)
    }
    .frame(width: 520, height: 520)
    .background(MacDesignTokens.Colors.canvas)
  }

  private var dataClassSelection: Binding<String> {
    Binding(
      get: { filter.dataClass?.rawValue ?? "" },
      set: { filter.dataClass = $0.isEmpty ? nil : TelemetryDataClass(rawValue: $0) }
    )
  }

  private var categorySelection: Binding<String> {
    Binding(
      get: { filter.category?.rawValue ?? "" },
      set: { filter.category = $0.isEmpty ? nil : TelemetryCategory(rawValue: $0) }
    )
  }

  private var severitySelection: Binding<String> {
    Binding(
      get: { filter.severity?.rawValue ?? "" },
      set: { filter.severity = $0.isEmpty ? nil : TelemetrySeverity(rawValue: $0) }
    )
  }

  private var providerSelection: Binding<String> {
    Binding(
      get: { filter.providerID?.rawValue ?? "" },
      set: { filter.providerID = $0.isEmpty ? nil : ProviderID(rawValue: $0) }
    )
  }

  private var modelSelection: Binding<String> {
    Binding(
      get: { filter.modelID?.rawValue ?? "" },
      set: { filter.modelID = $0.isEmpty ? nil : ModelID(rawValue: $0) }
    )
  }

  private var conversationSelection: Binding<String> {
    Binding(
      get: { filter.conversationID?.rawValue ?? "" },
      set: { filter.conversationID = $0.isEmpty ? nil : ConversationID(rawValue: $0) }
    )
  }

  private func shortIdentifier(_ value: String) -> String {
    guard value.count > 18 else { return value }
    return String(value.prefix(8)) + "…" + String(value.suffix(6))
  }
}

private struct MacTelemetryEventDetailView: View {
  let event: TelemetryEvent

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(eventTitle(event.name.rawValue))
          .font(.headline)
        Spacer()
        Button("Copy JSON") { copyJSON() }
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      Divider()

      Form {
        Section("Event") {
          LabeledContent("Timestamp", value: event.timestamp.formatted(date: .abbreviated, time: .standard))
          LabeledContent("Data class", value: event.dataClass.rawValue.capitalized)
          LabeledContent("Category", value: event.category.rawValue.capitalized)
          LabeledContent("Severity", value: event.severity.rawValue.capitalized)
          if let outcome = event.outcome {
            LabeledContent("Outcome", value: outcome.rawValue.capitalized)
          }
          LabeledContent("ID", value: event.id)
            .textSelection(.enabled)
        }

        if event.providerID != nil || event.accountID != nil || event.modelID != nil {
          Section("Provider") {
            if let value = event.providerID { LabeledContent("Provider", value: value.rawValue) }
            if let value = event.accountID { LabeledContent("Account", value: value.rawValue) }
            if let value = event.modelID { LabeledContent("Model", value: value.rawValue) }
          }
        }

        if event.conversationID != nil || event.messageID != nil {
          Section("Chat") {
            if let value = event.conversationID { LabeledContent("Conversation", value: value.rawValue).textSelection(.enabled) }
            if let value = event.messageID { LabeledContent("Message", value: value.rawValue).textSelection(.enabled) }
          }
        }

        if event.durationMilliseconds != nil || event.timeToFirstTokenMilliseconds != nil || event.httpStatus != nil {
          Section("Timing & HTTP") {
            if let value = event.durationMilliseconds { LabeledContent("Duration", value: "\(value.formatted(.number.precision(.fractionLength(1)))) ms") }
            if let value = event.timeToFirstTokenMilliseconds { LabeledContent("First token", value: "\(value.formatted(.number.precision(.fractionLength(1)))) ms") }
            if let value = event.httpStatus { LabeledContent("HTTP status", value: value.formatted()) }
          }
        }

        if event.inputTokens != nil || event.outputTokens != nil || event.cachedInputTokens != nil || event.reasoningTokens != nil {
          Section("Tokens") {
            if let value = event.inputTokens { LabeledContent("Input", value: value.formatted()) }
            if let value = event.outputTokens { LabeledContent("Output", value: value.formatted()) }
            if let value = event.cachedInputTokens { LabeledContent("Cached input", value: value.formatted()) }
            if let value = event.reasoningTokens { LabeledContent("Reasoning", value: value.formatted()) }
          }
        }

        if let errorCode = event.errorCode {
          Section("Error") {
            LabeledContent("Code", value: errorCode)
          }
        }

        if !event.metadata.isEmpty {
          Section("Sanitized Metadata") {
            ForEach(event.metadata.keys.sorted(), id: \.self) { key in
              LabeledContent(key, value: event.metadata[key] ?? "")
                .textSelection(.enabled)
            }
          }
        }
      }
      .formStyle(.grouped)
      .padding(10)
    }
    .frame(width: 620, height: 640)
    .background(MacDesignTokens.Colors.canvas)
  }

  private func copyJSON() {
    guard let bytes = try? TelemetryDiagnostics.exportJSON(events: [event]),
      let value = String(data: bytes, encoding: .utf8)
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

private func eventTitle(_ rawValue: String) -> String {
  rawValue
    .replacingOccurrences(of: ".", with: " ")
    .replacingOccurrences(of: "_", with: " ")
    .capitalized
}

private func severityIcon(_ severity: TelemetrySeverity) -> String {
  switch severity {
  case .debug: "ladybug"
  case .info: "info.circle"
  case .notice: "bell"
  case .warning: "exclamationmark.triangle"
  case .error: "xmark.octagon"
  }
}

private func contextLine(_ event: TelemetryEvent) -> String {
  var parts: [String] = []
  if let provider = event.providerID?.rawValue { parts.append(provider) }
  if let model = event.modelID?.rawValue { parts.append(model) }
  if let outcome = event.outcome?.rawValue { parts.append(outcome) }
  if let error = event.errorCode { parts.append(error) }
  return parts.isEmpty ? "—" : parts.joined(separator: " · ")
}
