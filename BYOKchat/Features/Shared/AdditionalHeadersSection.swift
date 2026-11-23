import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UIKit

/// Editable draft representation of a single custom HTTP header row.
struct AdditionalHeaderItem: Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var value: String

  init(id: UUID = UUID(), name: String, value: String) {
    self.id = id
    self.name = name
    self.value = value
  }

  static func items(from dictionary: [String: String]) -> [AdditionalHeaderItem] {
    dictionary
      .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
      .map { AdditionalHeaderItem(name: $0.key, value: $0.value) }
  }

  static func dictionary(from items: [AdditionalHeaderItem]) -> [String: String] {
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
    for item: AdditionalHeaderItem,
    in items: [AdditionalHeaderItem],
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
    in items: [AdditionalHeaderItem],
    policy: HTTPHeaderValidationPolicy
  ) -> Bool {
    items.contains { validationError(for: $0, in: items, policy: policy) != nil }
  }

  static func validatedDictionary(
    from items: [AdditionalHeaderItem],
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

/// Shared expandable Form section for viewing, adding, editing, and validating
/// additional HTTP headers across Provider and MCP configuration editors.
struct AdditionalHeadersSection: View {
  @Binding var headers: [AdditionalHeaderItem]
  let policy: HTTPHeaderValidationPolicy
  let footerText: String
  var onChange: (() -> Void)? = nil

  @Environment(\.appFoundationTheme) private var theme
  @State private var isExpanded: Bool
  @State private var editorTarget: EditorTarget?

  private enum EditorTarget: Identifiable {
    case add
    case edit(AdditionalHeaderItem)

    var id: String {
      switch self {
      case .add: "add"
      case .edit(let item): item.id.uuidString
      }
    }
  }

  init(
    headers: Binding<[AdditionalHeaderItem]>,
    policy: HTTPHeaderValidationPolicy,
    footerText: String,
    onChange: (() -> Void)? = nil
  ) {
    _headers = headers
    self.policy = policy
    self.footerText = footerText
    self.onChange = onChange
    _isExpanded = State(initialValue: !headers.wrappedValue.isEmpty)
  }

  private var hasAnyError: Bool {
    AdditionalHeaderItem.hasValidationErrors(in: headers, policy: policy)
  }

  private var summaryLabel: String {
    headers.isEmpty ? "None" : "\(headers.count)"
  }

  var body: some View {
    Section {
      Button {
        withAnimation(.snappy(duration: 0.22)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Text("Additional Headers")
            .foregroundStyle(theme.primaryForegroundColor)
          Spacer(minLength: 8)
          if hasAnyError {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .accessibilityLabel("Header validation error")
          }
          Text(summaryLabel)
            .font(.subheadline)
            .foregroundStyle(hasAnyError ? Color.red : theme.secondaryForegroundColor)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryForegroundColor)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowBackground(theme.surfaceColor)
      .listRowSeparatorTint(theme.borderColor)
      .accessibilityValue(isExpanded ? "Expanded, \(summaryLabel)" : "Collapsed, \(summaryLabel)")

      if isExpanded {
        ForEach(headers) { item in
          headerRow(item)
        }

        Button {
          editorTarget = .add
        } label: {
          Label("Add Header", systemImage: "plus.circle.fill")
            .font(.body.weight(.medium))
            .foregroundStyle(theme.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.surfaceColor)
        .listRowSeparatorTint(theme.borderColor)
      }
    } footer: {
      if isExpanded || hasAnyError {
        Text(footerText)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .onChange(of: hasAnyError) { _, newValue in
      if newValue && !isExpanded {
        withAnimation(.snappy(duration: 0.22)) {
          isExpanded = true
        }
      }
    }
    .sheet(item: $editorTarget) { target in
      switch target {
      case .add:
        AdditionalHeaderEditorSheet(
          existingItem: nil,
          existingNames: headers.map(\.name),
          policy: policy,
          onSave: { name, value in
            headers.append(AdditionalHeaderItem(name: name, value: value))
            if !isExpanded { isExpanded = true }
            onChange?()
          }
        )
      case .edit(let item):
        AdditionalHeaderEditorSheet(
          existingItem: item,
          existingNames: headers.filter { $0.id != item.id }.map(\.name),
          policy: policy,
          onSave: { name, value in
            if let index = headers.firstIndex(where: { $0.id == item.id }) {
              headers[index].name = name
              headers[index].value = value
              onChange?()
            }
          },
          onDelete: {
            deleteHeader(id: item.id)
          }
        )
      }
    }
  }

  @ViewBuilder
  private func headerRow(_ item: AdditionalHeaderItem) -> some View {
    let error = AdditionalHeaderItem.validationError(for: item, in: headers, policy: policy)

    Button {
      editorTarget = .edit(item)
    } label: {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(item.name)
            .font(.system(.subheadline, design: .monospaced, weight: .medium))
            .foregroundStyle(error == nil ? theme.primaryForegroundColor : Color.red)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(item.value)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(theme.secondaryForegroundColor)
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
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.7))
          .accessibilityHidden(true)
      }
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(theme.surfaceColor)
    .listRowSeparatorTint(theme.borderColor)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button("Delete", systemImage: "trash", role: .destructive) {
        deleteHeader(id: item.id)
      }
    }
    .contextMenu {
      Button("Edit", systemImage: "pencil") {
        editorTarget = .edit(item)
      }
      Button("Copy Value", systemImage: "doc.on.doc") {
        UIPasteboard.general.string = item.value
      }
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) {
        deleteHeader(id: item.id)
      }
    }
  }

  private func deleteHeader(id: UUID) {
    headers.removeAll { $0.id == id }
    onChange?()
  }
}

/// Modal form sheet for adding or editing a single custom HTTP header with live validation.
private struct AdditionalHeaderEditorSheet: View {
  let existingItem: AdditionalHeaderItem?
  let existingNames: [String]
  let policy: HTTPHeaderValidationPolicy
  let onSave: (String, String) -> Void
  var onDelete: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @FocusState private var focusedField: Field?

  @State private var name: String
  @State private var value: String
  @State private var hasAttemptedSubmit = false

  private enum Field: Hashable {
    case name
    case value
  }

  init(
    existingItem: AdditionalHeaderItem?,
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
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Text("Header Name")
              .font(.caption.weight(.semibold))
              .foregroundStyle(theme.secondaryForegroundColor)
            TextField("e.g. X-API-Version", text: $name)
              .font(.system(.body, design: .monospaced))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .focused($focusedField, equals: .name)
              .submitLabel(.next)
              .onSubmit { focusedField = .value }
              .onChange(of: name) { _, newValue in
                splitPastedHeaderPairIfNeeded(newValue)
              }
          }
          .padding(.vertical, 2)

          VStack(alignment: .leading, spacing: 6) {
            Text("Value")
              .font(.caption.weight(.semibold))
              .foregroundStyle(theme.secondaryForegroundColor)
            TextField("Header value", text: $value)
              .font(.system(.body, design: .monospaced))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .focused($focusedField, equals: .value)
              .submitLabel(.done)
              .onSubmit { attemptSave() }
          }
          .padding(.vertical, 2)

          if let visibleValidationError {
            Label(visibleValidationError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
              .font(.footnote)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        } footer: {
          Text("Stored in plain configuration, not Keychain. Use the Authentication section for API keys or tokens.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)
        .listRowSeparatorTint(theme.borderColor)

        if isEditing, let onDelete {
          Section {
            Button("Delete Header", systemImage: "trash", role: .destructive) {
              onDelete()
              dismiss()
            }
          }
          .listRowBackground(theme.surfaceColor)
        }
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle(isEditing ? "Edit Header" : "Add Header")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isEditing ? "Save" : "Add") { attemptSave() }
            .disabled(validationError != nil)
        }
      }
      .onAppear {
        if !isEditing {
          focusedField = .name
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
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
