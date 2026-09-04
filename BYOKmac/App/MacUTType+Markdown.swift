import UniformTypeIdentifiers

extension UTType {
  static let markdown = UTType(filenameExtension: "md") ?? .plainText
}
