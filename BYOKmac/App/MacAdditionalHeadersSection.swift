import AppKit
import BYOKchatProviderCore
import SwiftUI

/// Editable draft representation of a single custom HTTP header row on macOS.
struct MacAdditionalHeaderItem: Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var value: String

  init(id: UUID = UUID(), name: String, value: String) {
    self.id = id
    self.name = name
    self.value = value
  }

  static func items(from dictionary: [String: String]) -> [MacAdditionalHeaderItem] {
    dictionary
      .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
      .map { MacAdditionalHeaderItem(name: $0.key, value: $0.value) }
  }

  static func dictionary(from items: [MacAdditionalHeaderItem]) -> [String: String] {
    var result: [String: String] = [:]
    result.reserveCapacity(items.count)
    for item in items {
      let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { continue }
      result[name] = value
    }
    return result
  }

  static func validationError(
    for item: MacAdditionalHeaderItem,
    in items: [MacAdditionalHeaderItem],
    policy: HTTPHeaderValidationPolicy
  ) -> HTTPHeaderValidationError? {
    let otherNames = items.filter { $0.id != item.id }.map(\.name)
    return HTTPHeaderValidator.firstError(
      name: item.name,
      value: item.value,
      existingNames: otherNames,
      policy: policy
    )
  }

  static func hasValidationErrors(
    in items: [MacAdditionalHeaderItem],
    policy: HTTPHeaderValidationPolicy
  ) -> Bool {
    items.contains { validationError(for: $0, in: items, policy: policy) != nil }
  }

  static func validatedDictionary(
    from items: [MacAdditionalHeaderItem],
    policy: HTTPHeaderValidationPolicy
  ) throws -> [String: String] {
    var result: [String: String] = [:]
    var seenNames: [String] = []
    result.reserveCapacity(items.count)
    seenNames.reserveCapacity(items.count)
    for item in items {
      let validated = try HTTPHeaderValidator.validateEntry(
        name: item.name,
        value: item.value,
        existingNames: seenNames,
        policy: policy
      )
      seenNames.append(validated.name)
      result[validated.name] = validated.value
    }
    return result
  }
}

/// Presentation target for the add/edit HTTP header modal sheet on macOS.
enum MacAdditionalHeaderEditorTarget: Identifiable, Equatable {
  case add
  case edit(MacAdditionalHeaderItem)

  var id: String {
    switch self {
    case .add: "add"
    case .edit(let item): item.id.uuidString
    }
  }
}

/// Reusable structured HTTP headers list for Provider and MCP editors on macOS.
/// Attach `.macAdditionalHeaderEditorSheet(...)` to an enclosing view outside
/// scrollable `Form`/`List` sections so sheet presentation stays stable.
struct MacAdditionalHeadersSection: View {
  @Binding var headers: [MacAdditionalHeaderItem]
  let policy: HTTPHeaderValidationPolicy
  var footerText: String? = nil
  @Binding var editorTarget: MacAdditionalHeaderEditorTarget?
  var onChange: (() -> Void)? = nil

  @Environment(\.macToastCenter) private var toastCenter

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if headers.isEmpty {
        Text("No additional headers configured.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      } else {
        VStack(spacing: 6) {
          ForEach(headers) { item in
            headerRow(item)
          }
        }
      }

      HStack {
        Button {
          editorTarget = .add
        } label: {
          Label("Add Header", systemImage: "plus.circle.fill")
        }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))

        Spacer()

        if !headers.isEmpty {
          Text("\(headers.count) \(headers.count == 1 ? "header" : "headers")")
            .font(.caption)
            .foregroundStyle(
              MacAdditionalHeaderItem.hasValidationErrors(in: headers, policy: policy)
                ? Color.red
                : MacDesignTokens.Colors.textMuted
            )
        }
      }

      if let footerText, !footerText.isEmpty {
        Text(footerText)
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private func headerRow(_ item: MacAdditionalHeaderItem) -> some View {
    let error = MacAdditionalHeaderItem.validationError(for: item, in: headers, policy: policy)

    HStack(alignment: .top, spacing: 10) {
      Button {
        editorTarget = .edit(item)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Text(item.name)
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(error == nil ? MacDesignTokens.Colors.textPrimary : Color.red)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(item.value)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .lineLimit(2)
            .truncationMode(.tail)
          if let error {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      HStack(spacing: 4) {
        Button {
          copyToPasteboard(item.value, name: item.name)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Copy Value")
        .accessibilityLabel("Copy value for \(item.name)")

        Button {
          editorTarget = .edit(item)
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Edit Header")
        .accessibilityLabel("Edit \(item.name)")

        Button(role: .destructive) {
          deleteHeader(id: item.id)
        } label: {
          Image(systemName: "trash")
            .foregroundStyle(.red)
        }
        .buttonStyle(MacIconButtonStyle())
        .help("Delete Header")
        .accessibilityLabel("Delete \(item.name)")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(MacDesignTokens.Colors.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          error == nil ? MacDesignTokens.Colors.separator.opacity(0.75) : Color.red.opacity(0.5),
          lineWidth: 0.6
        )
    }
    .contextMenu {
      Button("Edit", systemImage: "pencil") {
        editorTarget = .edit(item)
      }
      Button("Copy Value", systemImage: "doc.on.doc") {
        copyToPasteboard(item.value, name: item.name)
      }
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) {
        deleteHeader(id: item.id)
      }
    }
  }

  private func copyToPasteboard(_ value: String, name: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    toastCenter?.success("Copied value for \(name)")
  }

  private func deleteHeader(id: UUID) {
    headers.removeAll { $0.id == id }
    onChange?()
  }
}

extension View {
  /// Presents the add/edit HTTP header sheet from a stable enclosing view.
  func macAdditionalHeaderEditorSheet(
    target: Binding<MacAdditionalHeaderEditorTarget?>,
    headers: Binding<[MacAdditionalHeaderItem]>,
    policy: HTTPHeaderValidationPolicy,
    onChange: (() -> Void)? = nil
  ) -> some View {
    sheet(item: target) { activeTarget in
      switch activeTarget {
      case .add:
        MacAdditionalHeaderEditorSheet(
          existingItem: nil,
          existingNames: headers.wrappedValue.map(\.name),
          policy: policy,
          onSave: { name, value in
            headers.wrappedValue.append(MacAdditionalHeaderItem(name: name, value: value))
            onChange?()
          }
        )
      case .edit(let item):
        MacAdditionalHeaderEditorSheet(
          existingItem: item,
          existingNames: headers.wrappedValue
            .filter { $0.id != item.id }
            .map(\.name),
          policy: policy,
          onSave: { name, value in
            if let index = headers.wrappedValue.firstIndex(where: { $0.id == item.id }) {
              headers.wrappedValue[index].name = name
              headers.wrappedValue[index].value = value
              onChange?()
            }
          },
          onDelete: {
            headers.wrappedValue.removeAll { $0.id == item.id }
            onChange?()
          }
        )
      }
    }
  }
}

/// Modal form sheet for adding or editing a single custom HTTP header with live
/// RFC 9110 + policy validation and `Name: Value` paste auto-splitting.
private struct MacAdditionalHeaderEditorSheet: View {
  let existingItem: MacAdditionalHeaderItem?
  let existingNames: [String]
  let policy: HTTPHeaderValidationPolicy
  let onSave: (String, String) -> Void
  var onDelete: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: Field?

  @State private var name: String
  @State private var value: String
  @State private var hasAttemptedSubmit = false

  private enum Field: Hashable {
    case name
    case value
  }

  init(
    existingItem: MacAdditionalHeaderItem?,
    existingNames: [String],
    policy: HTTPHeaderValidationPolicy,
    onSave: @escaping (String, String) -> Void,
    onDelete: (() -> Void)? = nil
  ) {
    self.existingItem = existingItem
    self.existingNames = existingNames
    self.policy = policy
    self.onSave = onSave
    self.onDelete = onDelete
    _name = State(initialValue: existingItem?.name ?? "")
    _value = State(initialValue: existingItem?.value ?? "")
  }

  private var validationError: HTTPHeaderValidationError? {
    HTTPHeaderValidator.firstError(
      name: name,
      value: value,
      existingNames: existingNames,
      policy: policy
    )
  }

  private var visibleValidationError: HTTPHeaderValidationError? {
    guard let error = validationError else { return nil }
    if hasAttemptedSubmit { return error }
    switch error {
    case .emptyName, .emptyValue:
      return nil
    case .invalidName, .forbiddenHeader, .reservedHeader, .authenticationConflict, .duplicateHeader:
      return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : error
    case .invalidValue:
      return value.isEmpty ? nil : error
    }
  }

  private var isEditing: Bool { existingItem != nil }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(isEditing ? "Edit Header" : "Add Header")
          .font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(MacActionButtonStyle(.secondary))
          .keyboardShortcut(.cancelAction)
        Button(isEditing ? "Save" : "Add") { attemptSave() }
          .buttonStyle(MacActionButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(validationError != nil)
      }
      .padding(16)

      Divider()

      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Header Name")
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          TextField("e.g. X-API-Version", text: $name)
            .font(.system(size: 13, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .name)
            .onSubmit { focusedField = .value }
            .onChange(of: name) { _, newValue in
              splitPastedHeaderPairIfNeeded(newValue)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Value")
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          TextField("Header value", text: $value)
            .font(.system(size: 13, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .value)
            .onSubmit { attemptSave() }
        }

        if let visibleValidationError {
          Label(visibleValidationError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text("Stored in plain configuration, not Keychain. Use the Authentication section for API keys or tokens.")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .fixedSize(horizontal: false, vertical: true)

        if isEditing, let onDelete {
          Divider()
          Button("Delete Header", systemImage: "trash", role: .destructive) {
            onDelete()
            dismiss()
          }
          .buttonStyle(MacActionButtonStyle(.destructive, size: .small))
        }
      }
      .padding(16)
    }
    .frame(width: 440)
    .background(MacDesignTokens.Colors.canvas)
    .onAppear {
      if !isEditing {
        focusedField = .name
      }
    }
  }

  /// If a user pastes `Name: Value` directly into the Name field while Value is
  /// empty, split it automatically into both fields.
  private func splitPastedHeaderPairIfNeeded(_ raw: String) {
    guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !raw.contains("\n"),
      !raw.contains("\r"),
      let colon = raw.firstIndex(of: ":")
    else { return }
    let parsedName = String(raw[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
    let parsedValue = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !parsedName.isEmpty, !parsedValue.isEmpty, HTTPHeaderValidator.isValidName(parsedName) else {
      return
    }
    name = parsedName
    value = parsedValue
  }

  private func attemptSave() {
    hasAttemptedSubmit = true
    guard let validated = try? HTTPHeaderValidator.validateEntry(
      name: name,
      value: value,
      existingNames: existingNames,
      policy: policy
    ) else {
      return
    }
    onSave(validated.name, validated.value)
    dismiss()
  }
}
