import Foundation

#if canImport(Security)
  import Security
#endif

public protocol MCPCredentialVault: Sendable {
  func credential(serverID: MCPServerID) async throws -> String?
  func setCredential(_ value: String?, serverID: MCPServerID) async throws
  func removeCredential(serverID: MCPServerID) async throws
}

public actor InMemoryMCPCredentialVault: MCPCredentialVault {
  private var values: [MCPServerID: String] = [:]
  public init() {}

  public func credential(serverID: MCPServerID) -> String? { values[serverID] }

  public func setCredential(_ value: String?, serverID: MCPServerID) {
    if let value, !value.isEmpty {
      values[serverID] = value
    } else {
      values.removeValue(forKey: serverID)
    }
  }

  public func removeCredential(serverID: MCPServerID) {
    values.removeValue(forKey: serverID)
  }
}

#if canImport(Security)
  public actor KeychainMCPCredentialVault: MCPCredentialVault {
    private let service: String

    public init(service: String = "com.hoangbkit.byokchat.mcp.credentials") {
      self.service = service
    }

    public func credential(serverID: MCPServerID) throws -> String? {
      var query = baseQuery(serverID: serverID)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess,
        let data = result as? Data,
        let value = String(data: data, encoding: .utf8)
      else {
        throw MCPError.transport("Keychain read failed with status \(status).")
      }
      return value
    }

    public func setCredential(_ value: String?, serverID: MCPServerID) throws {
      let query = baseQuery(serverID: serverID)
      guard let value, !value.isEmpty else {
        try removeCredential(serverID: serverID)
        return
      }

      let data = Data(value.utf8)
      let updateStatus = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      if updateStatus == errSecSuccess { return }
      guard updateStatus == errSecItemNotFound else {
        throw MCPError.transport("Keychain update failed with status \(updateStatus).")
      }

      var insert = query
      insert[kSecValueData as String] = data
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let insertStatus = SecItemAdd(insert as CFDictionary, nil)
      guard insertStatus == errSecSuccess else {
        throw MCPError.transport("Keychain insert failed with status \(insertStatus).")
      }
    }

    public func removeCredential(serverID: MCPServerID) throws {
      let status = SecItemDelete(baseQuery(serverID: serverID) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw MCPError.transport("Keychain delete failed with status \(status).")
      }
    }

    public func removeAllCredentials() throws {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
      ]
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw MCPError.transport("Keychain cleanup failed with status \(status).")
      }
    }

    private func baseQuery(serverID: MCPServerID) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: serverID.rawValue,
      ]
    }
  }
#endif
