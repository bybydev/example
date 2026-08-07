import BYOKchatProviderCore
import SwiftUI

struct MCPToolApprovalCard: View {
  let request: MCPToolApprovalRequest
  let resolve: (MCPToolApprovalDecision) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: request.destructiveHint == true ? "exclamationmark.shield" : "hand.raised")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(request.destructiveHint == true ? .orange : .primary)
          .frame(width: 28, height: 28)

        VStack(alignment: .leading, spacing: 3) {
          Text("Allow tool call?")
            .font(.system(size: 15, weight: .semibold))
          Text("\(request.serverName) · \(request.displayName)")
            .font(.system(size: 13, weight: .medium))
          Text(request.toolDescription)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(spacing: 7) {
        if request.readOnlyHint == true {
          Label("Read-only", systemImage: "eye")
        }
        if request.destructiveHint == true {
          Label("Destructive", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)

      DisclosureGroup("Arguments") {
        Text(request.arguments.prettyJSONString())
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
      }
      .font(.system(size: 12, weight: .semibold))

      HStack(spacing: 8) {
        Button("Deny", role: .destructive) { resolve(.deny) }
          .buttonStyle(.bordered)
        Spacer(minLength: 4)
        Button("Allow Once") { resolve(.allowOnce) }
          .buttonStyle(.bordered)
        Button("Always Allow") { resolve(.alwaysAllow) }
          .buttonStyle(.borderedProminent)
      }
      .font(.system(size: 13, weight: .semibold))
    }
    .padding(14)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(request.destructiveHint == true ? Color.orange.opacity(0.35) : Color.primary.opacity(0.09), lineWidth: 0.8)
    )
    .accessibilityElement(children: .contain)
  }
}

struct MCPToolRunningCard: View {
  let call: ChatToolCall
  let displayName: String
  let isWaitingForApproval: Bool

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      VStack(alignment: .leading, spacing: 2) {
        Text(isWaitingForApproval ? "Waiting for approval" : "Running tool")
          .font(.system(size: 12, weight: .semibold))
        Text(displayName)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
  }
}

struct ChatToolRoundView: View {
  let round: ChatToolRound
  let displayName: (String) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(round.calls) { call in
        let result = round.results.first { $0.callID == call.id }
        toolCard(call, result: result)
      }
    }
  }

  @ViewBuilder
  private func toolCard(_ call: ChatToolCall, result: ChatToolResult?) -> some View {
    let failed = result?.isError == true || result == nil
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Arguments")
            .font(.caption.weight(.semibold))
          Text(call.arguments.prettyJSONString())
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
        }

        if let result {
          VStack(alignment: .leading, spacing: 4) {
            Text(result.isError ? "Error" : "Result")
              .font(.caption.weight(.semibold))
            Text(result.content.prettyJSONString())
              .font(.system(size: 11, design: .monospaced))
              .textSelection(.enabled)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
          .foregroundStyle(failed ? .orange : .secondary)
        Text(displayName(call.name))
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(2)
        Spacer()
        Text(failed ? "Failed" : "Done")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
    }
    .tint(.secondary)
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
  }
}

struct MCPElicitationCard: View {
  let request: MCPElicitationRequest
  let resolve: (MCPElicitationDecision) -> Void

  @State private var textValues: [String: String]
  @State private var boolValues: [String: Bool]

  init(
    request: MCPElicitationRequest,
    resolve: @escaping (MCPElicitationDecision) -> Void
  ) {
    self.request = request
    self.resolve = resolve

    var text: [String: String] = [:]
    var bools: [String: Bool] = [:]
    for field in request.fields {
      switch (field.kind, field.defaultValue) {
      case (.boolean, .bool(let value)):
        bools[field.name] = value
      case (.string, .string(let value)):
        text[field.name] = value
      case (.integer, .number(let value)), (.number, .number(let value)):
        text[field.name] = String(value)
      case (.stringArray, .array(let values)):
        text[field.name] = values.compactMap {
          if case .string(let value) = $0 { return value }
          return nil
        }.joined(separator: ", ")
      default:
        if field.kind == .boolean { bools[field.name] = false }
      }
    }
    _textValues = State(initialValue: text)
    _boolValues = State(initialValue: bools)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("\(request.serverName) needs input", systemImage: "text.bubble")
        .font(.system(size: 14, weight: .semibold))
      Text(request.message)
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)

      switch request.mode {
      case .form:
        formFields
      case .url:
        if let url = request.url {
          Link(destination: url) {
            Label("Open Link", systemImage: "arrow.up.right.square")
          }
          .buttonStyle(.borderedProminent)
        }
      }

      HStack(spacing: 8) {
        Button("Cancel") { resolve(.cancel) }
          .buttonStyle(.bordered)
        Button("Decline", role: .destructive) { resolve(.decline) }
          .buttonStyle(.bordered)
        Spacer()
        Button(request.mode == .url ? "Continue" : "Submit") {
          resolve(.accept(responseContent()))
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      .font(.system(size: 13, weight: .semibold))
    }
    .padding(14)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.primary.opacity(0.09), lineWidth: 0.8)
    )
  }

  @ViewBuilder
  private var formFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(request.fields) { field in
        switch field.kind {
        case .boolean:
          Toggle(
            field.displayName,
            isOn: Binding(
              get: { boolValues[field.name] ?? false },
              set: { boolValues[field.name] = $0 }
            )
          )
        case .string where !field.allowedValues.isEmpty:
          Picker(
            field.displayName,
            selection: Binding(
              get: { textValues[field.name] ?? field.allowedValues.first ?? "" },
              set: { textValues[field.name] = $0 }
            )
          ) {
            ForEach(field.allowedValues, id: \.self) { value in
              Text(value).tag(value)
            }
          }
        default:
          TextField(
            field.isRequired ? field.displayName : "\(field.displayName) (optional)",
            text: Binding(
              get: { textValues[field.name] ?? "" },
              set: { textValues[field.name] = $0 }
            )
          )
          .textFieldStyle(.roundedBorder)
          .keyboardType(field.kind == .integer || field.kind == .number ? .decimalPad : .default)
        }

        if let description = field.description, !description.isEmpty {
          Text(description)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var canSubmit: Bool {
    guard request.mode == .form else { return request.url != nil }
    for field in request.fields where field.isRequired {
      if field.kind == .boolean { continue }
      if (textValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return false
      }
    }
    return true
  }

  private func responseContent() -> [String: JSONValue] {
    var values: [String: JSONValue] = [:]
    for field in request.fields {
      switch field.kind {
      case .boolean:
        values[field.name] = .bool(boolValues[field.name] ?? false)
      case .integer:
        if let value = Int(textValues[field.name] ?? "") {
          values[field.name] = .number(Double(value))
        }
      case .number:
        if let value = Double(textValues[field.name] ?? "") {
          values[field.name] = .number(value)
        }
      case .string:
        let value = textValues[field.name] ?? ""
        if !value.isEmpty || field.isRequired { values[field.name] = .string(value) }
      case .stringArray:
        let value = (textValues[field.name] ?? "")
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .map(JSONValue.string)
        if !value.isEmpty || field.isRequired { values[field.name] = .array(value) }
      }
    }
    return values
  }
}

extension JSONValue {
  fileprivate func prettyJSONString() -> String {
    guard let data = try? JSONEncoder.providerEncoder.encode(self),
      let object = try? JSONSerialization.jsonObject(with: data),
      JSONSerialization.isValidJSONObject(object),
      let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let value = String(data: pretty, encoding: .utf8)
    else {
      if case .string(let value) = self { return value }
      return compactJSONString()
    }
    return value
  }
}
