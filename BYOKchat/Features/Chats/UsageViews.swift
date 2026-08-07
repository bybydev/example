import BYOKchatProviderCore
import Foundation
import SwiftUI

struct MessageInfoView: View {
  let message: ChatMessage
  let accountLabel: String?

  @Environment(\.dismiss) private var dismiss

  private var billing: ChatBillingSnapshot { ChatBilling.snapshot(for: message) }

  var body: some View {
    NavigationStack {
      List {
        Section("Model") {
          if let providerID = message.providerID {
            LabeledContent("Provider", value: displayName(providerID.rawValue))
          }
          if let accountLabel, !accountLabel.isEmpty {
            LabeledContent("Account", value: accountLabel)
          }
          if let modelID = message.modelID {
            LabeledContent("Model", value: modelID.rawValue)
          }
        }

        if let usage = message.usage {
          Section("Usage") {
            if let value = usage.inputTokens {
              LabeledContent("Input", value: tokenCount(value))
            }
            if let value = usage.cachedInputTokens, value > 0 {
              LabeledContent("Cached input", value: tokenCount(value))
            }
            if let value = usage.outputTokens {
              LabeledContent("Output", value: tokenCount(value))
            }
            if let value = usage.reasoningTokens, value > 0 {
              LabeledContent("Reasoning", value: tokenCount(value))
            }

            LabeledContent(costLabel, value: costValue)
          } footer: {
            Text(costFootnote)
          }
        }

        if billing.inputPricePerToken != nil || billing.outputPricePerToken != nil {
          Section("Pricing snapshot") {
            if let price = billing.inputPricePerToken {
              LabeledContent("Input / 1M", value: pricePerMillion(price))
            }
            if let price = billing.outputPricePerToken {
              LabeledContent("Output / 1M", value: pricePerMillion(price))
            }
          } footer: {
            Text("The price snapshot is stored with this message so later model price changes do not rewrite historical spend.")
          }
        }

        Section("Request") {
          if billing.modelRequestCount > 0 {
            LabeledContent("Model requests", value: String(billing.modelRequestCount))
          }
          if billing.toolCallCount > 0 {
            LabeledContent("Tool calls", value: String(billing.toolCallCount))
          }
          if let finishReason = message.finishReason, !finishReason.isEmpty {
            LabeledContent("Finish reason", value: finishReason)
          }
          LabeledContent("Generated") {
            Text(message.updatedAt, format: .dateTime.year().month().day().hour().minute().second())
              .multilineTextAlignment(.trailing)
          }
        }
      }
      .navigationTitle("Message Info")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var costLabel: String {
    switch billing.accuracy {
    case .providerReported: "Cost"
    case .calculated: "Estimated cost"
    case .unavailable: "Cost"
    }
  }

  private var costValue: String {
    guard let cost = billing.costUSD else { return "Unavailable" }
    let prefix = billing.accuracy == .calculated ? "~" : ""
    return prefix + formatUSD(cost)
  }

  private var costFootnote: String {
    switch billing.accuracy {
    case .providerReported:
      "Cost was reported by the provider for this request."
    case .calculated:
      "Estimated from the token usage and model pricing snapshot recorded when this response completed."
    case .unavailable:
      "Token usage is available, but this model did not expose pricing to BYOKchat."
    }
  }
}

struct UsageDashboardView: View {
  let conversations: [ChatConversation]
  let currentConversationID: ConversationID?

  @Environment(\.dismiss) private var dismiss
  @AppStorage("byokchat.usage.monthlyBudgetUSD") private var monthlyBudgetUSD = 0.0
  @AppStorage("byokchat.usage.budgetWarningFraction") private var budgetWarningFraction = 0.8
  @State private var range: UsageRange = .month

  init(
    conversations: [ChatConversation],
    currentConversationID: ConversationID? = nil
  ) {
    self.conversations = conversations
    self.currentConversationID = currentConversationID
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("Range", selection: $range) {
            ForEach(UsageRange.allCases) { value in
              Text(value.label).tag(value)
            }
          }
          .pickerStyle(.segmented)
        }

        Section("Summary") {
          LabeledContent("Spend", value: aggregateCostText(filteredAggregate))
          LabeledContent("Input", value: compactTokens(filteredAggregate.inputTokens))
          LabeledContent("Output", value: compactTokens(filteredAggregate.outputTokens))
          if filteredAggregate.cachedInputTokens > 0 {
            LabeledContent("Cached input", value: compactTokens(filteredAggregate.cachedInputTokens))
          }
          LabeledContent("Model requests", value: filteredAggregate.modelRequestCount.formatted())
          if filteredAggregate.toolCallCount > 0 {
            LabeledContent("Tool calls", value: filteredAggregate.toolCallCount.formatted())
          }
        } footer: {
          if filteredAggregate.hasPartialCost {
            Text("Spend is partial because some models did not expose pricing.")
          } else {
            Text("Only requests made by BYOKchat are included.")
          }
        }

        if let conversationAggregate = currentConversationAggregate {
          Section("This conversation") {
            LabeledContent("Spend", value: aggregateCostText(conversationAggregate))
            LabeledContent("Input", value: compactTokens(conversationAggregate.inputTokens))
            LabeledContent("Output", value: compactTokens(conversationAggregate.outputTokens))
            LabeledContent("Model requests", value: conversationAggregate.modelRequestCount.formatted())
          }
        }

        if !providerBreakdown.isEmpty {
          Section("Providers") {
            ForEach(providerBreakdown) { row in
              UsageBreakdownRowView(row: row)
            }
          }
        }

        if !modelBreakdown.isEmpty {
          Section("Models") {
            ForEach(modelBreakdown) { row in
              UsageBreakdownRowView(row: row)
            }
          }
        }

        Section("Monthly budget") {
          HStack {
            Text("Budget")
            Spacer()
            Text("$")
              .foregroundStyle(.secondary)
            TextField("0", value: $monthlyBudgetUSD, format: .number.precision(.fractionLength(0...2)))
              .keyboardType(.decimalPad)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: 100)
          }

          Picker("Warn at", selection: $budgetWarningFraction) {
            Text("50%").tag(0.5)
            Text("75%").tag(0.75)
            Text("80%").tag(0.8)
            Text("90%").tag(0.9)
          }

          if monthlyBudgetUSD > 0 {
            ProgressView(value: budgetProgress)
            LabeledContent("This month", value: aggregateCostText(currentMonthAggregate))
            if budgetWarningReached {
              Label("Budget warning threshold reached", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }
          }
        } footer: {
          Text("The budget is a local BYOKchat warning. It does not include API-key usage from other apps and does not change provider-side spending limits.")
        }
      }
      .navigationTitle("Usage")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var filteredMessages: [ChatMessage] {
    messages(since: range.startDate(reference: .now))
  }

  private var filteredAggregate: ChatUsageAggregate {
    ChatBilling.aggregate(messages: filteredMessages)
  }

  private var currentConversationAggregate: ChatUsageAggregate? {
    guard let currentConversationID,
      let conversation = conversations.first(where: { $0.id == currentConversationID })
    else { return nil }
    return ChatBilling.aggregate(messages: conversation.messages)
  }

  private var currentMonthAggregate: ChatUsageAggregate {
    ChatBilling.aggregate(messages: messages(since: UsageRange.month.startDate(reference: .now)))
  }

  private var providerBreakdown: [UsageBreakdown] {
    breakdown { message in
      message.providerID.map { displayName($0.rawValue) }
    }
  }

  private var modelBreakdown: [UsageBreakdown] {
    breakdown { message in message.modelID?.rawValue }
  }

  private func breakdown(key: (ChatMessage) -> String?) -> [UsageBreakdown] {
    var values: [String: ChatUsageAggregate] = [:]
    for message in filteredMessages where message.role == .assistant {
      guard let name = key(message), !name.isEmpty else { continue }
      var aggregate = values[name] ?? ChatUsageAggregate()
      aggregate.add(message)
      values[name] = aggregate
    }
    return values.map { UsageBreakdown(id: $0.key, title: $0.key, aggregate: $0.value) }
      .sorted { lhs, rhs in
        if lhs.aggregate.costUSD != rhs.aggregate.costUSD {
          return lhs.aggregate.costUSD > rhs.aggregate.costUSD
        }
        return lhs.aggregate.inputTokens + lhs.aggregate.outputTokens
          > rhs.aggregate.inputTokens + rhs.aggregate.outputTokens
      }
  }

  private func messages(since startDate: Date?) -> [ChatMessage] {
    conversations.flatMap(\.messages).filter { message in
      guard message.role == .assistant else { return false }
      guard let startDate else { return true }
      return message.updatedAt >= startDate
    }
  }

  private var budgetProgress: Double {
    guard monthlyBudgetUSD > 0 else { return 0 }
    let spent = NSDecimalNumber(decimal: currentMonthAggregate.costUSD).doubleValue
    return min(max(spent / monthlyBudgetUSD, 0), 1)
  }

  private var budgetWarningReached: Bool {
    guard monthlyBudgetUSD > 0 else { return false }
    let spent = NSDecimalNumber(decimal: currentMonthAggregate.costUSD).doubleValue
    return spent >= monthlyBudgetUSD * budgetWarningFraction
  }
}

private enum UsageRange: String, CaseIterable, Identifiable {
  case today
  case sevenDays
  case thirtyDays
  case month
  case all

  var id: String { rawValue }

  var label: String {
    switch self {
    case .today: "Today"
    case .sevenDays: "7D"
    case .thirtyDays: "30D"
    case .month: "Month"
    case .all: "All"
    }
  }

  func startDate(reference: Date) -> Date? {
    let calendar = Calendar.current
    switch self {
    case .today:
      return calendar.startOfDay(for: reference)
    case .sevenDays:
      return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: reference))
    case .thirtyDays:
      return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: reference))
    case .month:
      return calendar.date(from: calendar.dateComponents([.year, .month], from: reference))
    case .all:
      return nil
    }
  }
}

private struct UsageBreakdown: Identifiable {
  let id: String
  let title: String
  let aggregate: ChatUsageAggregate
}

private struct UsageBreakdownRowView: View {
  let row: UsageBreakdown

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .lineLimit(1)
        Text("\(compactTokens(row.aggregate.inputTokens + row.aggregate.outputTokens)) tokens · \(row.aggregate.modelRequestCount.formatted()) requests")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Text(aggregateCostText(row.aggregate))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

private func displayName(_ raw: String) -> String {
  switch raw.lowercased() {
  case "openrouter": "OpenRouter"
  case "deepseek": "DeepSeek"
  case "anthropic": "Anthropic"
  case "gemini": "Gemini"
  case "nvidia": "NVIDIA"
  default: raw
  }
}

private func tokenCount(_ value: Int) -> String {
  value.formatted(.number.grouping(.automatic))
}

private func compactTokens(_ value: Int) -> String {
  let number = Double(value)
  if value >= 1_000_000 {
    return String(format: "%.2fM", number / 1_000_000)
  }
  if value >= 1_000 {
    return String(format: "%.1fK", number / 1_000)
  }
  return value.formatted()
}

private func pricePerMillion(_ perToken: Decimal) -> String {
  formatUSD(perToken * Decimal(1_000_000))
}

private func aggregateCostText(_ aggregate: ChatUsageAggregate) -> String {
  guard aggregate.hasKnownCost else { return "Unavailable" }
  let prefix = aggregate.hasPartialCost ? "≥" : "~"
  return prefix + formatUSD(aggregate.costUSD)
}

private func formatUSD(_ cost: Decimal) -> String {
  let value = NSDecimalNumber(decimal: cost).doubleValue
  if abs(value) < 0.001 {
    return String(format: "$%.6f", value)
  }
  if abs(value) < 1 {
    return String(format: "$%.4f", value)
  }
  return String(format: "$%.2f", value)
}
