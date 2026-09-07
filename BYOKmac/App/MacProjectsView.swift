import BYOKchatProviderCore
import Foundation
import SwiftUI

enum MacProjectAccentOption: String, CaseIterable, Identifiable {
  case blue, indigo, purple, pink, orange, teal, green

  var id: String { rawValue }
  var title: String { rawValue.capitalized }

  var color: Color {
    switch self {
    case .blue: .blue
    case .indigo: .indigo
    case .purple: .purple
    case .pink: .pink
    case .orange: .orange
    case .teal: .teal
    case .green: .green
    }
  }
}

func macProjectFileDetail(_ file: ProjectFile) -> String {
  let size = ByteCountFormatter.string(
    fromByteCount: Int64(file.byteCount),
    countStyle: .file
  )
  let estimatedTokens = max(1, file.byteCount / 4)
  return "\(size) · ~\(estimatedTokens.formatted()) tokens"
}
