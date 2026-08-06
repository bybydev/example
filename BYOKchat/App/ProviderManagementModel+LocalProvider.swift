import BYOKchatProviderCore
import Foundation

extension ProviderManagementModel {
  func createCustomProvider(
    id: String,
    name: String,
    baseURL: String,
    chatPath: String,
    modelsPath: String,
    authentication: ProviderAuthentication,
    seedModels: [String]
  ) async -> Bool {
    let allowsLocalHTTP = URL(string: baseURL)?.scheme?.lowercased() == "http"
    return await createCustomProvider(
      id: id,
      name: name,
      baseURL: baseURL,
      chatPath: chatPath,
      modelsPath: modelsPath,
      authentication: authentication,
      seedModels: seedModels,
      allowsLocalHTTP: allowsLocalHTTP
    )
  }
}
