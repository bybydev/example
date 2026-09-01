import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UniformTypeIdentifiers

struct TelemetryLogsView: View {
  @State private var events: [TelemetryEvent] = []
  @State private var filter = TelemetryLogFilter()
  @State private var showFilters = false
  @State private var exportDocument: JSONExportDocument?
  @State private var showExporter = false
  @State private var exportError: String?
  @State private var hasLoaded = false
  @Environment(AppModel.self) private var model
  @Environment(\.appFoundationTheme) private var theme

  private var recorder: TelemetryRecorder { model.telemetryRecorder }

  private var filteredEvents: [TelemetryEvent] {
    TelemetryDiagnostics.filtered(events: events, filter: filter)
  }

  var body: some View {
    List {
      if hasLoaded, filteredEvents.isEmpty {
        ContentUnavailableView(
          events.isEmpty ? "No Telemetry Yet" : "No Matching Events",
          systemImage: events.isEmpty ? "waveform.path.ecg" : "line.3.horizontal.decrease.circle",
          description: Text(
            events.isEmpty
              ? "Lifecycle events will appear here after you use providers, tools, or MCP."
              : "Change or clear the filters to show more events."
          )
        )
        .listRowBackground(theme.surfaceColor)
      } else {
        ForEach(filteredEvents) { event in
          NavigationLink {
            TelemetryLogDetailView(event: event)
          } label: {
            TelemetryLogRow(event: event)
          }
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Event Log")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $filter.searchText, prompt: "Search events")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("Filter", systemImage: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
          showFilters = true
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(activeFilterCount > 0 ? "Filter, \(activeFilterCount) active" : "Filter")

        Button("Export", systemImage: "square.and.arrow.up") {
          prepareExport()
        }
        .labelStyle(.iconOnly)
        .disabled(filteredEvents.isEmpty)
      }
    }
    .task { await loadEvents() }
    .refreshable { await loadEvents() }
    .sheet(isPresented: $showFilters) {
      TelemetryLogFilterView(
        filter: $filter,
        providerIDs: providerIDs,
        modelIDs: modelIDs,
        conversationIDs: conversationIDs
      )
      .presentationDragIndicator(.visible)
    }
    .fileExporter(
      isPresented: $showExporter,
      document: exportDocument,
      contentType: .json,
      defaultFilename: "BYOK-diagnostics"
    ) { result in
      if case .failure(let error) = result {
        exportError = error.localizedDescription
      }
    }
    .alert(
      "Export Failed",
      isPresented: Binding(
        get: { exportError != nil },
        set: { if !$0 { exportError = nil } }
      )
    ) {
      Button("OK") { exportError = nil }
    } message: {
      Text(exportError ?? "Unknown error")
    }
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

  private var providerIDs: [String] {
    Set(events.compactMap { $0.providerID?.rawValue }).sorted()
  }

  private var modelIDs: [String] {
    Set(events.compactMap { $0.modelID?.rawValue }).sorted()
  }

  private var conversationIDs: [String] {
    Set(events.compactMap { $0.conversationID?.rawValue }).sorted()
  }

  @MainActor
  private func loadEvents() async {
    events = await recorder.recentEvents(
      limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )
    hasLoaded = true
  }

  private func prepareExport() {
    do {
      let data = try TelemetryDiagnostics.exportJSON(events: filteredEvents)
      exportDocument = JSONExportDocument(data: data)
      showExporter = true
    } catch {
      exportError = error.localizedDescription
    }
  }
}

private struct TelemetryLogRow: View {
  let event: TelemetryEvent

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: severityIcon)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(theme.secondaryForegroundColor)
        .frame(width: 20, height: 22)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          Text(eventTitle(event.name.rawValue))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(event.timestamp, format: .dateTime.hour().minute().second())
            .font(.caption.monospacedDigit())
            .foregroundStyle(theme.secondaryForegroundColor)
        }

        Text(contextLine)
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)

        if let errorCode = event.errorCode {
          Text(errorCode.replacingOccurrences(of: "_", with: " "))
            .font(.caption2.monospaced())
            .foregroundStyle(theme.secondaryForegroundColor)
            .lineLimit(1)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var severityIcon: String {
    switch event.severity {
    case .debug: "ladybug"
    case .info: "info.circle"
    case .notice: "bell"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.octagon"
    }
  }

  private var contextLine: String {
    var parts = [event.category.rawValue.capitalized]
    if let provider = event.providerID?.rawValue { parts.append(provider) }
    if let model = event.modelID?.rawValue { parts.append(model) }
    if let outcome = event.outcome?.rawValue { parts.append(outcome) }
    return parts.joined(separator: " · ")
  }
}

private struct TelemetryLogFilterView: View {
  @Binding var filter: TelemetryLogFilter
  let providerIDs: [String]
  let modelIDs: [String]
  let conversationIDs: [String]

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    NavigationStack {
      Form {
        Section("Event") {
          Picker("Data", selection: dataClassSelection) {
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
        .listRowBackground(theme.surfaceColor)

        if !providerIDs.isEmpty {
          Section("Provider") {
            Picker("Provider", selection: providerSelection) {
              Text("All").tag("")
              ForEach(providerIDs, id: \.self) { value in
                Text(value).tag(value)
              }
            }
          }
          .listRowBackground(theme.surfaceColor)
        }

        if !modelIDs.isEmpty {
          Section("Model") {
            Picker("Model", selection: modelSelection) {
              Text("All").tag("")
              ForEach(modelIDs, id: \.self) { value in
                Text(value).tag(value)
              }
            }
          }
          .listRowBackground(theme.surfaceColor)
        }

        if !conversationIDs.isEmpty {
          Section("Chat") {
            Picker("Conversation", selection: conversationSelection) {
              Text("All").tag("")
              ForEach(conversationIDs, id: \.self) { value in
                Text(shortIdentifier(value)).tag(value)
              }
            }
          }
          .listRowBackground(theme.surfaceColor)
        }

        if hasStructuredFilters {
          Section {
            Button("Clear Filters", systemImage: "xmark.circle", role: .destructive) {
              let search = filter.searchText
              filter = TelemetryLogFilter(searchText: search)
            }
          }
          .listRowBackground(theme.surfaceColor)
        }
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("Filters")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var hasStructuredFilters: Bool {
    filter.dataClass != nil
      || filter.category != nil
      || filter.severity != nil
      || filter.providerID != nil
      || filter.modelID != nil
      || filter.conversationID != nil
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
    if value.count <= 18 { return value }
    return String(value.prefix(8)) + "…" + String(value.suffix(6))
  }
}

private func eventTitle(_ rawValue: String) -> String {
  rawValue
    .replacingOccurrences(of: ".", with: " ")
    .replacingOccurrences(of: "_", with: " ")
    .capitalized
}
