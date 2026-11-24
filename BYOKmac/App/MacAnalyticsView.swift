import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation
import SwiftUI

private struct MacAnalyticsOverviewComputation: Sendable {
  let snapshot: UsageAnalyticsSnapshot
  let budgetSnapshot: UsageAnalyticsSnapshot
  let conversationUsageByID: [ConversationID: ConversationUsageBreakdown]
}

private struct MacAnalyticsConversationComputation: Sendable {
  let snapshot: ConversationUsageAnalyticsSnapshot
  let contextUsage: ConversationContextUsage?
}

@MainActor
@Observable
final class MacAnalyticsModel {
  private(set) var conversations: [ChatConversation] = []
  private(set) var accounts: [ProviderAccount] = []
  private(set) var modelsByAccount: [ProviderAccountID: [AccountModelRecord]] = [:]

  private(set) var telemetryEvents: [TelemetryEvent] = []
  private(set) var dailyRollups: [TelemetryDailyRollup] = []
  private(set) var dailyErrorRollups: [TelemetryDailyErrorRollup] = []
  private(set) var statistics = TelemetryStoreStatistics.empty
  private(set) var overviewSnapshot = UsageAnalyticsSnapshot(
    aggregate: ChatUsageAggregate(),
    performance: TelemetryPerformanceAggregate(),
    failureBreakdown: [],
    providerBreakdown: [],
    modelBreakdown: []
  )
  private(set) var budgetSnapshot = UsageAnalyticsSnapshot(
    aggregate: ChatUsageAggregate(),
    performance: TelemetryPerformanceAggregate(),
    failureBreakdown: [],
    providerBreakdown: [],
    modelBreakdown: []
  )
  private(set) var overviewConversationUsageByID: [ConversationID: ConversationUsageBreakdown] = [:]
  private(set) var overviewTelemetryUnavailable = false
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var isClearingTelemetry = false
  private(set) var loadedRange: UsageAnalyticsRange = .today

  private(set) var selectedConversationSnapshot = ConversationUsageAnalyticsSnapshot(
    aggregate: ChatUsageAggregate(),
    performance: TelemetryPerformanceAggregate()
  )
  private(set) var selectedConversationContextUsage: ConversationContextUsage?
  private(set) var selectedConversationTelemetryEvents: [TelemetryEvent] = []
  private(set) var selectedConversationIDLoaded: ConversationID?
  private(set) var conversationTelemetryUnavailable = false
  private(set) var isLoadingConversation = false
  private(set) var hasLoadedConversation = false

  @ObservationIgnored private var overviewLoadGeneration = 0
  @ObservationIgnored private var conversationLoadGeneration = 0

  private let services: BYOKCoreServices

  init(services: BYOKCoreServices) {
    self.services = services
  }

  func load(
    range: UsageAnalyticsRange = .today,
    hasPro: Bool = true,
    retry: Bool = false,
    reference: Date = .now
  ) async {
    overviewLoadGeneration &+= 1
    let generation = overviewLoadGeneration
    let effectiveRange = range.accessible(hasPro: hasPro)
    let budgetRange = UsageAnalyticsRange.month.accessible(hasPro: hasPro)

    isLoading = true
    defer {
      if generation == overviewLoadGeneration {
        isLoading = false
      }
    }

    if retry {
      await services.telemetryRecorder.retryAfterFailure()
    }

    async let conversationsTask = services.conversationStore.allConversations()
    async let workspaceSnapshotTask = services.providerWorkspace.snapshot()
    async let analyticsLoadTask = services.telemetryRecorder.loadAnalytics(
      range: effectiveRange,
      reference: reference,
      limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )

    let loadedConversations = await conversationsTask.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt { return lhs.id.rawValue > rhs.id.rawValue }
      return lhs.updatedAt > rhs.updatedAt
    }
    let workspaceSnapshot = await workspaceSnapshotTask
    let analyticsLoadResult = await analyticsLoadTask

    guard !Task.isCancelled, generation == overviewLoadGeneration else { return }

    let loadedEvents: [TelemetryEvent]
    let loadedRollups: [TelemetryDailyRollup]
    let loadedErrorRollups: [TelemetryDailyErrorRollup]
    let loadedStatistics: TelemetryStoreStatistics
    let unavailable: Bool

    switch analyticsLoadResult {
    case .loaded(let events, let rollups, let errorRollups, let stats):
      loadedEvents = events
      loadedRollups = rollups
      loadedErrorRollups = errorRollups
      loadedStatistics = stats
      unavailable = false
    case .unavailable:
      loadedEvents = []
      loadedRollups = []
      loadedErrorRollups = []
      loadedStatistics = .empty
      unavailable = true
    }

    let computed = await Task.detached(priority: .userInitiated) {
      let snapshot = UsageAnalytics.snapshot(
        conversations: loadedConversations,
        telemetryEvents: loadedEvents,
        dailyRollups: loadedRollups,
        dailyErrorRollups: loadedErrorRollups,
        range: effectiveRange,
        reference: reference
      )
      let budget: UsageAnalyticsSnapshot
      if budgetRange == effectiveRange {
        budget = snapshot
      } else {
        budget = UsageAnalytics.snapshot(
          conversations: loadedConversations,
          telemetryEvents: [],
          range: budgetRange,
          reference: reference
        )
      }
      let usageByID = Dictionary(
        uniqueKeysWithValues: snapshot.conversationBreakdown.map { ($0.id, $0) }
      )
      return MacAnalyticsOverviewComputation(
        snapshot: snapshot,
        budgetSnapshot: budget,
        conversationUsageByID: usageByID
      )
    }.value

    guard !Task.isCancelled, generation == overviewLoadGeneration else { return }

    conversations = loadedConversations
    accounts = workspaceSnapshot.accounts
    modelsByAccount = Dictionary(grouping: workspaceSnapshot.modelRecords, by: \.accountID)
    telemetryEvents = loadedEvents
    dailyRollups = loadedRollups
    dailyErrorRollups = loadedErrorRollups
    statistics = loadedStatistics
    overviewTelemetryUnavailable = unavailable
    overviewSnapshot = computed.snapshot
    budgetSnapshot = computed.budgetSnapshot
    overviewConversationUsageByID = computed.conversationUsageByID
    loadedRange = effectiveRange
    hasLoaded = true
  }

  func loadConversation(
    _ conversation: ChatConversation,
    range: UsageAnalyticsRange = .all,
    retry: Bool = false,
    reference: Date = .now
  ) async {
    conversationLoadGeneration &+= 1
    let generation = conversationLoadGeneration

    if selectedConversationIDLoaded != conversation.id {
      hasLoadedConversation = false
    }
    isLoadingConversation = true
    defer {
      if generation == conversationLoadGeneration {
        isLoadingConversation = false
      }
    }

    if retry {
      await services.telemetryRecorder.retryAfterFailure()
    }

    let scopedResult = await services.telemetryRecorder.loadConversationAnalytics(
      conversationID: conversation.id,
      limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
    )

    guard !Task.isCancelled, generation == conversationLoadGeneration else { return }

    let scopedEvents: [TelemetryEvent]
    let unavailable: Bool
    switch scopedResult {
    case .loaded(let events):
      scopedEvents = events
      unavailable = false
    case .unavailable:
      scopedEvents = []
      unavailable = true
    }

    let accountsSnapshot = accounts
    let modelsSnapshot = modelsByAccount

    let computed = await Task.detached(priority: .userInitiated) {
      let snapshot = UsageAnalytics.conversationSnapshot(
        conversation: conversation,
        telemetryEvents: scopedEvents,
        range: range,
        reference: reference
      )
      let contextUsage = macConversationContextUsage(
        conversation: conversation,
        telemetryEvents: scopedEvents,
        accounts: accountsSnapshot,
        modelsByAccount: modelsSnapshot
      )
      return MacAnalyticsConversationComputation(
        snapshot: snapshot,
        contextUsage: contextUsage
      )
    }.value

    guard !Task.isCancelled, generation == conversationLoadGeneration else { return }

    selectedConversationTelemetryEvents = scopedEvents
    conversationTelemetryUnavailable = unavailable
    selectedConversationSnapshot = computed.snapshot
    selectedConversationContextUsage = computed.contextUsage
    selectedConversationIDLoaded = conversation.id
    hasLoadedConversation = true
  }

  func clearSelectionState() {
    conversationLoadGeneration &+= 1
    selectedConversationIDLoaded = nil
    selectedConversationTelemetryEvents = []
    selectedConversationContextUsage = nil
    selectedConversationSnapshot = ConversationUsageAnalyticsSnapshot(
      aggregate: ChatUsageAggregate(),
      performance: TelemetryPerformanceAggregate()
    )
    conversationTelemetryUnavailable = false
    isLoadingConversation = false
    hasLoadedConversation = false
  }

  func clearTelemetry(range: UsageAnalyticsRange, hasPro: Bool) async {
    guard !isClearingTelemetry else { return }
    isClearingTelemetry = true
    defer { isClearingTelemetry = false }
    await services.telemetryRecorder.clearAllTelemetry()
    await load(range: range, hasPro: hasPro, retry: true)
  }

  func overviewAggregate(for conversationID: ConversationID) -> ChatUsageAggregate {
    overviewConversationUsageByID[conversationID]?.aggregate ?? ChatUsageAggregate()
  }
}

enum MacAnalyticsWorkspaceSection: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case conversations = "Conversations"

  var id: String { rawValue }
}

struct MacAnalyticsView: View {
  @State private var analytics: MacAnalyticsModel
  @State private var range: UsageAnalyticsRange = .today
  @State private var section: MacAnalyticsWorkspaceSection
  @State private var selectedConversationID: String?
  @State private var conversationSearchText = ""
  @State private var confirmClearTelemetry = false
  @AppStorage("byokchat.usage.monthlyBudgetUSD") private var monthlyBudgetUSD = 0.0
  @AppStorage("byokchat.usage.budgetWarningFraction") private var budgetWarningFraction = 0.8

  @Environment(PurchaseManager.self) private var purchaseManager

  private struct OverviewReloadKey: Equatable {
    let range: UsageAnalyticsRange
    let hasPro: Bool
  }

  private struct ConversationLoadKey: Equatable {
    let conversationID: String?
    let hasLoaded: Bool
    let updatedAt: Date?
  }

  /// Every overview aggregate uses this range, including stale selections after downgrade.
  private var accessibleRange: UsageAnalyticsRange {
    range.accessible(hasPro: purchaseManager.hasPro)
  }

  private var overviewReloadKey: OverviewReloadKey {
    OverviewReloadKey(range: accessibleRange, hasPro: purchaseManager.hasPro)
  }

  private var conversationLoadKey: ConversationLoadKey {
    ConversationLoadKey(
      conversationID: selectedConversationID,
      hasLoaded: analytics.hasLoaded,
      updatedAt: selectedConversation?.updatedAt
    )
  }

  init(services: BYOKCoreServices, initialConversationID: ConversationID? = nil) {
    _analytics = State(initialValue: MacAnalyticsModel(services: services))
    if let initialConversationID {
      _section = State(initialValue: .conversations)
      _selectedConversationID = State(initialValue: initialConversationID.rawValue)
    } else {
      _section = State(initialValue: .overview)
      _selectedConversationID = State(initialValue: nil)
    }
  }

  private var selectedConversation: ChatConversation? {
    guard let selectedConversationID else { return nil }
    return analytics.conversations.first { $0.id.rawValue == selectedConversationID }
  }

  private var filteredConversations: [ChatConversation] {
    let query = conversationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return analytics.conversations }
    return analytics.conversations.filter { conversation in
      let title = conversation.title.isEmpty ? "New Chat" : conversation.title
      return title.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      workspaceControls
      Divider()

      if analytics.isLoading && !analytics.hasLoaded {
        loadingView
      } else if let conversation = selectedConversation {
        conversationDetail(conversation)
      } else {
        switch section {
        case .overview:
          overview
        case .conversations:
          conversations
        }
      }
    }
    .frame(minWidth: 920, minHeight: 620)
    .background(MacDesignTokens.Colors.canvas)
    .task(id: overviewReloadKey) {
      await analytics.load(range: accessibleRange, hasPro: purchaseManager.hasPro)
    }
    .task(id: conversationLoadKey) {
      guard analytics.hasLoaded else { return }
      if let conversation = selectedConversation {
        await analytics.loadConversation(conversation)
      } else {
        analytics.clearSelectionState()
      }
    }
    .onChange(of: range) { oldRange, newRange in
      guard oldRange != newRange else { return }
      MacAppAnalytics.track(.analyticsRangeSelected, dimension: .init(range: accessibleRange))
    }
    .onChange(of: purchaseManager.hasPro) { _, hasPro in
      if !hasPro { range = .today }
    }
    .onChange(of: analytics.conversations.map(\.id.rawValue)) { _, ids in
      guard analytics.hasLoaded else { return }
      if let selectedConversationID, !ids.contains(selectedConversationID) {
        self.selectedConversationID = nil
      }
    }
    .confirmationDialog(
      "Clear local telemetry?",
      isPresented: $confirmClearTelemetry,
      titleVisibility: .visible
    ) {
      Button("Clear Local Telemetry", role: .destructive) {
        Task {
          await analytics.clearTelemetry(
            range: accessibleRange,
            hasPro: purchaseManager.hasPro
          )
          if let conversation = selectedConversation {
            await analytics.loadConversation(conversation)
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes locally stored performance and reliability events and daily rollups. Saved chat history, usage, and spend are unaffected.")
    }
  }

  private var workspaceControls: some View {
    HStack(spacing: 12) {
      if selectedConversation != nil {
        Button {
          selectedConversationID = nil
          section = .conversations
        } label: {
          Label("Conversations", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(MacDesignTokens.Colors.accent)
      } else {
        Picker("Section", selection: $section) {
          ForEach(MacAnalyticsWorkspaceSection.allCases) { value in
            Text(value.rawValue).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 260)
      }

      Spacer()

      if selectedConversation == nil {
        Menu {
          ForEach(UsageAnalyticsRange.allCases) { value in
            rangeMenuButton(for: value)
          }
        } label: {
          Text(accessibleRange.label)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Analytics date range, \(accessibleRange.label)")
        .accessibilityHint("Choose the analytics date range.")
      }

      Button {
        Task {
          await analytics.load(range: accessibleRange, hasPro: purchaseManager.hasPro)
          if let conversation = selectedConversation {
            await analytics.loadConversation(conversation)
          }
        }
      } label: {
        Label(
          (analytics.isLoading || analytics.isLoadingConversation) ? "Refreshing…" : "Refresh",
          systemImage: "arrow.clockwise"
        )
      }
      .disabled(analytics.isLoading || analytics.isLoadingConversation || analytics.isClearingTelemetry)
    }
    .padding(.horizontal, 16)
    .frame(height: 54)
    .background(MacDesignTokens.Colors.surface.opacity(0.45))
  }

  private func rangeMenuButton(for value: UsageAnalyticsRange) -> some View {
    let locked = value.requiresPro && !purchaseManager.hasPro
    let selected = accessibleRange == value

    return Button {
      if locked {
        MacProAccess.requestUpgrade(.analytics)
      } else {
        range = value
      }
    } label: {
      if locked {
        Label(value.label, systemImage: "lock.fill")
      } else if selected {
        Label(value.label, systemImage: "checkmark")
      } else {
        Text(value.label)
      }
    }
    .disabled(locked && purchaseManager.entitlementState == .checking)
  }

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Loading local analytics…")
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MacDesignTokens.Colors.canvas)
  }

  private var overview: some View {
    let snapshot = analytics.overviewSnapshot
    let budget = analytics.budgetSnapshot
    let aggregate = snapshot.aggregate

    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        analyticsHeading(
          title: "Usage",
          subtitle: "Local usage and spend for \(accessibleRange.label.lowercased())."
        )

        MacAnalyticsMetricGrid(
          metrics: overviewMetrics(snapshot: snapshot)
        )

        Label(macUsageHistoryFootnote(aggregate), systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 12, alignment: .top)],
          alignment: .leading,
          spacing: 12
        ) {
          if analytics.overviewTelemetryUnavailable {
            telemetryUnavailableCard(
              isDisabled: analytics.isLoading || analytics.isClearingTelemetry
            ) {
              Task {
                await analytics.load(
                  range: accessibleRange,
                  hasPro: purchaseManager.hasPro,
                  retry: true
                )
              }
            }
          } else {
            performanceCard(snapshot.performance)
            reliabilityCard(snapshot.performance, includeToolAndMCP: true)

            if !snapshot.failureBreakdown.isEmpty {
              errorsCard(snapshot.failureBreakdown)
            }
          }

          if !snapshot.conversationBreakdown.isEmpty {
            topChatsCard(snapshot.conversationBreakdown)
          }

          if !snapshot.providerBreakdown.isEmpty {
            MacAnalyticsSection(title: "Providers", symbol: "server.rack") {
              MacAnalyticsBreakdownList(
                rows: snapshot.providerBreakdown,
                displayName: { macUsageDisplayName($0, accounts: analytics.accounts) }
              )
            }
          }

          if !snapshot.modelBreakdown.isEmpty {
            MacAnalyticsSection(title: "Models", symbol: "cpu") {
              MacAnalyticsBreakdownList(
                rows: snapshot.modelBreakdown,
                displayName: { macUsageModelDisplayName($0, modelsByAccount: analytics.modelsByAccount) }
              )
            }
          }

          budgetCard(budget.aggregate)
          localAnalyticsCard
        }
      }
      .frame(maxWidth: 980, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func overviewMetrics(snapshot: UsageAnalyticsSnapshot) -> [MacAnalyticsMetric] {
    let aggregate = snapshot.aggregate
    return [
      .init(title: "Spend", value: macUsageAggregateCost(aggregate), symbol: "dollarsign.circle"),
      .init(title: "Active Chats", value: snapshot.activeConversationCount.formatted(), symbol: "bubble.left.and.bubble.right"),
      .init(title: "Model Requests", value: aggregate.modelRequestCount.formatted(), symbol: "arrow.up.arrow.down"),
      .init(title: "Total Tokens", value: macUsageCompactTokens(aggregate.totalTokens), symbol: "sum"),
      .init(title: "Input", value: macUsageCompactTokens(aggregate.inputTokens), symbol: "arrow.down.left"),
      .init(title: "Output", value: macUsageCompactTokens(aggregate.outputTokens), symbol: "arrow.up.right"),
      .init(
        title: "Cached Input",
        value: macUsageCachedTokensWithRate(
          cached: aggregate.cachedInputTokens,
          input: aggregate.inputTokens
        ),
        symbol: "bolt.horizontal.circle"
      ),
      .init(title: "Cache Write", value: macUsageCompactTokens(aggregate.cacheWriteTokens), symbol: "square.and.arrow.down"),
      .init(title: "Reasoning", value: macUsageCompactTokens(aggregate.reasoningTokens), symbol: "brain"),
      .init(title: "Tool Calls", value: aggregate.toolCallCount.formatted(), symbol: "wrench.and.screwdriver"),
    ]
  }

  private func topChatsCard(_ rows: [ConversationUsageBreakdown]) -> some View {
    let topRows = Array(rows.prefix(5))
    return MacAnalyticsSection(title: "Top Chats", symbol: "bubble.left.and.bubble.right") {
      VStack(spacing: 0) {
        ForEach(topRows) { item in
          Button {
            section = .conversations
            selectedConversationID = item.id.rawValue
          } label: {
            HStack(alignment: .top, spacing: 12) {
              MacAnalyticsBreakdownRowContent(
                title: item.title,
                aggregate: item.aggregate,
                performance: item.performance
              )
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .padding(.top, 2)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          if item.id != topRows.last?.id {
            Divider()
          }
        }
      }
    }
  }

  private var conversations: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        analyticsHeading(
          title: "Conversations",
          subtitle: "Inspect usage, context window fill, and reliability for individual chats."
        )

        MacAnalyticsSearchField(
          placeholder: "Search conversations",
          text: $conversationSearchText
        )
        .frame(maxWidth: 420)

        Text("\(filteredConversations.count) conversation\(filteredConversations.count == 1 ? "" : "s")")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        if filteredConversations.isEmpty {
          if conversationSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
              "No Conversations",
              systemImage: "bubble.left.and.bubble.right",
              description: Text("Start chatting to see per-conversation analytics here.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
          } else {
            ContentUnavailableView.search(text: conversationSearchText)
              .frame(maxWidth: .infinity)
              .padding(.top, 70)
          }
        } else {
          LazyVStack(spacing: 9) {
            ForEach(filteredConversations) { conversation in
              conversationCard(conversation)
            }
          }
        }
      }
      .frame(maxWidth: 860, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func conversationCard(_ conversation: ChatConversation) -> some View {
    let aggregate = analytics.overviewAggregate(for: conversation.id)
    let title = conversation.title.isEmpty ? "New Chat" : conversation.title

    return Button {
      selectedConversationID = conversation.id.rawValue
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(title)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)
            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          Spacer()
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        HStack(spacing: 16) {
          conversationStat(aggregate.modelRequestCount.formatted(), label: "requests")
          conversationStat(macUsageCompactTokens(aggregate.totalTokens), label: "tokens")
          conversationStat(macUsageAggregateCost(aggregate), label: "spend")
          Spacer()
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func conversationStat(_ value: String, label: String) -> some View {
    HStack(spacing: 4) {
      Text(value)
        .font(.caption.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      Text(label)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
  }

  private func conversationDetail(_ conversation: ChatConversation) -> some View {
    let isCurrentConversationLoaded =
      analytics.hasLoadedConversation && analytics.selectedConversationIDLoaded == conversation.id
    let snapshot = isCurrentConversationLoaded
      ? analytics.selectedConversationSnapshot
      : ConversationUsageAnalyticsSnapshot(
        aggregate: ChatUsageAggregate(),
        performance: TelemetryPerformanceAggregate()
      )
    let contextUsage = isCurrentConversationLoaded ? analytics.selectedConversationContextUsage : nil
    let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "New Chat"
      : conversation.title
    let messageCount = conversation.messages.count
    let replyCount = snapshot.aggregate.assistantMessageCount
    let messagesSummary = replyCount > 0
      ? "\(messageCount.formatted()) (\(replyCount.formatted()) \(replyCount == 1 ? "reply" : "replies"))"
      : messageCount.formatted()

    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        analyticsHeading(
          title: title,
          subtitle: "All-time chat analytics · updated \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        )

        if !isCurrentConversationLoaded {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text("Loading conversation analytics…")
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 10))
          .overlay {
            RoundedRectangle(cornerRadius: 10)
              .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
          }
        } else {
          MacAnalyticsMetricGrid(
            metrics: [
              .init(title: "Spend", value: macUsageAggregateCost(snapshot.aggregate), symbol: "dollarsign.circle"),
              .init(title: "Messages", value: messagesSummary, symbol: "text.bubble"),
              .init(title: "Model Requests", value: snapshot.aggregate.modelRequestCount.formatted(), symbol: "arrow.up.arrow.down"),
              .init(title: "Total Tokens", value: macUsageCompactTokens(snapshot.aggregate.totalTokens), symbol: "sum"),
              .init(title: "Input", value: macUsageCompactTokens(snapshot.aggregate.inputTokens), symbol: "arrow.down.left"),
              .init(title: "Output", value: macUsageCompactTokens(snapshot.aggregate.outputTokens), symbol: "arrow.up.right"),
              .init(
                title: "Cached Input",
                value: macUsageCachedTokensWithRate(
                  cached: snapshot.aggregate.cachedInputTokens,
                  input: snapshot.aggregate.inputTokens
                ),
                symbol: "bolt.horizontal.circle"
              ),
              .init(title: "Cache Write", value: macUsageCompactTokens(snapshot.aggregate.cacheWriteTokens), symbol: "square.and.arrow.down"),
              .init(title: "Reasoning", value: macUsageCompactTokens(snapshot.aggregate.reasoningTokens), symbol: "brain"),
              .init(title: "Tool Calls", value: snapshot.aggregate.toolCallCount.formatted(), symbol: "wrench.and.screwdriver"),
            ]
          )

          Label(macUsageHistoryFootnote(snapshot.aggregate), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)

          if let contextUsage {
            contextWindowCard(contextUsage)
          }

          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
          ) {
            if analytics.conversationTelemetryUnavailable {
              telemetryUnavailableCard(isDisabled: analytics.isLoadingConversation) {
                Task { await analytics.loadConversation(conversation, retry: true) }
              }
            } else if !hasPerformance(snapshot.performance) && snapshot.failureBreakdown.isEmpty {
              noConversationTelemetryCard(
                hasSavedReplies: snapshot.aggregate.assistantMessageCount > 0
              )
            } else {
              if snapshot.performance.hasLatencyOrSpeedMetrics {
                performanceCard(snapshot.performance, singleRequestAware: true)
              }
              if snapshot.performance.providerRequestCount > 0 {
                reliabilityCard(snapshot.performance, includeToolAndMCP: false)
              }
              if snapshot.performance.toolCallCount > 0 || snapshot.performance.mcpRequestCount > 0 {
                toolsAndMCPCard(snapshot.performance)
              }
              if !snapshot.failureBreakdown.isEmpty {
                errorsCard(snapshot.failureBreakdown)
              }
            }

            if !snapshot.providerBreakdown.isEmpty {
              MacAnalyticsSection(title: "Providers", symbol: "server.rack") {
                MacAnalyticsBreakdownList(
                  rows: snapshot.providerBreakdown,
                  displayName: { macUsageDisplayName($0, accounts: analytics.accounts) }
                )
              }
            }

            if !snapshot.modelBreakdown.isEmpty {
              MacAnalyticsSection(title: "Models", symbol: "cpu") {
                MacAnalyticsBreakdownList(
                  rows: snapshot.modelBreakdown,
                  displayName: { macUsageModelDisplayName($0, modelsByAccount: analytics.modelsByAccount) }
                )
              }
            }
          }
        }
      }
      .frame(maxWidth: 960, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func contextWindowCard(_ contextUsage: ConversationContextUsage) -> some View {
    MacAnalyticsSection(title: "Context Window", symbol: "gauge.with.dots.needle.33percent") {
      VStack(alignment: .leading, spacing: 10) {
        if let window = contextUsage.contextWindow, let fill = contextUsage.fillFraction {
          MacAnalyticsLabeledRow(
            "Latest Turn",
            value: "\(macUsageCompactTokens(contextUsage.usedInputTokens)) / \(macUsageCompactTokens(window)) (\(macUsagePercent(fill)))"
          )
          ProgressView(value: fill)
            .tint(fill >= 0.95 ? .red : fill >= 0.8 ? .orange : MacDesignTokens.Colors.accent)
        } else {
          MacAnalyticsLabeledRow(
            "Latest Turn Input",
            value: macUsageCompactTokens(contextUsage.usedInputTokens)
          )
        }

        if contextUsage.omittedMessageCount > 0 {
          Label(
            "\(contextUsage.omittedMessageCount.formatted()) earlier \(contextUsage.omittedMessageCount == 1 ? "message" : "messages") omitted to fit context",
            systemImage: "scissors"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }

        Text(
          contextUsage.isEstimated
            ? "Estimated from the latest built request context."
            : "Based on the latest request's input tokens."
        )
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
  }

  private func telemetryUnavailableCard(
    isDisabled: Bool,
    retryAction: @escaping () -> Void
  ) -> some View {
    MacAnalyticsSection(title: "Performance Data Unavailable", symbol: "exclamationmark.triangle") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Local telemetry could not be read. Saved usage and spend remain available.")
          .font(.callout)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

        Button("Retry", action: retryAction)
          .buttonStyle(.borderedProminent)
          .disabled(isDisabled)
      }
    }
  }

  private func noConversationTelemetryCard(hasSavedReplies: Bool) -> some View {
    MacAnalyticsSection(
      title: hasSavedReplies ? "No Recent Performance Data" : "No Performance Data Yet",
      symbol: "waveform.path.ecg"
    ) {
      Text(
        hasSavedReplies
          ? "Local performance telemetry is retained for up to 30 days. Saved usage and spend above remain available."
          : "Send a message in this chat to start collecting local performance metrics."
      )
      .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
  }

  @ViewBuilder
  private func performanceCard(
    _ performance: TelemetryPerformanceAggregate,
    singleRequestAware: Bool = false
  ) -> some View {
    let isSingleRequest = singleRequestAware && performance.providerRequestCount <= 1
    let showPercentiles = !singleRequestAware || performance.providerRequestCount >= 5

    MacAnalyticsSection(
      title: "Performance",
      symbol: performance.hasLatencyOrSpeedMetrics ? "gauge.with.dots.needle.67percent" : "waveform.path.ecg"
    ) {
      if performance.hasLatencyOrSpeedMetrics {
        VStack(spacing: 9) {
          MacAnalyticsLabeledRow(
            isSingleRequest ? "TTFT" : "Median TTFT",
            value: macUsageDuration(performance.medianTTFTMilliseconds)
          )
          if showPercentiles, performance.p95TTFTMilliseconds != nil {
            MacAnalyticsLabeledRow("P95 TTFT", value: macUsageDuration(performance.p95TTFTMilliseconds))
          }
          MacAnalyticsLabeledRow(
            isSingleRequest ? "Duration" : "Median Duration",
            value: macUsageDuration(performance.medianDurationMilliseconds)
          )
          if showPercentiles, performance.p95DurationMilliseconds != nil {
            MacAnalyticsLabeledRow("P95 Duration", value: macUsageDuration(performance.p95DurationMilliseconds))
          }
          MacAnalyticsLabeledRow(
            isSingleRequest ? "Speed" : "Median Speed",
            value: macUsageRate(performance.medianOutputTokensPerSecond)
          )
        }
      } else {
        Text("Send a few messages to start collecting local performance metrics.")
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
  }

  private func reliabilityCard(
    _ performance: TelemetryPerformanceAggregate,
    includeToolAndMCP: Bool
  ) -> some View {
    MacAnalyticsSection(title: "Reliability", symbol: "checkmark.shield") {
      VStack(alignment: .leading, spacing: 9) {
        if hasPerformance(performance) {
          if performance.providerRequestCount > 0 {
            MacAnalyticsLabeledRow("Success Rate", value: macUsagePercent(performance.providerSuccessRate))
            MacAnalyticsLabeledRow("Succeeded", value: performance.providerSuccessCount.formatted())
            MacAnalyticsLabeledRow("Failed", value: performance.providerFailureCount.formatted())
            if performance.providerCancelledCount > 0 {
              MacAnalyticsLabeledRow("Cancelled", value: performance.providerCancelledCount.formatted())
            }
          }
          if includeToolAndMCP && performance.toolCallCount > 0 {
            if performance.providerRequestCount > 0 { Divider() }
            MacAnalyticsLabeledRow("Tool Success", value: macUsagePercent(performance.toolSuccessRate))
            MacAnalyticsLabeledRow("Tool Calls", value: performance.toolCallCount.formatted())
            if performance.toolFailureCount > 0 {
              MacAnalyticsLabeledRow("Tool Failures", value: performance.toolFailureCount.formatted())
            }
            if performance.toolCancelledCount > 0 {
              MacAnalyticsLabeledRow("Tool Cancelled", value: performance.toolCancelledCount.formatted())
            }
          }
          if includeToolAndMCP && performance.mcpRequestCount > 0 {
            if performance.providerRequestCount > 0 || performance.toolCallCount > 0 { Divider() }
            MacAnalyticsLabeledRow("MCP Requests", value: performance.mcpRequestCount.formatted())
            MacAnalyticsLabeledRow("MCP Failures", value: performance.mcpFailureCount.formatted())
          }

          Text(
            includeToolAndMCP
              ? "Provider success rate excludes user cancellations. Expected MCP legacy-protocol fallback is not counted as an MCP failure."
              : "Provider success rate excludes user cancellations."
          )
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .padding(.top, 2)
        } else {
          Text("Reliability metrics appear after provider, tool, or MCP requests are recorded.")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
      }
    }
  }

  private func toolsAndMCPCard(_ performance: TelemetryPerformanceAggregate) -> some View {
    MacAnalyticsSection(title: "Tools & MCP", symbol: "wrench.and.screwdriver") {
      VStack(spacing: 9) {
        if performance.toolCallCount > 0 {
          MacAnalyticsLabeledRow("Tool Calls", value: performance.toolCallCount.formatted())
          MacAnalyticsLabeledRow("Tool Success", value: macUsagePercent(performance.toolSuccessRate))
          if performance.toolFailureCount > 0 {
            MacAnalyticsLabeledRow("Tool Failures", value: performance.toolFailureCount.formatted())
          }
          if performance.toolCancelledCount > 0 {
            MacAnalyticsLabeledRow("Tool Cancelled", value: performance.toolCancelledCount.formatted())
          }
        }
        if performance.mcpRequestCount > 0 {
          if performance.toolCallCount > 0 { Divider() }
          MacAnalyticsLabeledRow("MCP Requests", value: performance.mcpRequestCount.formatted())
          MacAnalyticsLabeledRow("MCP Failures", value: performance.mcpFailureCount.formatted())
        }
      }
    }
  }

  private func errorsCard(_ failureBreakdown: [TelemetryFailureBreakdown]) -> some View {
    MacAnalyticsSection(title: "Errors", symbol: "exclamationmark.triangle") {
      VStack(alignment: .leading, spacing: 0) {
        let failures = Array(failureBreakdown.prefix(8))
        ForEach(failures) { failure in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(macAnalyticsErrorTitle(failure.errorCode))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              Text("\(macUsageCategoryTitle(failure.category)) · \(failure.classification.replacingOccurrences(of: "_", with: " "))")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }
            Spacer()
            Text(failure.count.formatted())
              .monospacedDigit()
              .foregroundStyle(Color.orange)
          }
          .padding(.vertical, 7)

          if failure.id != failures.last?.id {
            Divider()
          }
        }

        Text("Only stable, privacy-safe error codes are shown. Provider response text and request content are never stored in analytics.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .padding(.top, 8)
      }
    }
  }

  private func budgetCard(_ aggregate: ChatUsageAggregate) -> some View {
    MacAnalyticsSection(title: "Monthly Budget", symbol: "gauge.with.needle") {
      VStack(spacing: 10) {
        HStack {
          Text("Budget")
          Spacer()
          Text("$")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          TextField(
            "0",
            value: $monthlyBudgetUSD,
            format: .number.precision(.fractionLength(0...2))
          )
          .multilineTextAlignment(.trailing)
          .frame(width: 100)
        }

        Picker("Warn at", selection: $budgetWarningFraction) {
          Text("50%").tag(0.5)
          Text("75%").tag(0.75)
          Text("80%").tag(0.8)
          Text("90%").tag(0.9)
        }

        if monthlyBudgetUSD > 0 {
          ProgressView(value: budgetProgress(aggregate))
          MacAnalyticsLabeledRow(
            purchaseManager.hasPro ? "This Month" : "Today Only",
            value: macUsageAggregateCost(aggregate)
          )
          if budgetWarningReached(aggregate) {
            Label("Budget warning threshold reached", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        Text(purchaseManager.hasPro
          ? "This local warning does not change provider-side spending limits or include API-key usage from other apps."
          : "Free evaluates this monthly threshold using today's saved usage only. Earlier days are excluded, so warnings may underestimate monthly spending. Pro includes the complete month. This does not change provider spending limits.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var localAnalyticsCard: some View {
    MacAnalyticsSection(title: "Local Analytics", symbol: "internaldrive") {
      VStack(alignment: .leading, spacing: 9) {
        if analytics.overviewTelemetryUnavailable {
          MacAnalyticsLabeledRow("Telemetry", value: "Unavailable")
        } else {
          MacAnalyticsLabeledRow("Telemetry Events", value: analytics.telemetryEvents.count.formatted())
          if analytics.statistics.rollupRowCount > 0 {
            MacAnalyticsLabeledRow("Daily Rollups", value: analytics.statistics.rollupRowCount.formatted())
          }
        }
        if analytics.statistics.databaseBytes > 0 {
          MacAnalyticsLabeledRow(
            "Local Database",
            value: ByteCountFormatter.string(
              fromByteCount: analytics.statistics.databaseBytes,
              countStyle: .file
            )
          )
        }
        if analytics.statistics.eventCount > 0
          || analytics.statistics.rollupRowCount > 0
          || analytics.overviewTelemetryUnavailable
        {
          Button("Clear Local Telemetry", role: .destructive) {
            confirmClearTelemetry = true
          }
          .disabled(analytics.isLoading || analytics.isClearingTelemetry)
          .padding(.top, 2)
        }
        Text(telemetryFootnote)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func analyticsHeading(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.title3.weight(.semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
    }
  }

  private var telemetryFootnote: String {
    if !purchaseManager.hasPro {
      return "Only today's local telemetry is shown. Historical ranges require Pro. Detailed events are kept for up to 30 days and summarized into lightweight daily rollups for long-term history."
    }
    if analytics.telemetryEvents.count >= TelemetryStoreConfiguration.maximumRecentEventQueryCount {
      let limit = TelemetryStoreConfiguration.maximumRecentEventQueryCount.formatted()
      return "Recent performance uses up to \(limit) detailed events in this range plus archived daily rollups. Raw telemetry is device-local, and saved chat usage remains available from message history."
    }
    return "Detailed telemetry is kept on device for up to 30 days and automatically summarized into daily rollups before pruning. Chat usage and spend remain available from message history even if telemetry is cleared."
  }

  private func hasPerformance(_ performance: TelemetryPerformanceAggregate) -> Bool {
    performance.providerRequestCount > 0 || performance.toolCallCount > 0 || performance.mcpRequestCount > 0
  }

  private func budgetProgress(_ aggregate: ChatUsageAggregate) -> Double {
    guard monthlyBudgetUSD > 0 else { return 0 }
    let spent = NSDecimalNumber(decimal: aggregate.costUSD).doubleValue
    return min(max(spent / monthlyBudgetUSD, 0), 1)
  }

  private func budgetWarningReached(_ aggregate: ChatUsageAggregate) -> Bool {
    guard monthlyBudgetUSD > 0 else { return false }
    let spent = NSDecimalNumber(decimal: aggregate.costUSD).doubleValue
    return spent >= monthlyBudgetUSD * budgetWarningFraction
  }
}

struct MacAnalyticsMetric: Identifiable {
  let title: String
  let value: String
  let symbol: String

  var id: String { title }
}

struct MacAnalyticsMetricGrid: View {
  let metrics: [MacAnalyticsMetric]

  private let columns = [
    GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 10, alignment: .top)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
      ForEach(metrics) { metric in
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 6) {
            Image(systemName: metric.symbol)
            Text(metric.title.uppercased())
          }
          .font(.caption2.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

          Text(metric.value)
            .font(.system(size: 19, weight: .semibold, design: .rounded))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(13)
        .background(
          MacDesignTokens.Colors.surface,
          in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(metric.value)
      }
    }
  }
}

struct MacAnalyticsSection<Content: View>: View {
  let title: String
  let symbol: String
  let content: Content

  init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.symbol = symbol
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: symbol)
        .font(.headline)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)

      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }
}

struct MacAnalyticsLabeledRow: View {
  let title: String
  let value: String

  init(_ title: String, value: String) {
    self.title = title
    self.value = value
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      Spacer(minLength: 20)
      Text(value)
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        .monospacedDigit()
        .textSelection(.enabled)
    }
    .font(.system(size: 13))
  }
}

private struct MacAnalyticsBreakdownRowContent: View {
  let title: String
  let aggregate: ChatUsageAggregate
  let performance: TelemetryPerformanceAggregate

  private var hasSavedMessages: Bool {
    aggregate.assistantMessageCount > 0
  }

  private var performanceSummaryLine: String? {
    guard performance.providerRequestCount > 0 else { return nil }
    var parts = ["\(macUsagePercent(performance.providerSuccessRate)) success"]
    if let ttft = performance.medianTTFTMilliseconds {
      parts.append("\(macUsageDuration(ttft)) TTFT")
    }
    if let speed = performance.medianOutputTokensPerSecond {
      parts.append(macUsageRate(speed))
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .fontWeight(.medium)
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          .lineLimit(1)

        if hasSavedMessages {
          Text(
            "\(macUsageCompactTokens(aggregate.totalTokens)) tokens · \(macUsageRequestCountLabel(aggregate.modelRequestCount))"
          )
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
        } else if performance.providerRequestCount > 0 {
          Text("\(macUsageRequestCountLabel(performance.providerRequestCount)) · no saved messages")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        if let performanceSummaryLine {
          Text(performanceSummaryLine)
            .font(.caption2)
            .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.85))
            .monospacedDigit()
        }
      }

      Spacer(minLength: 16)

      Text(
        hasSavedMessages || performance.providerRequestCount == 0
          ? macUsageAggregateCost(aggregate)
          : "—"
      )
      .monospacedDigit()
      .foregroundStyle(MacDesignTokens.Colors.textPrimary)
    }
  }
}

private struct MacAnalyticsBreakdownList: View {
  let rows: [UsageAnalyticsBreakdown]
  let displayName: (String) -> String

  var body: some View {
    VStack(spacing: 0) {
      ForEach(rows) { row in
        MacAnalyticsBreakdownRowContent(
          title: displayName(row.id),
          aggregate: row.aggregate,
          performance: row.performance
        )
        .padding(.vertical, 8)

        if row.id != rows.last?.id {
          Divider()
        }
      }
    }
  }
}

struct MacAnalyticsSearchField: View {
  let placeholder: String
  @Binding var text: String

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }
}

// MARK: - Formatting & Context Window Helpers

nonisolated func macUsageDisplayName(
  _ raw: String,
  accounts: [ProviderAccount] = [],
  fallbackLabel: String? = nil
) -> String {
  let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  let kind = ProviderKind(providerID: ProviderID(rawValue: trimmedRaw.lowercased()))
  if !kind.displayName.isEmpty {
    return kind.displayName
  }
  if let matched = accounts.first(where: {
    $0.providerID.rawValue.caseInsensitiveCompare(trimmedRaw) == .orderedSame
      || $0.id.rawValue.caseInsensitiveCompare(trimmedRaw) == .orderedSame
  }) {
    let trimmed = matched.label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
  }
  if let fallbackLabel {
    let trimmed = fallbackLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
  }
  if UUID(uuidString: trimmedRaw) != nil {
    return "Custom Provider"
  }
  return raw
}

nonisolated func macUsageModelDisplayName(
  _ rawModelID: String,
  modelsByAccount: [ProviderAccountID: [AccountModelRecord]] = [:]
) -> String {
  let trimmedID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedID.isEmpty else { return rawModelID }

  let sortedAccountIDs = modelsByAccount.keys.sorted { $0.rawValue < $1.rawValue }
  var manualFallback: String?
  for accountID in sortedAccountIDs {
    guard let records = modelsByAccount[accountID] else { continue }
    if let match = records.first(where: { $0.model.id.rawValue == trimmedID }) {
      let label = match.model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !label.isEmpty {
        if !match.isManual {
          return label
        }
        if manualFallback == nil {
          manualFallback = label
        }
      }
    }
  }
  if let manualFallback {
    return manualFallback
  }
  for kind in ProviderKind.catalog {
    if let seed = kind.seedModels.first(where: { $0.id.rawValue == trimmedID }) {
      let label = seed.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !label.isEmpty { return label }
    }
  }
  return rawModelID
}

nonisolated func macUsageRequestCountLabel(_ count: Int) -> String {
  count == 1 ? "1 request" : "\(count.formatted()) requests"
}

nonisolated func macUsageCompactTokens(_ value: Int) -> String {
  let number = Double(value)
  if value >= 999_950 {
    return String(format: "%.2fM", number / 1_000_000)
  }
  if value >= 1_000 {
    return String(format: "%.1fK", number / 1_000)
  }
  return value.formatted()
}

nonisolated func macUsageCachedTokensWithRate(
  cached: Int,
  input: Int,
  compact: Bool = true
) -> String {
  let formatted = compact
    ? macUsageCompactTokens(cached)
    : cached.formatted(.number.grouping(.automatic))
  guard input > 0, cached > 0 else { return formatted }
  let rate = min(max(Double(cached) / Double(input), 0), 1)
  return "\(formatted) (\(macUsagePercent(rate)))"
}

nonisolated func macUsageAggregateCost(_ aggregate: ChatUsageAggregate) -> String {
  guard aggregate.assistantMessageCount > 0 else { return "No requests" }
  guard aggregate.hasKnownCost else { return "Unavailable" }
  let prefix = aggregate.isLowerBound ? "≥" : (aggregate.hasEstimatedCost ? "~" : "")
  return prefix + macUsageFormatUSD(aggregate.costUSD) + (aggregate.hasPartialCost ? " (partial)" : "")
}

nonisolated func macUsageFormatUSD(_ cost: Decimal) -> String {
  let value = NSDecimalNumber(decimal: cost).doubleValue
  let magnitude = abs(value)
  if magnitude == 0 {
    return "$0.00"
  }
  if magnitude < 0.0009995 {
    return String(format: "$%.6f", value)
  }
  if magnitude < 0.99995 {
    return String(format: "$%.4f", value)
  }
  return String(format: "$%.2f", value)
}

nonisolated func macUsageHistoryFootnote(_ aggregate: ChatUsageAggregate) -> String {
  let cost = aggregate.hasPartialCost
    ? "Costs are incomplete: some requests lack usage, pricing, or supported billing details. Estimates may differ from provider charges. "
    : "Calculated costs are estimates; provider-reported costs use the reported billing scope. "
  let scope = aggregate.scopedProviderCostMessageCount > 0
    ? "OpenRouter BYOK subtotals include its account charge; upstream provider spend is excluded. "
    : ""
  return cost + scope + "Totals come from saved chat history. Regenerating, editing, or deleting messages can reduce them. API-key usage in other apps is excluded."
}

nonisolated func macUsageDuration(_ milliseconds: Double?) -> String {
  guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
  if milliseconds < 999.5 {
    return "\(Int(milliseconds.rounded())) ms"
  }
  if milliseconds < 9_995 {
    return String(format: "%.2f s", milliseconds / 1_000)
  }
  return String(format: "%.1f s", milliseconds / 1_000)
}

nonisolated func macUsageRate(_ value: Double?) -> String {
  guard let value, value.isFinite, value >= 0 else { return "—" }
  return String(format: "%.1f tok/s", value)
}

nonisolated func macUsagePercent(_ value: Double?) -> String {
  guard let value, value.isFinite else { return "—" }
  return value.formatted(.percent.precision(.fractionLength(0...1)))
}

nonisolated func macUsageCategoryTitle(_ category: TelemetryCategory) -> String {
  switch category {
  case .mcp: "MCP"
  default: category.rawValue.capitalized
  }
}

nonisolated func macAnalyticsErrorTitle(_ raw: String) -> String {
  let acronyms: [String: String] = [
    "http": "HTTP",
    "https": "HTTPS",
    "mcp": "MCP",
    "url": "URL",
    "uri": "URI",
    "api": "API",
    "id": "ID",
    "ids": "IDs",
    "json": "JSON",
    "sse": "SSE",
    "tls": "TLS",
    "ssl": "SSL",
    "eof": "EOF",
    "dns": "DNS",
    "tcp": "TCP",
    "udp": "UDP",
    "ip": "IP",
    "utf8": "UTF-8",
    "oauth": "OAuth",
    "byok": "BYOK",
  ]
  return raw
    .replacingOccurrences(of: "_", with: " ")
    .replacingOccurrences(of: "-", with: " ")
    .split(whereSeparator: \.isWhitespace)
    .map { part in
      let lower = part.lowercased()
      return acronyms[lower] ?? part.capitalized
    }
    .joined(separator: " ")
}

nonisolated func macResolveModelContextWindow(
  conversation: ChatConversation,
  accounts: [ProviderAccount],
  modelsByAccount: [ProviderAccountID: [AccountModelRecord]]
) -> Int? {
  let account = accounts.first { $0.id == conversation.accountID }
  let modelRecord = modelsByAccount[conversation.accountID]?
    .first { $0.model.id == conversation.modelID }
  let kind = account?.kind ?? ProviderKind(providerID: conversation.providerID)
  let resolved = ModelCapabilityResolver.resolve(
    kind: kind,
    modelID: conversation.modelID,
    model: modelRecord?.model
  )
  if let window = resolved.contextWindow, window > 0 {
    return window
  }
  if let rawWindow = modelRecord?.model.contextWindow, rawWindow > 0 {
    return rawWindow
  }
  return nil
}

nonisolated func macConversationContextUsage(
  conversation: ChatConversation,
  telemetryEvents: [TelemetryEvent],
  accounts: [ProviderAccount],
  modelsByAccount: [ProviderAccountID: [AccountModelRecord]]
) -> ConversationContextUsage? {
  let modelWindow = macResolveModelContextWindow(
    conversation: conversation,
    accounts: accounts,
    modelsByAccount: modelsByAccount
  )
  guard let usage = UsageAnalytics.latestContextUsage(
    conversation: conversation,
    telemetryEvents: telemetryEvents,
    modelContextWindow: modelWindow
  ) else {
    return nil
  }
  let omitted = max(usage.omittedMessageCount, max(0, conversation.lastContextOmittedMessageCount))
  guard omitted != usage.omittedMessageCount else { return usage }
  return ConversationContextUsage(
    usedInputTokens: usage.usedInputTokens,
    contextWindow: usage.contextWindow,
    omittedMessageCount: omitted,
    isEstimated: usage.isEstimated
  )
}
