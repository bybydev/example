import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation
import SwiftUI

private struct MacAnalyticsOverviewComputation: Sendable {
  let snapshot: UsageAnalyticsSnapshot
  let budgetSnapshot: UsageAnalyticsSnapshot
  let timeSeries: MacAnalyticsTimeSeries
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
  private(set) var overviewTimeSeries: MacAnalyticsTimeSeries = .empty
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
      let timeSeries = MacAnalyticsTimeSeriesBuilder.build(
        conversations: loadedConversations,
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
        timeSeries: timeSeries,
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
    overviewTimeSeries = computed.timeSeries
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

private enum MacAnalyticsBreakdownTab: String, CaseIterable, Identifiable {
  case models = "Models"
  case providers = "Providers"

  var id: String { rawValue }
}

struct MacAnalyticsView: View {
  @State private var analytics: MacAnalyticsModel
  @State private var range: UsageAnalyticsRange = .today
  @State private var section: MacAnalyticsWorkspaceSection
  @State private var selectedConversationID: String?
  @State private var conversationSearchText = ""
  @State private var chartMetric: MacAnalyticsChartMetric = .spend
  @State private var breakdownTab: MacAnalyticsBreakdownTab = .models
  @State private var showAllBreakdownRows = false
  @State private var showAllErrors = false
  @State private var confirmClearTelemetry = false
  @AppStorage("byokchat.usage.monthlyBudgetUSD") private var monthlyBudgetUSD = 0.0
  @AppStorage("byokchat.usage.budgetWarningFraction") private var budgetWarningFraction = 0.8

  @Environment(\.macAppTheme) private var theme
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

  private static let contentMaxWidth: CGFloat = 920
  private static let contentPadding: CGFloat = 16
  private static let twoColumnGrid = [
    GridItem(.flexible(), spacing: 12, alignment: .top),
    GridItem(.flexible(), spacing: 12, alignment: .top),
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
      Rectangle()
        .fill(theme.separator.opacity(0.75))
        .frame(height: 1)

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
    .frame(
      minWidth: MacDesignTokens.Sheet.workspaceMinWidth,
      minHeight: MacDesignTokens.Sheet.workspaceMinHeight
    )
    .background(theme.canvas)
    .foregroundStyle(theme.textPrimary)
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
      showAllBreakdownRows = false
      showAllErrors = false
      MacAppAnalytics.track(.analyticsRangeSelected, dimension: .init(range: accessibleRange))
    }
    .onChange(of: breakdownTab) { _, _ in
      showAllBreakdownRows = false
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

  // MARK: - Top Control Bar

  private var workspaceControls: some View {
    HStack(spacing: 10) {
      if selectedConversationID != nil {
        Button {
          selectedConversationID = nil
          section = .conversations
        } label: {
          Label("Conversations", systemImage: "chevron.left")
            .foregroundStyle(theme.accent)
        }
        .buttonStyle(MacActionButtonStyle(.subtle, size: .small))
      } else {
        MacSegmentedControl(
          options: MacAnalyticsWorkspaceSection.allCases,
          selection: $section,
          title: \.rawValue
        )
        .frame(width: 210)
      }

      Spacer(minLength: 8)

      if selectedConversationID == nil {
        inlineRangePicker
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
        Group {
          if analytics.isLoading || analytics.isLoadingConversation {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(theme.textSecondary)
          }
        }
        .frame(width: 28, height: 28)
      }
      .buttonStyle(MacIconButtonStyle())
      .disabled(analytics.isLoading || analytics.isLoadingConversation || analytics.isClearingTelemetry)
      .help("Refresh analytics")
      .accessibilityLabel("Refresh analytics")
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
    .background(theme.surface.opacity(0.65))
  }

  private var inlineRangePicker: some View {
    MacSegmentedControl(
      options: UsageAnalyticsRange.allCases,
      selection: Binding(
        get: { accessibleRange },
        set: { range = $0 }
      ),
      equalWidth: false,
      isLocked: { $0.requiresPro && !purchaseManager.hasPro },
      isOptionDisabled: {
        $0.requiresPro && !purchaseManager.hasPro && purchaseManager.entitlementState == .checking
      },
      onLockedSelect: { _ in
        MacProAccess.requestUpgrade(.analytics)
      },
      title: \.label
    )
    .accessibilityLabel("Analytics date range, \(accessibleRange.label)")
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

  // MARK: - Overview Dashboard

  private var overview: some View {
    let snapshot = analytics.overviewSnapshot
    let budget = analytics.budgetSnapshot
    let aggregate = snapshot.aggregate
    let series = analytics.overviewTimeSeries

    return ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        overviewHeroStrip(snapshot: snapshot, budget: budget, series: series)

        MacAnalyticsActivityChartCard(
          series: series,
          metric: $chartMetric
        )

        LazyVGrid(columns: Self.twoColumnGrid, alignment: .leading, spacing: 12) {
          breakdownMixCard(snapshot: snapshot)
          tokenMixCard(aggregate: aggregate)
        }

        LazyVGrid(columns: Self.twoColumnGrid, alignment: .leading, spacing: 12) {
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
            performanceAndReliabilityCard(
              snapshot.performance,
              failures: snapshot.failureBreakdown,
              includeToolAndMCP: true
            )
          }

          if !snapshot.conversationBreakdown.isEmpty {
            topChatsCard(snapshot.conversationBreakdown, overallSpend: aggregate.costUSD)
          } else {
            emptyTopChatsCard
          }
        }

        LazyVGrid(columns: Self.twoColumnGrid, alignment: .leading, spacing: 12) {
          budgetCard(budget.aggregate)
          localAnalyticsCard
        }

        Label(macUsageHistoryFootnote(aggregate), systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(theme.textMuted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 2)
      }
      .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
      .padding(Self.contentPadding)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(theme.canvas)
  }

  private func overviewHeroStrip(
    snapshot: UsageAnalyticsSnapshot,
    budget: UsageAnalyticsSnapshot,
    series: MacAnalyticsTimeSeries
  ) -> some View {
    let aggregate = snapshot.aggregate
    let performance = snapshot.performance

    let spendSubtitle: String = {
      if monthlyBudgetUSD > 0 {
        let pct = macUsagePercent(budgetProgress(budget.aggregate))
        return "\(pct) of \(macUsageFormatUSD(Decimal(monthlyBudgetUSD))) mo budget"
      }
      if series.hasKnownSpend && series.buckets.count > 1 {
        let avg = macUsageFormatUSD(Decimal(series.averageValue(for: .spend)))
        return "\(avg)/\(series.granularity.singularUnit) avg"
      }
      return "\(accessibleRange.label) total"
    }()

    let spendAccentColor: Color =
      (monthlyBudgetUSD > 0 && budgetWarningReached(budget.aggregate))
        ? theme.warning
        : theme.accent

    let tokensSubtitle: String = {
      var parts = [
        "\(macUsageCompactTokens(aggregate.inputTokens)) in",
        "\(macUsageCompactTokens(aggregate.outputTokens)) out",
      ]
      if aggregate.cachedInputTokens > 0 && aggregate.inputTokens > 0 {
        let rate = min(max(Double(aggregate.cachedInputTokens) / Double(aggregate.inputTokens), 0), 1)
        parts.append("\(macUsagePercent(rate)) cached")
      }
      return parts.joined(separator: " · ")
    }()

    let requestsSubtitle: String = {
      var parts = [
        "\(snapshot.activeConversationCount) chat\(snapshot.activeConversationCount == 1 ? "" : "s")"
      ]
      if aggregate.toolCallCount > 0 {
        parts.append("\(aggregate.toolCallCount.formatted()) tools")
      }
      return parts.joined(separator: " · ")
    }()

    let healthValue: String = {
      if let rate = performance.providerSuccessRate {
        return macUsagePercent(rate)
      }
      if let ttft = performance.medianTTFTMilliseconds {
        return macUsageDuration(ttft)
      }
      return "—"
    }()

    let healthSubtitle: String = {
      var parts: [String] = []
      if let ttft = performance.medianTTFTMilliseconds {
        parts.append("\(macUsageDuration(ttft)) TTFT")
      }
      if let speed = performance.medianOutputTokensPerSecond {
        parts.append(macUsageRate(speed))
      }
      if parts.isEmpty {
        return performance.providerRequestCount > 0
          ? "\(performance.providerRequestCount.formatted()) tracked"
          : "No recent telemetry"
      }
      return parts.joined(separator: " · ")
    }()

    let healthTint: Color = {
      guard let rate = performance.providerSuccessRate else { return theme.textMuted }
      if rate >= 0.98 { return theme.success }
      if rate >= 0.90 { return theme.warning }
      return theme.destructive
    }()

    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4),
      spacing: 10
    ) {
      MacAnalyticsHeroCard(
        title: "Spend",
        value: macUsageAggregateCost(aggregate),
        subtitle: spendSubtitle,
        symbol: "dollarsign.circle",
        tint: spendAccentColor
      )
      MacAnalyticsHeroCard(
        title: "Tokens",
        value: macUsageCompactTokens(aggregate.totalTokens),
        subtitle: tokensSubtitle,
        symbol: "sum",
        tint: Color.teal
      )
      MacAnalyticsHeroCard(
        title: "Requests",
        value: aggregate.modelRequestCount.formatted(),
        subtitle: requestsSubtitle,
        symbol: "arrow.up.arrow.down",
        tint: Color.indigo
      )
      MacAnalyticsHeroCard(
        title: "Reliability",
        value: healthValue,
        subtitle: healthSubtitle,
        symbol: "checkmark.shield",
        tint: healthTint
      )
    }
  }

  // MARK: - Models & Providers Mix Card (Capped + Expandable)

  private func breakdownMixCard(snapshot: UsageAnalyticsSnapshot) -> some View {
    let rows = breakdownTab == .models ? snapshot.modelBreakdown : snapshot.providerBreakdown
    let resolveName: (String) -> String = breakdownTab == .models
      ? { analytics.overviewModelDisplayName(for: $0) }
      : { analytics.overviewProviderDisplayName(for: $0) }

    let useCostBasis = rows.contains { $0.aggregate.hasKnownCost && $0.aggregate.costUSD > 0 }
    let metricValue: (UsageAnalyticsBreakdown) -> Double = { row in
      if useCostBasis {
        return row.aggregate.hasKnownCost
          ? max(0, NSDecimalNumber(decimal: row.aggregate.costUSD).doubleValue)
          : 0
      }
      if row.aggregate.totalTokens > 0 {
        return Double(row.aggregate.totalTokens)
      }
      return Double(max(row.aggregate.modelRequestCount, row.performance.providerRequestCount))
    }

    let totalMetric = rows.reduce(0.0) { $0 + metricValue($1) }
    let topLimit = 5
    let visibleRows = showAllBreakdownRows ? rows : Array(rows.prefix(topLimit))
    let hiddenCount = max(0, rows.count - topLimit)

    let segments: [MacAnalyticsBarSegment] = {
      var list = rows.prefix(topLimit).enumerated().map { index, row in
        MacAnalyticsBarSegment(
          id: row.id,
          label: resolveName(row.id),
          value: metricValue(row),
          color: MacAnalyticsPalette.color(at: index, accent: theme.accent)
        )
      }
      if rows.count > topLimit {
        let otherValue = rows.dropFirst(topLimit).reduce(0.0) { $0 + metricValue($1) }
        if otherValue > 0 {
          list.append(
            MacAnalyticsBarSegment(
              id: "__other__",
              label: "Other",
              value: otherValue,
              color: theme.textMuted.opacity(0.45)
            )
          )
        }
      }
      return list
    }()

    return MacAnalyticsCardContainer {
      HStack(spacing: 8) {
        Label(
          breakdownTab == .models ? "Model Share" : "Provider Share",
          systemImage: breakdownTab == .models ? "cpu" : "server.rack"
        )
        .font(.system(size: 13.5, weight: .semibold))
        .foregroundStyle(theme.textPrimary)

        Spacer(minLength: 8)

        HStack(spacing: 2) {
          ForEach(MacAnalyticsBreakdownTab.allCases) { tab in
            let isSelected = breakdownTab == tab
            Button {
              breakdownTab = tab
            } label: {
              Text(tab.rawValue)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                  isSelected ? theme.surfaceRaised : Color.clear,
                  in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(2)
        .background(theme.canvas.opacity(0.85), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(theme.border.opacity(0.8), lineWidth: 0.75)
        }
      }

      if rows.isEmpty {
        Text("Usage breakdown appears here after your first reply in this range.")
          .font(.callout)
          .foregroundStyle(theme.textMuted)
          .padding(.vertical, 8)
      } else {
        MacAnalyticsProportionalBar(segments: segments, height: 8)

        VStack(spacing: 0) {
          ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
            let rowValue = metricValue(row)
            let share = totalMetric > 0 ? rowValue / totalMetric : 0
            let dotColor = index < topLimit
              ? MacAnalyticsPalette.color(at: index, accent: theme.accent)
              : theme.textMuted.opacity(0.55)

            MacAnalyticsRankedRow(
              title: resolveName(row.id),
              aggregate: row.aggregate,
              performance: row.performance,
              share: share,
              tint: dotColor
            )

            if row.id != visibleRows.last?.id {
              Rectangle()
                .fill(theme.separator.opacity(0.55))
                .frame(height: 1)
            }
          }
        }

        if hiddenCount > 0 {
          Button {
            showAllBreakdownRows.toggle()
          } label: {
            Text(showAllBreakdownRows ? "Show top \(topLimit)" : "Show all \(rows.count)")
              .font(.caption.weight(.medium))
              .foregroundStyle(theme.accent)
          }
          .buttonStyle(.plain)
          .padding(.top, 2)
        }
      }
    }
  }

  // MARK: - Token Mix & Efficiency Card

  private func tokenMixCard(aggregate: ChatUsageAggregate) -> some View {
    let cachedInput = min(max(0, aggregate.cachedInputTokens), max(0, aggregate.inputTokens))
    let freshInput = max(0, aggregate.inputTokens - cachedInput)
    let output = max(0, aggregate.outputTokens)
    let reasoning = max(0, aggregate.reasoningTokens)
    let totalVisual = Double(freshInput + cachedInput + output + reasoning)

    let segments: [MacAnalyticsBarSegment] = [
      .init(id: "fresh-input", label: "Fresh Input", value: Double(freshInput), color: theme.accent),
      .init(id: "cached-input", label: "Cached Input", value: Double(cachedInput), color: theme.success),
      .init(id: "output", label: "Output", value: Double(output), color: Color.teal),
      .init(id: "reasoning", label: "Reasoning", value: Double(reasoning), color: Color.indigo),
    ]

    let cacheHitRate: Double? = aggregate.inputTokens > 0 && aggregate.cachedInputTokens > 0
      ? min(max(Double(aggregate.cachedInputTokens) / Double(aggregate.inputTokens), 0), 1)
      : nil

    return MacAnalyticsCardContainer {
      HStack(spacing: 8) {
        Label("Token Mix", systemImage: "square.stack.3d.up")
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(theme.textPrimary)

        Spacer(minLength: 8)

        if let cacheHitRate {
          Text("\(macUsagePercent(cacheHitRate)) cache hit")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(theme.success)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.success.opacity(0.14), in: Capsule())
        }
      }

      if aggregate.totalTokens == 0 && reasoning == 0 {
        Text("Input, cached, output, and reasoning token proportions appear here once replies are recorded.")
          .font(.callout)
          .foregroundStyle(theme.textMuted)
          .padding(.vertical, 8)
      } else {
        MacAnalyticsProportionalBar(segments: segments, height: 8)

        VStack(spacing: 8) {
          tokenMixRow(
            label: "Fresh Input",
            tokens: freshInput,
            share: totalVisual > 0 ? Double(freshInput) / totalVisual : 0,
            color: theme.accent
          )
          tokenMixRow(
            label: "Cached Input",
            tokens: cachedInput,
            share: totalVisual > 0 ? Double(cachedInput) / totalVisual : 0,
            color: theme.success
          )
          tokenMixRow(
            label: "Output",
            tokens: output,
            share: totalVisual > 0 ? Double(output) / totalVisual : 0,
            color: Color.teal
          )
          if reasoning > 0 {
            tokenMixRow(
              label: "Reasoning",
              tokens: reasoning,
              share: totalVisual > 0 ? Double(reasoning) / totalVisual : 0,
              color: Color.indigo
            )
          }
        }

        if aggregate.cacheWriteTokens > 0 || aggregate.toolCallCount > 0 {
          Rectangle()
            .fill(theme.separator.opacity(0.55))
            .frame(height: 1)

          HStack(spacing: 14) {
            if aggregate.cacheWriteTokens > 0 {
              compactBadgeStat(
                icon: "square.and.arrow.down",
                label: "Cache write",
                value: macUsageCompactTokens(aggregate.cacheWriteTokens)
              )
            }
            if aggregate.toolCallCount > 0 {
              compactBadgeStat(
                icon: "wrench.and.screwdriver",
                label: "Tool calls",
                value: aggregate.toolCallCount.formatted()
              )
            }
            Spacer(minLength: 0)
          }
        }
      }
    }
  }

  private func tokenMixRow(
    label: String,
    tokens: Int,
    share: Double,
    color: Color
  ) -> some View {
    HStack(spacing: 8) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(label)
        .font(.system(size: 12.5))
        .foregroundStyle(theme.textSecondary)
      Spacer(minLength: 12)
      Text(macUsageCompactTokens(tokens))
        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
        .foregroundStyle(theme.textPrimary)
      Text(macUsagePercent(share))
        .font(.caption.monospacedDigit())
        .foregroundStyle(theme.textMuted)
        .frame(width: 40, alignment: .trailing)
    }
  }

  private func compactBadgeStat(icon: String, label: String, value: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon)
        .font(.caption2)
        .foregroundStyle(theme.textMuted)
      Text(label)
        .font(.caption)
        .foregroundStyle(theme.textMuted)
      Text(value)
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(theme.textPrimary)
    }
  }

  // MARK: - Unified Performance & Reliability Card

  private func performanceAndReliabilityCard(
    _ performance: TelemetryPerformanceAggregate,
    failures: [TelemetryFailureBreakdown],
    includeToolAndMCP: Bool,
    singleRequestAware: Bool = false
  ) -> some View {
    let isSingleRequest = singleRequestAware && performance.providerRequestCount <= 1
    let showPercentiles = !singleRequestAware || performance.providerRequestCount >= 5
    let hasAnyTelemetry = hasPerformance(performance) || performance.hasLatencyOrSpeedMetrics || !failures.isEmpty

    return MacAnalyticsCardContainer {
      HStack(spacing: 8) {
        Label("Performance & Reliability", systemImage: "waveform.path.ecg")
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(theme.textPrimary)
        Spacer(minLength: 8)
        if let rate = performance.providerSuccessRate {
          Text("\(macUsagePercent(rate)) ok")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(rate >= 0.98 ? theme.success : (rate >= 0.9 ? theme.warning : theme.destructive))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
              (rate >= 0.98 ? theme.success : (rate >= 0.9 ? theme.warning : theme.destructive)).opacity(0.14),
              in: Capsule()
            )
        }
      }

      if !hasAnyTelemetry {
        Text("Send a few messages to start collecting local latency, speed, and reliability metrics.")
          .font(.callout)
          .foregroundStyle(theme.textMuted)
          .padding(.vertical, 8)
      } else {
        if performance.providerRequestCount > 0 {
          let healthSegments: [MacAnalyticsBarSegment] = [
            .init(id: "ok", label: "Succeeded", value: Double(performance.providerSuccessCount), color: theme.success),
            .init(id: "fail", label: "Failed", value: Double(performance.providerFailureCount), color: theme.destructive),
            .init(id: "cancel", label: "Cancelled", value: Double(performance.providerCancelledCount), color: theme.textMuted.opacity(0.55)),
          ]

          VStack(alignment: .leading, spacing: 6) {
            MacAnalyticsProportionalBar(segments: healthSegments, height: 7)

            HStack(spacing: 12) {
              healthCountPill(label: "OK", count: performance.providerSuccessCount, color: theme.success)
              if performance.providerFailureCount > 0 {
                healthCountPill(label: "Failed", count: performance.providerFailureCount, color: theme.destructive)
              }
              if performance.providerCancelledCount > 0 {
                healthCountPill(label: "Cancelled", count: performance.providerCancelledCount, color: theme.textMuted)
              }
              Spacer(minLength: 0)
            }
          }
        }

        if performance.hasLatencyOrSpeedMetrics {
          HStack(spacing: 8) {
            latencyTile(
              title: isSingleRequest ? "TTFT" : "Median TTFT",
              value: macUsageDuration(performance.medianTTFTMilliseconds),
              footnote: showPercentiles ? performance.p95TTFTMilliseconds.map { "P95 \(macUsageDuration($0))" } : nil
            )
            latencyTile(
              title: isSingleRequest ? "Duration" : "Median Dur.",
              value: macUsageDuration(performance.medianDurationMilliseconds),
              footnote: showPercentiles ? performance.p95DurationMilliseconds.map { "P95 \(macUsageDuration($0))" } : nil
            )
            latencyTile(
              title: isSingleRequest ? "Speed" : "Median Speed",
              value: macUsageRate(performance.medianOutputTokensPerSecond),
              footnote: nil
            )
          }
        }

        if includeToolAndMCP && (performance.toolCallCount > 0 || performance.mcpRequestCount > 0) {
          Rectangle()
            .fill(theme.separator.opacity(0.55))
            .frame(height: 1)

          VStack(spacing: 6) {
            if performance.toolCallCount > 0 {
              MacAnalyticsLabeledRow(
                "Tools (\(performance.toolCallCount.formatted()))",
                value: "\(macUsagePercent(performance.toolSuccessRate)) ok"
                  + (performance.toolFailureCount > 0 ? " · \(performance.toolFailureCount) err" : "")
              )
            }
            if performance.mcpRequestCount > 0 {
              MacAnalyticsLabeledRow(
                "MCP Requests",
                value: "\(performance.mcpRequestCount.formatted())"
                  + (performance.mcpFailureCount > 0 ? " · \(performance.mcpFailureCount) failed" : "")
              )
            }
          }
        }

        if !failures.isEmpty {
          Rectangle()
            .fill(theme.separator.opacity(0.55))
            .frame(height: 1)

          let displayed = showAllErrors ? failures : Array(failures.prefix(4))
          VStack(alignment: .leading, spacing: 6) {
            Text("Recent Error Codes")
              .font(.caption.weight(.semibold))
              .foregroundStyle(theme.textSecondary)

            ForEach(displayed) { failure in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                  Text(macAnalyticsErrorTitle(failure.errorCode))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                  Text("\(macUsageCategoryTitle(failure.category)) · \(failure.classification.replacingOccurrences(of: "_", with: " "))")
                    .font(.caption2)
                    .foregroundStyle(theme.textMuted)
                }
                Spacer(minLength: 8)
                Text(failure.count.formatted())
                  .font(.caption.weight(.semibold).monospacedDigit())
                  .foregroundStyle(theme.warning)
              }
            }

            if failures.count > 4 {
              Button {
                showAllErrors.toggle()
              } label: {
                Text(showAllErrors ? "Show fewer errors" : "Show all \(failures.count) error codes")
                  .font(.caption.weight(.medium))
                  .foregroundStyle(theme.accent)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
  }

  private func healthCountPill(label: String, count: Int, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text("\(count.formatted()) \(label)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(theme.textSecondary)
    }
  }

  private func latencyTile(title: String, value: String, footnote: String?) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(theme.textMuted)
        .lineLimit(1)
      Text(value)
        .font(.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(theme.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      if let footnote {
        Text(footnote)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(theme.textMuted)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(theme.border.opacity(0.65), lineWidth: 0.5)
    }
  }

  // MARK: - Top Chats Card

  private func topChatsCard(
    _ rows: [ConversationUsageBreakdown],
    overallSpend: Decimal
  ) -> some View {
    let topRows = Array(rows.prefix(5))
    let totalCost = NSDecimalNumber(decimal: overallSpend).doubleValue
    let totalTokens = rows.reduce(0) { $0 + $1.aggregate.totalTokens }

    return MacAnalyticsCardContainer {
      HStack(spacing: 8) {
        Label("Top Chats", systemImage: "bubble.left.and.bubble.right")
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(theme.textPrimary)
        Spacer(minLength: 8)
        if rows.count > 5 {
          Button {
            section = .conversations
          } label: {
            Text("All \(rows.count)")
              .font(.caption.weight(.medium))
              .foregroundStyle(theme.accent)
          }
          .buttonStyle(.plain)
        }
      }

      VStack(spacing: 0) {
        ForEach(topRows) { item in
          let share: Double = {
            if totalCost > 0 && item.aggregate.hasKnownCost {
              return min(max(NSDecimalNumber(decimal: item.aggregate.costUSD).doubleValue / totalCost, 0), 1)
            }
            if totalTokens > 0 {
              return min(max(Double(item.aggregate.totalTokens) / Double(totalTokens), 0), 1)
            }
            return 0
          }()

          MacAnalyticsTopChatRow(item: item, share: share) {
            section = .conversations
            selectedConversationID = item.id.rawValue
          }

          if item.id != topRows.last?.id {
            Rectangle()
              .fill(theme.separator.opacity(0.55))
              .frame(height: 1)
          }
        }
      }
    }
  }

  private var emptyTopChatsCard: some View {
    MacAnalyticsCardContainer {
      Label("Top Chats", systemImage: "bubble.left.and.bubble.right")
        .font(.system(size: 13.5, weight: .semibold))
        .foregroundStyle(theme.textPrimary)

      Text("Your highest-usage conversations in this range will appear here.")
        .font(.callout)
        .foregroundStyle(theme.textMuted)
        .padding(.vertical, 8)
    }
  }

  // MARK: - Conversations Tab

  private var conversations: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          MacAnalyticsSearchField(
            placeholder: "Search conversations",
            text: $conversationSearchText
          )
          .frame(maxWidth: 340)

          Spacer(minLength: 8)

          Text("\(filteredConversations.count) conversation\(filteredConversations.count == 1 ? "" : "s") · \(accessibleRange.label)")
            .font(.caption)
            .foregroundStyle(theme.textMuted)
        }

        if filteredConversations.isEmpty {
          if conversationSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
              "No Conversations",
              systemImage: "bubble.left.and.bubble.right",
              description: Text("Start chatting to see per-conversation analytics here.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 56)
          } else {
            ContentUnavailableView.search(text: conversationSearchText)
              .frame(maxWidth: .infinity)
              .padding(.top, 56)
          }
        } else {
          LazyVStack(spacing: 8) {
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
    .background(theme.canvas)
  }

  private func conversationCard(_ conversation: ChatConversation) -> some View {
    let aggregate = analytics.overviewAggregate(for: conversation.id)
    let title = conversation.title.isEmpty ? "New Chat" : conversation.title

    return Button {
      selectedConversationID = conversation.id.rawValue
    } label: {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
          HStack(spacing: 10) {
            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(theme.textMuted)
            conversationStat(aggregate.modelRequestCount.formatted(), label: "req")
            conversationStat(macUsageCompactTokens(aggregate.totalTokens), label: "tok")
          }
        }

        Spacer(minLength: 12)

        Text(macUsageAggregateCost(aggregate))
          .font(.system(size: 13, weight: .semibold).monospacedDigit())
          .foregroundStyle(theme.textPrimary)

        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(theme.textMuted)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(MacCardButtonStyle(cornerRadius: 10))
  }

  private func conversationStat(_ value: String, label: String) -> some View {
    HStack(spacing: 3) {
      Text(value)
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(theme.textSecondary)
      Text(label)
        .font(.caption)
        .foregroundStyle(theme.textMuted)
    }
  }

  // MARK: - Conversation Detail

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
          VStack(alignment: .leading, spacing: 14) {
            analyticsHeading(title: title, subtitle: subtitle)

            conversationHeroStrip(
              messageCount: conversation.messages.count,
              snapshot: snapshot
            )

            if let contextUsage {
              contextWindowCard(contextUsage)
            }

            LazyVGrid(columns: Self.twoColumnGrid, alignment: .leading, spacing: 12) {
              tokenMixCard(aggregate: snapshot.aggregate)

              if analytics.conversationTelemetryUnavailable {
                telemetryUnavailableCard(isDisabled: analytics.isLoadingConversation) {
                  Task { await analytics.loadConversation(conversation, retry: true) }
                }
              } else if !hasPerformance(snapshot.performance) && snapshot.failureBreakdown.isEmpty {
                noConversationTelemetryCard(
                  hasSavedReplies: snapshot.aggregate.assistantMessageCount > 0
                )
              } else {
                performanceAndReliabilityCard(
                  snapshot.performance,
                  failures: snapshot.failureBreakdown,
                  includeToolAndMCP: true,
                  singleRequestAware: true
                )
              }
            }

            if !snapshot.providerBreakdown.isEmpty || !snapshot.modelBreakdown.isEmpty {
              LazyVGrid(columns: Self.twoColumnGrid, alignment: .leading, spacing: 12) {
                if !snapshot.modelBreakdown.isEmpty {
                  MacAnalyticsSection(title: "Models", symbol: "cpu") {
                    MacAnalyticsBreakdownList(
                      rows: snapshot.modelBreakdown,
                      displayName: { analytics.conversationModelDisplayName(for: $0) }
                    )
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
              }
            }

            Label(macUsageHistoryFootnote(snapshot.aggregate), systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(theme.textMuted)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
          .padding(Self.contentPadding)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(theme.canvas)
      }
    }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isCurrentConversationLoaded
    )
  }

  private func conversationHeroStrip(
    messageCount: Int,
    snapshot: ConversationUsageAnalyticsSnapshot
  ) -> some View {
    let aggregate = snapshot.aggregate
    let performance = snapshot.performance
    let replyCount = aggregate.assistantMessageCount

    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4),
      spacing: 10
    ) {
      MacAnalyticsHeroCard(
        title: "Spend",
        value: macUsageAggregateCost(aggregate),
        subtitle: "\(aggregate.modelRequestCount.formatted()) request\(aggregate.modelRequestCount == 1 ? "" : "s")",
        symbol: "dollarsign.circle",
        tint: theme.accent
      )
      MacAnalyticsHeroCard(
        title: "Tokens",
        value: macUsageCompactTokens(aggregate.totalTokens),
        subtitle: "\(macUsageCompactTokens(aggregate.inputTokens)) in · \(macUsageCompactTokens(aggregate.outputTokens)) out",
        symbol: "sum",
        tint: Color.teal
      )
      MacAnalyticsHeroCard(
        title: "Messages",
        value: messageCount.formatted(),
        subtitle: "\(replyCount.formatted()) \(replyCount == 1 ? "reply" : "replies")",
        symbol: "text.bubble",
        tint: Color.indigo
      )
      MacAnalyticsHeroCard(
        title: "Speed",
        value: macUsageRate(performance.medianOutputTokensPerSecond),
        subtitle: performance.medianTTFTMilliseconds.map { "\(macUsageDuration($0)) TTFT" } ?? "No recent telemetry",
        symbol: "gauge.with.dots.needle.67percent",
        tint: theme.success
      )
    }
  }

  private func contextWindowCard(_ contextUsage: ConversationContextUsage) -> some View {
    MacAnalyticsSection(title: "Context Window", symbol: "gauge.with.dots.needle.33percent") {
      VStack(alignment: .leading, spacing: 9) {
        if let window = contextUsage.contextWindow, let fill = contextUsage.fillFraction {
          MacAnalyticsLabeledRow(
            "Latest Turn",
            value: "\(macUsageCompactTokens(contextUsage.usedInputTokens)) / \(macUsageCompactTokens(window)) (\(macUsagePercent(fill)))"
          )
          ProgressView(value: fill)
            .tint(fill >= 0.95 ? theme.destructive : fill >= 0.8 ? theme.warning : theme.accent)
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
          .foregroundStyle(theme.warning)
        }

        Text(
          contextUsage.isEstimated
            ? "Estimated from the latest built request context."
            : "Based on the latest request's input tokens."
        )
        .font(.caption)
        .foregroundStyle(theme.textMuted)
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
          .foregroundStyle(theme.textSecondary)

        Button("Retry", action: retryAction)
          .buttonStyle(MacActionButtonStyle(.primary, size: .small))
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
      .font(.callout)
      .foregroundStyle(theme.textMuted)
    }
  }

  // MARK: - Budget & Local Telemetry Cards

  private func budgetCard(_ aggregate: ChatUsageAggregate) -> some View {
    MacAnalyticsSection(title: "Monthly Budget", symbol: "gauge.with.needle") {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 8) {
          Text("Limit")
            .font(.system(size: 12.5))
            .foregroundStyle(theme.textSecondary)
          Spacer()
          Text("$")
            .font(.system(size: 12.5))
            .foregroundStyle(theme.textMuted)
          TextField(
            "0",
            value: $monthlyBudgetUSD,
            format: .number.precision(.fractionLength(0...2))
          )
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 92)
        }

        HStack(spacing: 8) {
          Text("Warn at")
            .font(.system(size: 12.5))
            .foregroundStyle(theme.textSecondary)
          Spacer()
          Picker("Warn at", selection: $budgetWarningFraction) {
            Text("50%").tag(0.5)
            Text("75%").tag(0.75)
            Text("80%").tag(0.8)
            Text("90%").tag(0.9)
          }
          .labelsHidden()
          .frame(width: 92)
        }

        if monthlyBudgetUSD > 0 {
          let progress = budgetProgress(aggregate)
          ProgressView(value: progress)
            .tint(progress >= 1 ? theme.destructive : (budgetWarningReached(aggregate) ? theme.warning : theme.accent))
          MacAnalyticsLabeledRow(
            purchaseManager.hasPro ? "This Month" : "Today Only",
            value: "\(macUsageAggregateCost(aggregate)) (\(macUsagePercent(progress)))"
          )
          if budgetWarningReached(aggregate) {
            Label("Budget warning threshold reached", systemImage: "exclamationmark.triangle.fill")
              .font(.caption.weight(.medium))
              .foregroundStyle(theme.warning)
          }
        }

        Text(purchaseManager.hasPro
          ? "Local warning only; does not set provider spending caps or track other apps."
          : "Free evaluates today's saved usage only. Pro includes the full calendar month.")
          .font(.caption)
          .foregroundStyle(theme.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var localAnalyticsCard: some View {
    MacAnalyticsSection(title: "Local Telemetry", symbol: "internaldrive") {
      VStack(alignment: .leading, spacing: 8) {
        if analytics.overviewTelemetryUnavailable {
          MacAnalyticsLabeledRow("Telemetry", value: "Unavailable")
        } else {
          MacAnalyticsLabeledRow("Detailed Events", value: analytics.telemetryEvents.count.formatted())
          if analytics.statistics.rollupRowCount > 0 {
            MacAnalyticsLabeledRow("Daily Rollups", value: analytics.statistics.rollupRowCount.formatted())
          }
        }
        if analytics.statistics.databaseBytes > 0 {
          MacAnalyticsLabeledRow(
            "Database Size",
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
          .foregroundStyle(theme.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func analyticsHeading(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(theme.textPrimary)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(theme.textSecondary)
    }
  }

  private var telemetryFootnote: String {
    if !purchaseManager.hasPro {
      return "Only today's telemetry is shown on Free. Detailed events stay on device for 30 days and roll up daily."
    }
    if analytics.telemetryEvents.count >= TelemetryStoreConfiguration.maximumRecentEventQueryCount {
      let limit = TelemetryStoreConfiguration.maximumRecentEventQueryCount.formatted()
      return "Uses up to \(limit) recent detailed events plus archived daily rollups. Chat history keeps usage and spend."
    }
    return "Detailed events stay on device for 30 days before rolling up daily. Chat usage and spend come from saved chats."
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

// MARK: - Redesigned Cards & Components

private struct MacAnalyticsHeroCard: View {
  let title: String
  let value: String
  let subtitle: String
  let symbol: String
  let tint: Color

  @Environment(\.macAppTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 5) {
        Image(systemName: symbol)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(tint)
        Text(title.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(theme.textMuted)
          .lineLimit(1)
      }

      Text(value)
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .foregroundStyle(theme.textPrimary)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.72)

      Text(subtitle)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
    .padding(12)
    .background(
      theme.surface,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.border, lineWidth: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue("\(value), \(subtitle)")
  }
}

private struct MacAnalyticsCardContainer<Content: View>: View {
  @Environment(\.macAppTheme) private var theme
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      theme.surface,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.border, lineWidth: 1)
    }
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

  @Environment(\.macAppTheme) private var theme

  private static let columns = Array(
    repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
    count: 4
  )

  var body: some View {
    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
      ForEach(metrics) { metric in
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 5) {
            Image(systemName: metric.symbol)
            Text(metric.title.uppercased())
              .lineLimit(1)
          }
          .font(.caption2.weight(.semibold))
          .foregroundStyle(theme.textMuted)

          Text(metric.value)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(12)
        .background(
          theme.surface,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(theme.border, lineWidth: 1)
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

  @Environment(\.macAppTheme) private var theme

  init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.symbol = symbol
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Label(title, systemImage: symbol)
        .font(.system(size: 13.5, weight: .semibold))
        .foregroundStyle(theme.textPrimary)
        .accessibilityAddTraits(.isHeader)

      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      theme.surface,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.border, lineWidth: 1)
    }
  }
}

private struct MacAnalyticsRankedRow: View {
  let title: String
  let aggregate: ChatUsageAggregate
  let performance: TelemetryPerformanceAggregate
  let share: Double
  let tint: Color

  @Environment(\.macAppTheme) private var theme

  private var hasSavedMessages: Bool {
    aggregate.assistantMessageCount > 0
  }

  private var secondaryLine: String {
    var parts: [String] = []
    if hasSavedMessages {
      parts.append("\(macUsageCompactTokens(aggregate.totalTokens)) tok")
      parts.append(macUsageRequestCountLabel(aggregate.modelRequestCount))
    } else if performance.providerRequestCount > 0 {
      parts.append(macUsageRequestCountLabel(performance.providerRequestCount))
    }
    if let ttft = performance.medianTTFTMilliseconds {
      parts.append("\(macUsageDuration(ttft)) TTFT")
    }
    if let speed = performance.medianOutputTokensPerSecond {
      parts.append(macUsageRate(speed))
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Circle()
          .fill(tint)
          .frame(width: 7, height: 7)

        Text(title)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(theme.textPrimary)
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer(minLength: 8)

        Text(
          hasSavedMessages || performance.providerRequestCount == 0
            ? macUsageAggregateCost(aggregate)
            : "—"
        )
        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(theme.textPrimary)

        if share > 0 {
          Text(macUsagePercent(share))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(theme.textMuted)
            .frame(width: 34, alignment: .trailing)
        }
      }

      if !secondaryLine.isEmpty {
        Text(secondaryLine)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(theme.textMuted)
          .lineLimit(1)
          .padding(.leading, 15)
      }
    }
    .padding(.vertical, 7)
  }
}

private struct MacAnalyticsTopChatRow: View {
  let item: ConversationUsageBreakdown
  let share: Double
  let action: () -> Void

  @Environment(\.macAppTheme) private var theme
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .center, spacing: 8) {
          Text(item.title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)

          Spacer(minLength: 8)

          Text(macUsageAggregateCost(item.aggregate))
            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(theme.textPrimary)

          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isHovered ? theme.textPrimary : theme.textMuted)
        }

        HStack(spacing: 8) {
          Text(
            "\(macUsageCompactTokens(item.aggregate.totalTokens)) tok · \(macUsageRequestCountLabel(item.aggregate.modelRequestCount))"
          )
          .font(.caption2.monospacedDigit())
          .foregroundStyle(theme.textMuted)
          .lineLimit(1)

          Spacer(minLength: 8)

          if share > 0 {
            GeometryReader { proxy in
              ZStack(alignment: .leading) {
                Capsule()
                  .fill(theme.separator.opacity(0.45))
                Capsule()
                  .fill(theme.accent.opacity(0.75))
                  .frame(width: max(3, proxy.size.width * share))
              }
            }
            .frame(width: 56, height: 4)
          }
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 7)
      .background(
        isHovered ? theme.selection.opacity(0.6) : Color.clear,
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

private struct MacAnalyticsHeroSkeleton: View {
  @Environment(\.macAppTheme) private var theme

  private static let columns = Array(
    repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
    count: 4
  )

  var body: some View {
    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
      ForEach(0..<4, id: \.self) { index in
        VStack(alignment: .leading, spacing: 10) {
          MacAnalyticsSkeletonBar(width: 64, height: 9, opacity: 0.075)
          MacAnalyticsSkeletonBar(width: index == 0 ? 92 : 76, height: 19, opacity: 0.11)
          MacAnalyticsSkeletonBar(width: 112, height: 9, opacity: 0.065)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(12)
        .background(
          theme.surface,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(theme.border.opacity(0.8), lineWidth: 1)
        }
      }
    }
  }
}

private struct MacAnalyticsChartSkeleton: View {
  @Environment(\.macAppTheme) private var theme

  private static let barHeights: [CGFloat] = [38, 62, 48, 84, 72, 108, 66, 94, 52, 118, 88, 64]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        MacAnalyticsSkeletonBar(width: 130, height: 13, opacity: 0.10)
        Spacer()
        MacAnalyticsSkeletonBar(width: 150, height: 22, opacity: 0.08)
      }

      HStack(alignment: .bottom, spacing: 8) {
        ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
      }
      .frame(height: 158, alignment: .bottom)
    }
    .padding(14)
    .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.border.opacity(0.8), lineWidth: 1)
    }
  }
}

private struct MacAnalyticsSectionSkeleton: View {
  let rowCount: Int

  @Environment(\.macAppTheme) private var theme

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
      theme.surface,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.border.opacity(0.8), lineWidth: 1)
    }
  }
}

private struct MacAnalyticsOverviewSkeleton: View {
  let subtitle: String

  @Environment(\.macAppTheme) private var theme

  private static let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(theme.textMuted)

        VStack(alignment: .leading, spacing: 14) {
          MacAnalyticsHeroSkeleton()
          MacAnalyticsChartSkeleton()
          LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
            MacAnalyticsSectionSkeleton(rowCount: 4)
            MacAnalyticsSectionSkeleton(rowCount: 4)
          }
        }
        .modifier(MacAnalyticsSkeletonPulse())
      }
      .frame(maxWidth: 920, alignment: .leading)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(theme.canvas)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading analytics overview")
  }
}

private struct MacAnalyticsConversationsSkeleton: View {
  @Environment(\.macAppTheme) private var theme

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(theme.surface)
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(theme.border.opacity(0.8), lineWidth: 1)
          }
          .frame(maxWidth: 340, minHeight: 32, maxHeight: 32)

        VStack(spacing: 8) {
          ForEach(0..<5, id: \.self) { index in
            HStack {
              VStack(alignment: .leading, spacing: 8) {
                MacAnalyticsSkeletonBar(
                  width: index.isMultiple(of: 2) ? 220 : 170,
                  height: 12,
                  opacity: 0.095
                )
                MacAnalyticsSkeletonBar(width: 150, height: 9, opacity: 0.065)
              }
              Spacer()
              MacAnalyticsSkeletonBar(width: 58, height: 12, opacity: 0.09)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.border.opacity(0.8), lineWidth: 1)
            }
          }
        }
        .modifier(MacAnalyticsSkeletonPulse())
      }
      .frame(maxWidth: 920, alignment: .leading)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(theme.canvas)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading conversations analytics")
  }
}

private struct MacAnalyticsConversationDetailSkeleton: View {
  let title: String?
  let subtitle: String?

  @Environment(\.macAppTheme) private var theme

  private static let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let title, let subtitle {
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(theme.textPrimary)
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(theme.textSecondary)
          }
        } else {
          VStack(alignment: .leading, spacing: 6) {
            MacAnalyticsSkeletonBar(width: 220, height: 16, opacity: 0.10)
            MacAnalyticsSkeletonBar(width: 260, height: 10, opacity: 0.07)
          }
          .modifier(MacAnalyticsSkeletonPulse())
        }

        VStack(alignment: .leading, spacing: 14) {
          MacAnalyticsHeroSkeleton()
          MacAnalyticsSectionSkeleton(rowCount: 2)
          LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
            MacAnalyticsSectionSkeleton(rowCount: 4)
            MacAnalyticsSectionSkeleton(rowCount: 4)
          }
        }
        .modifier(MacAnalyticsSkeletonPulse())
      }
      .frame(maxWidth: 920, alignment: .leading)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(theme.canvas)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading conversation analytics")
  }
}

struct MacAnalyticsLabeledRow: View {
  let title: String
  let value: String

  @Environment(\.macAppTheme) private var theme

  init(_ title: String, value: String) {
    self.title = title
    self.value = value
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .foregroundStyle(theme.textSecondary)
      Spacer(minLength: 16)
      Text(value)
        .foregroundStyle(theme.textPrimary)
        .monospacedDigit()
        .textSelection(.enabled)
    }
    .font(.system(size: 12.5))
  }
}

private struct MacAnalyticsBreakdownRowContent: View {
  let title: String
  let aggregate: ChatUsageAggregate
  let performance: TelemetryPerformanceAggregate

  @Environment(\.macAppTheme) private var theme

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
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(theme.textPrimary)
          .lineLimit(1)

        if hasSavedMessages {
          Text(
            "\(macUsageCompactTokens(aggregate.totalTokens)) tokens · \(macUsageRequestCountLabel(aggregate.modelRequestCount))"
          )
          .font(.caption)
          .foregroundStyle(theme.textMuted)
        } else if performance.providerRequestCount > 0 {
          Text("\(macUsageRequestCountLabel(performance.providerRequestCount)) · no saved messages")
            .font(.caption)
            .foregroundStyle(theme.textMuted)
        }

        if let performanceSummaryLine {
          Text(performanceSummaryLine)
            .font(.caption2)
            .foregroundStyle(theme.textMuted)
            .monospacedDigit()
        }
      }

      Spacer(minLength: 12)

      Text(
        hasSavedMessages || performance.providerRequestCount == 0
          ? macUsageAggregateCost(aggregate)
          : "—"
      )
      .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
      .foregroundStyle(theme.textPrimary)
    }
  }
}

private struct MacAnalyticsBreakdownList: View {
  let rows: [UsageAnalyticsBreakdown]
  let displayName: (String) -> String

  @Environment(\.macAppTheme) private var theme

  var body: some View {
    VStack(spacing: 0) {
      ForEach(rows) { row in
        MacAnalyticsBreakdownRowContent(
          title: displayName(row.id),
          aggregate: row.aggregate,
          performance: row.performance
        )
        .padding(.vertical, 7)

        if row.id != rows.last?.id {
          Rectangle()
            .fill(theme.separator.opacity(0.55))
            .frame(height: 1)
        }
      }
    }
  }
}

struct MacAnalyticsSearchField: View {
  let placeholder: String
  @Binding var text: String

  @Environment(\.macAppTheme) private var theme

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(theme.textMuted)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .foregroundStyle(theme.textPrimary)
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(theme.textMuted)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(theme.border, lineWidth: 1)
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
