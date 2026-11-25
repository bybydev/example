import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation
import SwiftUI

private struct MacAnalyticsOverviewComputation: Sendable {
  let snapshot: UsageAnalyticsSnapshot
  let budgetSnapshot: UsageAnalyticsSnapshot
  let conversationUsageByID: [ConversationID: ConversationUsageBreakdown]
  let conversationsByID: [String: ChatConversation]
  let overviewMetrics: [MacAnalyticsMetric]
  let modelNameIndex: [String: String]
  let providerDisplayNamesByID: [String: String]
  let modelDisplayNamesByID: [String: String]
}

private struct MacAnalyticsConversationComputation: Sendable {
  let snapshot: ConversationUsageAnalyticsSnapshot
  let contextUsage: ConversationContextUsage?
  let metrics: [MacAnalyticsMetric]
  let providerDisplayNamesByID: [String: String]
  let modelDisplayNamesByID: [String: String]
}

@MainActor
@Observable
final class MacAnalyticsModel {
  private(set) var conversations: [ChatConversation] = []
  private(set) var conversationsByID: [String: ChatConversation] = [:]
  private(set) var corpusRevision = 0
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
  private(set) var overviewMetrics: [MacAnalyticsMetric] = []
  private(set) var providerDisplayNamesByID: [String: String] = [:]
  private(set) var modelDisplayNamesByID: [String: String] = [:]
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
  private(set) var selectedConversationMetrics: [MacAnalyticsMetric] = []
  private(set) var selectedConversationProviderDisplayNames: [String: String] = [:]
  private(set) var selectedConversationModelDisplayNames: [String: String] = [:]
  private(set) var selectedConversationTelemetryEvents: [TelemetryEvent] = []
  private(set) var selectedConversationIDLoaded: ConversationID?
  private(set) var conversationTelemetryUnavailable = false
  private(set) var isLoadingConversation = false
  private(set) var hasLoadedConversation = false

  @ObservationIgnored private var overviewLoadGeneration = 0
  @ObservationIgnored private var conversationLoadGeneration = 0
  @ObservationIgnored private var cachedBudgetRange: UsageAnalyticsRange?
  @ObservationIgnored private var cachedModelNameIndex: [String: String] = [:]

  private let services: BYOKCoreServices

  init(services: BYOKCoreServices) {
    self.services = services
  }

  func load(
    range: UsageAnalyticsRange = .today,
    hasPro: Bool = true,
    retry: Bool = false,
    reloadCorpus: Bool = true,
    reference: Date = .now
  ) async {
    overviewLoadGeneration &+= 1
    let generation = overviewLoadGeneration
    let effectiveRange = range.accessible(hasPro: hasPro)
    let budgetRange = UsageAnalyticsRange.month.accessible(hasPro: hasPro)
    let shouldReloadCorpus = reloadCorpus || !hasLoaded

    isLoading = true
    defer {
      if generation == overviewLoadGeneration {
        isLoading = false
      }
    }

    if retry {
      await services.telemetryRecorder.retryAfterFailure()
    }

    let conversationStore = services.conversationStore
    let providerWorkspace = services.providerWorkspace
    let telemetryRecorder = services.telemetryRecorder

    let loadedConversations: [ChatConversation]
    let loadedAccounts: [ProviderAccount]
    let loadedModelsByAccount: [ProviderAccountID: [AccountModelRecord]]
    let analyticsLoadResult: TelemetryAnalyticsRangeLoadResult

    if shouldReloadCorpus {
      async let conversationsTask = conversationStore.analyticsConversations()
      async let workspaceSnapshotTask = providerWorkspace.snapshot()
      async let analyticsLoadTask = telemetryRecorder.loadAnalytics(
        range: effectiveRange,
        reference: reference,
        limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
      )

      let rawConversations = await conversationsTask
      let workspaceSnapshot = await workspaceSnapshotTask
      analyticsLoadResult = await analyticsLoadTask

      guard !Task.isCancelled, generation == overviewLoadGeneration else { return }

      loadedConversations = rawConversations
      loadedAccounts = workspaceSnapshot.accounts
      loadedModelsByAccount = Dictionary(grouping: workspaceSnapshot.modelRecords, by: \.accountID)
    } else {
      analyticsLoadResult = await telemetryRecorder.loadAnalytics(
        range: effectiveRange,
        reference: reference,
        limit: TelemetryStoreConfiguration.maximumRecentEventQueryCount
      )

      guard !Task.isCancelled, generation == overviewLoadGeneration else { return }

      loadedConversations = conversations
      loadedAccounts = accounts
      loadedModelsByAccount = modelsByAccount
    }

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

    let existingBudgetRange = shouldReloadCorpus ? nil : cachedBudgetRange
    let existingBudgetSnapshot = budgetSnapshot
    let existingModelNameIndex = shouldReloadCorpus ? nil : cachedModelNameIndex
    let existingConversationsByID = shouldReloadCorpus ? nil : conversationsByID

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
      } else if existingBudgetRange == budgetRange {
        budget = existingBudgetSnapshot
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
      let byID = existingConversationsByID ?? Dictionary(
        loadedConversations.map { ($0.id.rawValue, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let modelIndex = existingModelNameIndex
        ?? macBuildModelDisplayNameIndex(modelsByAccount: loadedModelsByAccount)

      var providerNames: [String: String] = [:]
      providerNames.reserveCapacity(snapshot.providerBreakdown.count)
      for row in snapshot.providerBreakdown {
        providerNames[row.id] = macUsageDisplayName(row.id, accounts: loadedAccounts)
      }

      var modelNames: [String: String] = [:]
      modelNames.reserveCapacity(snapshot.modelBreakdown.count)
      for row in snapshot.modelBreakdown {
        let trimmed = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
        modelNames[row.id] = modelIndex[trimmed] ?? row.id
      }

      let metrics = macAnalyticsOverviewMetrics(snapshot: snapshot)

      return MacAnalyticsOverviewComputation(
        snapshot: snapshot,
        budgetSnapshot: budget,
        conversationUsageByID: usageByID,
        conversationsByID: byID,
        overviewMetrics: metrics,
        modelNameIndex: modelIndex,
        providerDisplayNamesByID: providerNames,
        modelDisplayNamesByID: modelNames
      )
    }.value

    guard !Task.isCancelled, generation == overviewLoadGeneration else { return }

    if shouldReloadCorpus {
      conversations = loadedConversations
      conversationsByID = computed.conversationsByID
      accounts = loadedAccounts
      modelsByAccount = loadedModelsByAccount
      cachedModelNameIndex = computed.modelNameIndex
      corpusRevision &+= 1
    }
    telemetryEvents = loadedEvents
    dailyRollups = loadedRollups
    dailyErrorRollups = loadedErrorRollups
    statistics = loadedStatistics
    overviewTelemetryUnavailable = unavailable
    overviewSnapshot = computed.snapshot
    budgetSnapshot = computed.budgetSnapshot
    cachedBudgetRange = budgetRange
    overviewConversationUsageByID = computed.conversationUsageByID
    overviewMetrics = computed.overviewMetrics
    providerDisplayNamesByID = computed.providerDisplayNamesByID
    modelDisplayNamesByID = computed.modelDisplayNamesByID
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
    let modelIndexSnapshot = cachedModelNameIndex

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
      let metrics = macAnalyticsConversationMetrics(
        messageCount: conversation.messages.count,
        aggregate: snapshot.aggregate
      )

      var providerNames: [String: String] = [:]
      providerNames.reserveCapacity(snapshot.providerBreakdown.count)
      for row in snapshot.providerBreakdown {
        providerNames[row.id] = macUsageDisplayName(row.id, accounts: accountsSnapshot)
      }

      var modelNames: [String: String] = [:]
      modelNames.reserveCapacity(snapshot.modelBreakdown.count)
      for row in snapshot.modelBreakdown {
        let trimmed = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
        modelNames[row.id] = modelIndexSnapshot[trimmed]
          ?? macUsageModelDisplayName(row.id, modelsByAccount: modelsSnapshot)
      }

      return MacAnalyticsConversationComputation(
        snapshot: snapshot,
        contextUsage: contextUsage,
        metrics: metrics,
        providerDisplayNamesByID: providerNames,
        modelDisplayNamesByID: modelNames
      )
    }.value

    guard !Task.isCancelled, generation == conversationLoadGeneration else { return }

    selectedConversationTelemetryEvents = scopedEvents
    conversationTelemetryUnavailable = unavailable
    selectedConversationSnapshot = computed.snapshot
    selectedConversationContextUsage = computed.contextUsage
    selectedConversationMetrics = computed.metrics
    selectedConversationProviderDisplayNames = computed.providerDisplayNamesByID
    selectedConversationModelDisplayNames = computed.modelDisplayNamesByID
    selectedConversationIDLoaded = conversation.id
    hasLoadedConversation = true
  }

  func clearSelectionState() {
    conversationLoadGeneration &+= 1
    selectedConversationIDLoaded = nil
    selectedConversationTelemetryEvents = []
    selectedConversationContextUsage = nil
    selectedConversationMetrics = []
    selectedConversationProviderDisplayNames = [:]
    selectedConversationModelDisplayNames = [:]
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
    await load(range: range, hasPro: hasPro, retry: true, reloadCorpus: true)
  }

  func conversation(for id: String?) -> ChatConversation? {
    guard let id else { return nil }
    return conversationsByID[id]
  }

  func overviewAggregate(for conversationID: ConversationID) -> ChatUsageAggregate {
    overviewConversationUsageByID[conversationID]?.aggregate ?? ChatUsageAggregate()
  }

  func overviewProviderDisplayName(for id: String) -> String {
    providerDisplayNamesByID[id] ?? macUsageDisplayName(id, accounts: accounts)
  }

  func overviewModelDisplayName(for id: String) -> String {
    modelDisplayNamesByID[id] ?? id
  }

  func conversationProviderDisplayName(for id: String) -> String {
    selectedConversationProviderDisplayNames[id] ?? macUsageDisplayName(id, accounts: accounts)
  }

  func conversationModelDisplayName(for id: String) -> String {
    selectedConversationModelDisplayNames[id] ?? id
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

  private static let contentMaxWidth: CGFloat = 960
  private static let contentPadding: CGFloat = 18
  private static let detailGridColumns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
  ]

  private var selectedConversation: ChatConversation? {
    analytics.conversation(for: selectedConversationID)
  }

  private var showsRangeSwitchSkeleton: Bool {
    analytics.hasLoaded && analytics.isLoading && analytics.loadedRange != accessibleRange
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

      Group {
        if !analytics.hasLoaded {
          initialSkeletonView
        } else if let conversation = selectedConversation {
          conversationDetail(conversation)
        } else {
          switch section {
          case .overview:
            if showsRangeSwitchSkeleton {
              MacAnalyticsOverviewSkeleton(
                subtitle: "Loading usage and spend for \(accessibleRange.label.lowercased())…"
              )
            } else {
              overview
            }
          case .conversations:
            conversations
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .animation(
        .easeOut(duration: MacDesignTokens.Control.interactionDuration),
        value: analytics.hasLoaded
      )
      .animation(
        .easeOut(duration: MacDesignTokens.Control.interactionDuration),
        value: showsRangeSwitchSkeleton
      )
    }
    .frame(minWidth: 920, minHeight: 620)
    .background(MacDesignTokens.Colors.canvas)
    .task(id: overviewReloadKey) {
      await analytics.load(
        range: accessibleRange,
        hasPro: purchaseManager.hasPro,
        reloadCorpus: !analytics.hasLoaded
      )
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
    .onChange(of: analytics.corpusRevision) { _, _ in
      guard analytics.hasLoaded else { return }
      if let selectedConversationID, analytics.conversation(for: selectedConversationID) == nil {
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
      if selectedConversationID != nil {
        Button {
          selectedConversationID = nil
          section = .conversations
        } label: {
          Label("Conversations", systemImage: "chevron.left")
            .foregroundStyle(MacDesignTokens.Colors.accent)
        }
        .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
      } else {
        MacSegmentedControl(
          options: MacAnalyticsWorkspaceSection.allCases,
          selection: $section,
          title: \.rawValue
        )
        .frame(width: 260)
      }

      Spacer()

      if selectedConversationID == nil {
        Menu {
          ForEach(UsageAnalyticsRange.allCases) { value in
            rangeMenuButton(for: value)
          }
        } label: {
          MacMenuButtonLabel(title: accessibleRange.label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Analytics date range, \(accessibleRange.label)")
        .accessibilityHint("Choose the analytics date range.")
      }

      Button {
        Task {
          await analytics.load(
            range: accessibleRange,
            hasPro: purchaseManager.hasPro,
            reloadCorpus: true
          )
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
      .buttonStyle(MacActionButtonStyle(.secondary))
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

  @ViewBuilder
  private var initialSkeletonView: some View {
    if selectedConversationID != nil {
      MacAnalyticsConversationDetailSkeleton(title: nil, subtitle: nil)
    } else if section == .conversations {
      MacAnalyticsConversationsSkeleton()
    } else {
      MacAnalyticsOverviewSkeleton(
        subtitle: "Loading usage and spend for \(accessibleRange.label.lowercased())…"
      )
    }
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
          metrics: analytics.overviewMetrics
        )

        Label(macUsageHistoryFootnote(aggregate), systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)

        LazyVGrid(
          columns: Self.detailGridColumns,
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
                  retry: true,
                  reloadCorpus: false
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
                displayName: { analytics.overviewProviderDisplayName(for: $0) }
              )
            }
          }

          if !snapshot.modelBreakdown.isEmpty {
            MacAnalyticsSection(title: "Models", symbol: "cpu") {
              MacAnalyticsBreakdownList(
                rows: snapshot.modelBreakdown,
                displayName: { analytics.overviewModelDisplayName(for: $0) }
              )
            }
          }

          budgetCard(budget.aggregate)
          localAnalyticsCard
        }
      }
      .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
      .padding(Self.contentPadding)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
  }

  private func topChatsCard(_ rows: [ConversationUsageBreakdown]) -> some View {
    let topRows = Array(rows.prefix(5))
    return MacAnalyticsSection(title: "Top Chats", symbol: "bubble.left.and.bubble.right") {
      VStack(spacing: 0) {
        ForEach(topRows) { item in
          MacAnalyticsTopChatRow(item: item) {
            section = .conversations
            selectedConversationID = item.id.rawValue
          }

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
      .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
      .padding(Self.contentPadding)
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
    }
    .buttonStyle(MacCardButtonStyle(cornerRadius: 10))
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
    let subtitle = "All-time chat analytics · updated \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))"

    return Group {
      if !isCurrentConversationLoaded {
        MacAnalyticsConversationDetailSkeleton(title: title, subtitle: subtitle)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            analyticsHeading(title: title, subtitle: subtitle)

            MacAnalyticsMetricGrid(
              metrics: analytics.selectedConversationMetrics
            )

            Label(macUsageHistoryFootnote(snapshot.aggregate), systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .fixedSize(horizontal: false, vertical: true)

            if let contextUsage {
              contextWindowCard(contextUsage)
            }

            LazyVGrid(
              columns: Self.detailGridColumns,
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
                    displayName: { analytics.conversationProviderDisplayName(for: $0) }
                  )
                }
              }

              if !snapshot.modelBreakdown.isEmpty {
                MacAnalyticsSection(title: "Models", symbol: "cpu") {
                  MacAnalyticsBreakdownList(
                    rows: snapshot.modelBreakdown,
                    displayName: { analytics.conversationModelDisplayName(for: $0) }
                  )
                }
              }
            }
          }
          .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
          .padding(Self.contentPadding)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(MacDesignTokens.Colors.canvas)
      }
    }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isCurrentConversationLoaded
    )
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
          .buttonStyle(MacActionButtonStyle(.primary))
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
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("Budget")
            .font(.system(size: 13))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer()
          Text("$")
            .font(.system(size: 13))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          TextField(
            "0",
            value: $monthlyBudgetUSD,
            format: .number.precision(.fractionLength(0...2))
          )
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 100)
        }

        HStack(spacing: 8) {
          Text("Warn at")
            .font(.system(size: 13))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer()
          Picker("Warn at", selection: $budgetWarningFraction) {
            Text("50%").tag(0.5)
            Text("75%").tag(0.75)
            Text("80%").tag(0.8)
            Text("90%").tag(0.9)
          }
          .labelsHidden()
          .frame(width: 100)
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
          .buttonStyle(MacActionButtonStyle(.destructive, size: .small))
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

struct MacAnalyticsMetric: Identifiable, Sendable {
  let title: String
  let value: String
  let symbol: String

  var id: String { title }
}

struct MacAnalyticsMetricGrid: View {
  let metrics: [MacAnalyticsMetric]

  private static let columns = Array(
    repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
    count: 5
  )

  var body: some View {
    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
      ForEach(metrics) { metric in
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 5) {
            Image(systemName: metric.symbol)
            Text(metric.title.uppercased())
              .lineLimit(1)
          }
          .font(.caption2.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)

          Text(metric.value)
            .font(.system(size: 19, weight: .semibold, design: .rounded))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(13)
        .background(
          MacDesignTokens.Colors.surface,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.5)
    }
  }
}

private struct MacAnalyticsTopChatRow: View {
  let item: ConversationUsageBreakdown
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        MacAnalyticsBreakdownRowContent(
          title: item.title,
          aggregate: item.aggregate,
          performance: item.performance
        )
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(
            isHovered ? MacDesignTokens.Colors.textPrimary : MacDesignTokens.Colors.textMuted
          )
          .padding(.top, 2)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 8)
      .background(
        Color.primary.opacity(isHovered ? MacDesignTokens.Control.hoverOpacity : 0),
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isHovered
    )
  }
}

// MARK: - Analytics Skeleton Loading Views

private struct MacAnalyticsSkeletonPulse: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isPulsing = false

  func body(content: Content) -> some View {
    content
      .opacity(reduceMotion ? 0.72 : (isPulsing ? 0.88 : 0.48))
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
          isPulsing = true
        }
      }
  }
}

private struct MacAnalyticsSkeletonBar: View {
  let width: CGFloat?
  let height: CGFloat
  var opacity: CGFloat = 0.08

  init(width: CGFloat? = nil, height: CGFloat, opacity: CGFloat = 0.08) {
    self.width = width
    self.height = height
    self.opacity = opacity
  }

  var body: some View {
    Capsule(style: .continuous)
      .fill(Color.primary.opacity(opacity))
      .frame(maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
  }
}

private struct MacAnalyticsMetricGridSkeleton: View {
  private static let columns = Array(
    repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
    count: 5
  )

  var body: some View {
    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
      ForEach(0..<10, id: \.self) { index in
        VStack(alignment: .leading, spacing: 12) {
          MacAnalyticsSkeletonBar(width: index.isMultiple(of: 2) ? 74 : 90, height: 9, opacity: 0.075)
          MacAnalyticsSkeletonBar(width: index.isMultiple(of: 3) ? 84 : 64, height: 18, opacity: 0.10)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(13)
        .background(
          MacDesignTokens.Colors.surface,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(MacDesignTokens.Colors.separator.opacity(0.65), lineWidth: 0.5)
        }
      }
    }
  }
}

private struct MacAnalyticsSectionSkeleton: View {
  let rowCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MacAnalyticsSkeletonBar(width: 124, height: 13, opacity: 0.10)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(0..<rowCount, id: \.self) { index in
          HStack {
            MacAnalyticsSkeletonBar(
              width: index.isMultiple(of: 2) ? 130 : 108,
              height: 10,
              opacity: 0.07
            )
            Spacer(minLength: 16)
            MacAnalyticsSkeletonBar(
              width: index.isMultiple(of: 2) ? 56 : 70,
              height: 10,
              opacity: 0.09
            )
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.65), lineWidth: 0.5)
    }
  }
}

private struct MacAnalyticsOverviewSkeleton: View {
  let subtitle: String

  private static let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Usage")
            .font(.title3.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        VStack(alignment: .leading, spacing: 16) {
          MacAnalyticsMetricGridSkeleton()

          MacAnalyticsSkeletonBar(width: 520, height: 10, opacity: 0.065)

          LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
            MacAnalyticsSectionSkeleton(rowCount: 4)
            MacAnalyticsSectionSkeleton(rowCount: 4)
            MacAnalyticsSectionSkeleton(rowCount: 3)
            MacAnalyticsSectionSkeleton(rowCount: 3)
          }
        }
        .modifier(MacAnalyticsSkeletonPulse())
      }
      .frame(maxWidth: 960, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading analytics overview")
  }
}

private struct MacAnalyticsConversationsSkeleton: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Conversations")
            .font(.title3.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textPrimary)
          Text("Inspect usage, context window fill, and reliability for individual chats.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
        }

        VStack(alignment: .leading, spacing: 12) {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(MacDesignTokens.Colors.surface)
            .overlay {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.65), lineWidth: 0.5)
            }
            .frame(maxWidth: 420, minHeight: 32, maxHeight: 32)

          MacAnalyticsSkeletonBar(width: 110, height: 10, opacity: 0.07)

          VStack(spacing: 9) {
            ForEach(0..<5, id: \.self) { index in
              VStack(alignment: .leading, spacing: 11) {
                MacAnalyticsSkeletonBar(
                  width: index.isMultiple(of: 2) ? 240 : 190,
                  height: 13,
                  opacity: 0.095
                )
                MacAnalyticsSkeletonBar(width: 120, height: 9, opacity: 0.065)
                HStack(spacing: 16) {
                  MacAnalyticsSkeletonBar(width: 72, height: 10, opacity: 0.075)
                  MacAnalyticsSkeletonBar(width: 82, height: 10, opacity: 0.075)
                  MacAnalyticsSkeletonBar(width: 68, height: 10, opacity: 0.075)
                }
              }
              .padding(14)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                MacDesignTokens.Colors.surface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(MacDesignTokens.Colors.separator.opacity(0.65), lineWidth: 0.5)
              }
            }
          }
        }
        .modifier(MacAnalyticsSkeletonPulse())
      }
      .frame(maxWidth: 960, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading conversations analytics")
  }
}

private struct MacAnalyticsConversationDetailSkeleton: View {
  let title: String?
  let subtitle: String?

  private static let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let title, let subtitle {
          VStack(alignment: .leading, spacing: 3) {
            Text(title)
              .font(.title3.weight(.semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        } else {
          VStack(alignment: .leading, spacing: 6) {
            MacAnalyticsSkeletonBar(width: 220, height: 16, opacity: 0.10)
            MacAnalyticsSkeletonBar(width: 260, height: 10, opacity: 0.07)
          }
          .modifier(MacAnalyticsSkeletonPulse())
        }

        VStack(alignment: .leading, spacing: 16) {
          MacAnalyticsMetricGridSkeleton()

          MacAnalyticsSkeletonBar(width: 480, height: 10, opacity: 0.065)

          MacAnalyticsSectionSkeleton(rowCount: 2)

          LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
            MacAnalyticsSectionSkeleton(rowCount: 4)
            MacAnalyticsSectionSkeleton(rowCount: 4)
          }
        }
        .modifier(MacAnalyticsSkeletonPulse())
      }
      .frame(maxWidth: 960, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(MacDesignTokens.Colors.canvas)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading conversation analytics")
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

nonisolated private func macBuildModelDisplayNameIndex(
  modelsByAccount: [ProviderAccountID: [AccountModelRecord]]
) -> [String: String] {
  var index: [String: String] = [:]
  for kind in ProviderKind.catalog {
    for seed in kind.seedModels {
      let label = seed.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !label.isEmpty, index[seed.id.rawValue] == nil {
        index[seed.id.rawValue] = label
      }
    }
  }

  let sortedAccountIDs = modelsByAccount.keys.sorted { $0.rawValue < $1.rawValue }
  var manualFallbacks: [String: String] = [:]
  var discoveredNames: [String: String] = [:]
  for accountID in sortedAccountIDs {
    guard let records = modelsByAccount[accountID] else { continue }
    for record in records {
      let label = record.model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !label.isEmpty else { continue }
      let rawID = record.model.id.rawValue
      if !record.isManual {
        if discoveredNames[rawID] == nil {
          discoveredNames[rawID] = label
        }
      } else if manualFallbacks[rawID] == nil {
        manualFallbacks[rawID] = label
      }
    }
  }
  for (id, label) in manualFallbacks {
    index[id] = label
  }
  for (id, label) in discoveredNames {
    index[id] = label
  }
  return index
}

nonisolated private func macAnalyticsOverviewMetrics(
  snapshot: UsageAnalyticsSnapshot
) -> [MacAnalyticsMetric] {
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

nonisolated private func macAnalyticsConversationMetrics(
  messageCount: Int,
  aggregate: ChatUsageAggregate
) -> [MacAnalyticsMetric] {
  let replyCount = aggregate.assistantMessageCount
  let messagesSummary = replyCount > 0
    ? "\(messageCount.formatted()) (\(replyCount.formatted()) \(replyCount == 1 ? "reply" : "replies"))"
    : messageCount.formatted()
  return [
    .init(title: "Spend", value: macUsageAggregateCost(aggregate), symbol: "dollarsign.circle"),
    .init(title: "Messages", value: messagesSummary, symbol: "text.bubble"),
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
