import Foundation
import Testing
@testable import BYOKchatProviderCore

@Suite("HTTP Header Validation")
struct HTTPHeaderValidationTests {
  @Test("Validates RFC 9110 header names and rejects invalid characters")
  func headerNameValidation() {
    #expect(HTTPHeaderValidator.isValidName("X-API-Version"))
    #expect(HTTPHeaderValidator.isValidName("X_Custom.Header-1"))
    #expect(!HTTPHeaderValidator.isValidName(""))
    #expect(!HTTPHeaderValidator.isValidName("X Invalid"))
    #expect(!HTTPHeaderValidator.isValidName("X-Name:Value"))
    #expect(!HTTPHeaderValidator.isValidName("X-Ünicode"))
  }

  @Test("Rejects control characters and line breaks in values")
  func headerValueValidation() {
    let policy = HTTPHeaderValidationPolicy.provider(kind: .openai, authentication: .bearer)
    #expect(
      HTTPHeaderValidator.firstError(
        name: "X-Trace",
        value: "line1\nline2",
        policy: policy
      ) == .invalidValue
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "X-Trace",
        value: "line1\r\nX-Injected: 1",
        policy: policy
      ) == .invalidValue
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "X-Trace",
        value: "   ",
        policy: policy
      ) == .emptyValue
    )
  }

  @Test("Rejects transport-forbidden headers for both Provider and MCP policies")
  func forbiddenHeadersBlocked() {
    let providerPolicy = HTTPHeaderValidationPolicy.provider(kind: .openai, authentication: .bearer)
    let mcpPolicy = HTTPHeaderValidationPolicy.mcp()

    for forbidden in ["Authorization", "Host", "Cookie", "Transfer-Encoding", "Content-Length"] {
      #expect(
        HTTPHeaderValidator.firstError(
          name: forbidden,
          value: "val",
          policy: providerPolicy
        ) == .forbiddenHeader(forbidden)
      )
      #expect(
        HTTPHeaderValidator.firstError(
          name: forbidden,
          value: "val",
          policy: mcpPolicy
        ) == .forbiddenHeader(forbidden)
      )
    }
  }

  @Test("Detects provider-specific reserved headers and authentication header collisions")
  func providerPolicyRules() {
    let anthropicPolicy = HTTPHeaderValidationPolicy.provider(
      kind: .anthropic,
      authentication: .header(name: "x-api-key")
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "X-API-Key",
        value: "secret",
        policy: anthropicPolicy
      ) == .authenticationConflict("X-API-Key")
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "Anthropic-Version",
        value: "2023-06-01",
        policy: anthropicPolicy
      ) == .reservedHeader("Anthropic-Version")
    )

    let openRouterPolicy = HTTPHeaderValidationPolicy.provider(
      kind: .openRouter,
      authentication: .bearer
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "HTTP-Referer",
        value: "https://example.com",
        policy: openRouterPolicy
      ) == .reservedHeader("HTTP-Referer")
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "X-Title",
        value: "MyApp",
        policy: openRouterPolicy
      ) == .reservedHeader("X-Title")
    )

    let customPolicy = HTTPHeaderValidationPolicy.provider(
      kind: .openAICompatible,
      authentication: .header(name: "X-Gateway-Key")
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "x-gateway-key",
        value: "override",
        policy: customPolicy
      ) == .authenticationConflict("x-gateway-key")
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "X-Tenant",
        value: "acme",
        policy: customPolicy
      ) == nil
    )
  }

  @Test("Detects MCP reserved headers, parameter prefixes, and case-insensitive duplicates")
  func mcpPolicyRulesAndDuplicates() {
    let mcpPolicy = HTTPHeaderValidationPolicy.mcp(authenticationHeader: "X-Custom-Auth")

    #expect(
      HTTPHeaderValidator.firstError(
        name: "MCP-Session-Id",
        value: "abc",
        policy: mcpPolicy
      ) == .reservedHeader("MCP-Session-Id")
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "mcp-param-foo",
        value: "bar",
        policy: mcpPolicy
      ) == .reservedHeader("mcp-param-foo")
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "x-custom-auth",
        value: "token",
        policy: mcpPolicy
      ) == .authenticationConflict("x-custom-auth")
    )
    #expect(
      HTTPHeaderValidator.firstError(
        name: "x-tenant",
        value: "beta",
        existingNames: ["X-Tenant"],
        policy: mcpPolicy
      ) == .duplicateHeader("x-tenant")
    )
  }
}
