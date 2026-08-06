import Foundation

#if canImport(Security)
  import Security
#endif

public protocol CredentialVault: Sendable {
  func secret(accountID: ProviderAccountID, field: String) async throws -> String?
  func setSecret(_ value: String?, accountID: ProviderAccountID, field: String) async throws
  func removeAll(accountID: ProviderAccountID) async throws
}

public actor InMemoryCredentialVault: CredentialVault {
  private var values: [String: String] = [:]
  public init() {}
  public func secret(accountID: ProviderAccountID, field: String) -> String? {
    values[key(accountID, field)]
  }
  public func setSecret(_ value: String?, accountID: ProviderAccountID, field: String) {
    let key = key(accountID, field)
    if let value, !value.isEmpty { values[key] = value } else { values.removeValue(forKey: key) }
  }
  public func removeAll(accountID: ProviderAccountID) {
    let prefix = "\(accountID.rawValue):"
    values = values.filter { !$0.key.hasPrefix(prefix) }
  }
  private func key(_ accountID: ProviderAccountID, _ field: String) -> String {
    "\(accountID.rawValue):\(field)"
  }
}

#if canImport(Security)
  public actor KeychainCredentialVault: CredentialVault {
    private let service: String
    public init(service: String = "com.hoangbkit.byokchat.credentials") { self.service = service }

    public func secret(accountID: ProviderAccountID, field: String) throws -> String? {
      var query = baseQuery(accountID: accountID, field: field)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = result as? Data,
        let value = String(data: data, encoding: .utf8)
      else {
        throw ProviderError.transport(
          message: "Keychain read failed with status \(status).", completionUnknown: false)
      }
      return value
    }

    public func setSecret(_ value: String?, accountID: ProviderAccountID, field: String) throws {
      let query = baseQuery(accountID: accountID, field: field)
      guard let value, !value.isEmpty else {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          throw ProviderError.transport(
            message: "Keychain delete failed with status \(status).", completionUnknown: false)
        }
        return
      }
      let data = Data(value.utf8)
      let updateStatus = SecItemUpdate(
        query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if updateStatus == errSecSuccess { return }
      guard updateStatus == errSecItemNotFound else {
        throw ProviderError.transport(
          message: "Keychain update failed with status \(updateStatus).", completionUnknown: false)
      }
      var insert = query
      insert[kSecValueData as String] = data
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let insertStatus = SecItemAdd(insert as CFDictionary, nil)
      guard insertStatus == errSecSuccess else {
        throw ProviderError.transport(
          message: "Keychain insert failed with status \(insertStatus).", completionUnknown: false)
      }
    }

    public func removeAll(accountID: ProviderAccountID) throws {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrGeneric as String: Data(accountID.rawValue.utf8),
      ]
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ProviderError.transport(
          message: "Keychain cleanup failed with status \(status).", completionUnknown: false)
      }
    }

    private func baseQuery(accountID: ProviderAccountID, field: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "\(accountID.rawValue):\(field)",
        kSecAttrGeneric as String: Data(accountID.rawValue.utf8),
      ]
    }
  }
#endif
