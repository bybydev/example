#if DEBUG
import AppFoundation
import SwiftUI

@MainActor
struct BYOKScreenshotChatScene: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKScreenshotCanvas(
      settings: settings,
      eyebrow: "NATIVE AI CHAT",
      title: "Chat with\nany model",
      subtitle: "Streaming answers, reasoning, files, and tools in one native workspace.",
      symbol: "bubble.left.and.text.bubble.right.fill"
    ) {
      BYOKStudioChatFixture(settings: settings)
    }
  }
}

@MainActor
struct BYOKScreenshotProvidersScene: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKScreenshotCanvas(
      settings: settings,
      eyebrow: "BRING YOUR OWN KEYS",
      title: "Your providers.\nYour API keys.",
      subtitle: "Connect leading AI providers, private endpoints, and your own OpenAI-compatible servers.",
      symbol: "key.horizontal.fill"
    ) {
      BYOKStudioProvidersFixture(settings: settings)
    }
  }
}

@MainActor
struct BYOKScreenshotMCPScene: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKScreenshotCanvas(
      settings: settings,
      eyebrow: "REMOTE MCP",
      title: "Give every chat\npowerful tools",
      subtitle: "Connect remote MCP servers and decide exactly what each tool is allowed to do.",
      symbol: "shippingbox.fill"
    ) {
      BYOKStudioMCPFixture(settings: settings)
    }
  }
}

@MainActor
struct BYOKScreenshotProjectsScene: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKScreenshotCanvas(
      settings: settings,
      eyebrow: "PROJECT WORKSPACES",
      title: "Keep every\nworkspace organized",
      subtitle: "Group chats by project with their own prompts, files, models, and tools.",
      symbol: "folder.fill"
    ) {
      BYOKStudioProjectsFixture(settings: settings)
    }
  }
}

@MainActor
struct BYOKScreenshotAnalyticsScene: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKScreenshotCanvas(
      settings: settings,
      eyebrow: "LOCAL ANALYTICS",
      title: "Know what every\nrequest costs",
      subtitle: "Track tokens, spend, speed, reliability, and provider performance — all locally.",
      symbol: "chart.bar.xaxis"
    ) {
      BYOKStudioAnalyticsFixture(settings: settings)
    }
  }
}

// MARK: - Chat

private struct BYOKStudioChatFixture: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKStudioWidthFixture(designSize: CGSize(width: 520, height: 760)) {
      VStack(spacing: 12) {
        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 12) {
            Image(systemName: "sparkles")
              .font(.title3.bold())
              .foregroundStyle(settings.theme.accentColor)
              .frame(width: 42, height: 42)
              .background(settings.theme.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
              Text("Claude Sonnet 4")
                .font(.headline)
              Text("Anthropic · Personal")
                .font(.caption)
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }

            Spacer()

            Label("3 tools", systemImage: "shippingbox.fill")
              .font(.caption.bold())
              .foregroundStyle(settings.theme.accentColor)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(settings.theme.accentColor.opacity(0.12), in: Capsule())
          }
        }

        HStack {
          Spacer(minLength: 70)
          Text("Compare these two reports and tell me what actually changed.")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(settings.theme.backgroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(settings.theme.accentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
              Image(systemName: "brain.head.profile.fill")
              Text("Reasoned for 8s")
            }
            .font(.caption.bold())
            .foregroundStyle(settings.theme.secondaryForegroundColor)

            Text("The biggest change is pricing: the new report lowers inference cost while increasing the context window. Reliability is roughly unchanged.")
              .font(.system(size: 16))
              .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(settings.theme.borderColor)

            HStack(spacing: 10) {
              Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(settings.theme.accentColor)
              VStack(alignment: .leading, spacing: 2) {
                Text("Compared 2 attached reports")
                  .font(.subheadline.bold())
                Text("Tool completed successfully")
                  .font(.caption)
                  .foregroundStyle(settings.theme.secondaryForegroundColor)
              }
              Spacer()
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 12) {
            Image(systemName: "plus")
              .foregroundStyle(settings.theme.secondaryForegroundColor)
            Text("Message Claude Sonnet 4")
              .foregroundStyle(settings.theme.secondaryForegroundColor)
            Spacer()
            Image(systemName: "mic.fill")
              .foregroundStyle(settings.theme.secondaryForegroundColor)
            Image(systemName: "arrow.up.circle.fill")
              .font(.title2)
              .foregroundStyle(settings.theme.accentColor)
          }
        }
      }
    }
  }
}

// MARK: - Providers

private struct BYOKStudioProvidersFixture: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKStudioWidthFixture(designSize: CGSize(width: 520, height: 720)) {
      VStack(spacing: 14) {
        BYOKStudioCard(theme: settings.theme) {
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text("Provider Accounts")
                .font(.title3.bold())
              Text("Keys stay in Keychain on this device")
                .font(.caption)
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }
            Spacer()
            Image(systemName: "plus.circle.fill")
              .font(.title2)
              .foregroundStyle(settings.theme.accentColor)
          }
        }

        HStack(spacing: 12) {
          BYOKStudioProviderTile(
            theme: settings.theme,
            name: "OpenRouter",
            detail: "240+ models",
            symbol: "bolt.horizontal.fill"
          )
          BYOKStudioProviderTile(
            theme: settings.theme,
            name: "Anthropic",
            detail: "Claude Sonnet 4",
            symbol: "sparkles"
          )
        }

        HStack(spacing: 12) {
          BYOKStudioProviderTile(
            theme: settings.theme,
            name: "Gemini",
            detail: "Gemini 2.5 Pro",
            symbol: "diamond.fill"
          )
          BYOKStudioProviderTile(
            theme: settings.theme,
            name: "Local Server",
            detail: "192.168.1.42",
            symbol: "network"
          )
        }

        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 13) {
            Image(systemName: "lock.shield.fill")
              .font(.title3)
              .foregroundStyle(settings.theme.accentColor)
            VStack(alignment: .leading, spacing: 4) {
              Text("Direct to your providers")
                .font(.headline)
              Text("No BYOK account. No proxy. Your app talks directly to the endpoints you configure.")
                .font(.subheadline)
                .foregroundStyle(settings.theme.secondaryForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
  }
}

// MARK: - MCP

private struct BYOKStudioMCPFixture: View {
  let settings: BYOKScreenshotStudioSettings

  private let tools = [
    ("Search repositories", "search_repositories", "Always", "checkmark.shield.fill"),
    ("Read files", "fetch_file", "Ask", "questionmark.circle.fill"),
    ("Create issues", "create_issue", "Off", "nosign"),
  ]

  var body: some View {
    BYOKStudioWidthFixture(designSize: CGSize(width: 520, height: 760)) {
      VStack(spacing: 14) {
        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
              .font(.title2)
              .foregroundStyle(settings.theme.accentColor)
              .frame(width: 52, height: 52)
              .background(settings.theme.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 15))

            VStack(alignment: .leading, spacing: 4) {
              Text("GitHub MCP")
                .font(.title3.bold())
              Text("Remote · 12 tools discovered")
                .font(.caption)
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }

            Spacer()

            Label("Connected", systemImage: "checkmark.circle.fill")
              .font(.caption.bold())
              .foregroundStyle(.green)
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              Text("Tool permissions")
                .font(.title3.bold())
              Spacer()
              Text("Per chat")
                .font(.caption.bold())
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }
            .padding(.bottom, 10)

            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
              if index > 0 {
                Divider().overlay(settings.theme.borderColor)
              }

              HStack(spacing: 13) {
                Image(systemName: tool.3)
                  .font(.title3)
                  .foregroundStyle(tool.2 == "Off" ? settings.theme.secondaryForegroundColor : settings.theme.accentColor)
                  .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                  Text(tool.0)
                    .font(.headline)
                  Text(tool.1)
                    .font(.caption.monospaced())
                    .foregroundStyle(settings.theme.secondaryForegroundColor)
                }

                Spacer()

                Text(tool.2)
                  .font(.subheadline.bold())
                  .foregroundStyle(tool.2 == "Off" ? settings.theme.secondaryForegroundColor : settings.theme.accentColor)
                  .padding(.horizontal, 11)
                  .padding(.vertical, 7)
                  .background(
                    (tool.2 == "Off" ? settings.theme.secondaryForegroundColor : settings.theme.accentColor).opacity(0.10),
                    in: Capsule()
                  )
              }
              .padding(.vertical, 16)
            }
          }
        }

        HStack(spacing: 10) {
          Image(systemName: "hand.raised.fill")
            .foregroundStyle(settings.theme.accentColor)
          Text("You decide before sensitive tools run.")
            .font(.subheadline.weight(.semibold))
          Spacer()
        }
        .padding(.horizontal, 4)
        .foregroundStyle(settings.theme.primaryForegroundColor)
      }
    }
  }
}

// MARK: - Projects

private struct BYOKStudioProjectsFixture: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKStudioWidthFixture(designSize: CGSize(width: 520, height: 760)) {
      VStack(spacing: 14) {
        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
              HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                  .font(.title2.bold())
                  .foregroundStyle(settings.theme.accentColor)
                  .frame(width: 50, height: 50)
                  .background(settings.theme.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                  Text("BYOK Launch")
                    .font(.title2.bold())
                  Text("12 conversations")
                    .font(.caption)
                    .foregroundStyle(settings.theme.secondaryForegroundColor)
                }
              }

              Spacer()
              Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }

            Text("Ship a minimal, native AI workspace with direct provider access and safe tool use.")
              .font(.subheadline)
              .foregroundStyle(settings.theme.secondaryForegroundColor)
              .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
              BYOKStudioChip(theme: settings.theme, text: "Sonnet 4", symbol: "sparkles")
              BYOKStudioChip(theme: settings.theme, text: "3 MCP", symbol: "shippingbox.fill")
              BYOKStudioChip(theme: settings.theme, text: "6 files", symbol: "paperclip")
            }
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              Text("Recent chats")
                .font(.title3.bold())
              Spacer()
              Text("View all")
                .font(.caption.bold())
                .foregroundStyle(settings.theme.accentColor)
            }
            .padding(.bottom, 8)

            BYOKStudioChatRow(theme: settings.theme, title: "Release readiness review", detail: "2 min ago", symbol: "checkmark.seal.fill")
            Divider().overlay(settings.theme.borderColor)
            BYOKStudioChatRow(theme: settings.theme, title: "App Store screenshot copy", detail: "Yesterday", symbol: "photo.stack.fill")
            Divider().overlay(settings.theme.borderColor)
            BYOKStudioChatRow(theme: settings.theme, title: "Provider pricing research", detail: "Yesterday", symbol: "dollarsign.circle.fill")
          }
        }

        HStack(spacing: 12) {
          BYOKStudioMiniProject(theme: settings.theme, title: "Research", symbol: "magnifyingglass")
          BYOKStudioMiniProject(theme: settings.theme, title: "Personal", symbol: "person.fill")
          BYOKStudioMiniProject(theme: settings.theme, title: "Ideas", symbol: "lightbulb.fill")
        }
      }
    }
  }
}

// MARK: - Analytics

private struct BYOKStudioAnalyticsFixture: View {
  let settings: BYOKScreenshotStudioSettings

  private let bars: [CGFloat] = [0.42, 0.58, 0.36, 0.72, 0.63, 0.88, 0.76]

  var body: some View {
    BYOKStudioWidthFixture(designSize: CGSize(width: 520, height: 820)) {
      VStack(spacing: 12) {
        HStack(spacing: 10) {
          BYOKStudioMetricCard(theme: settings.theme, title: "Spend", value: "$12.48", detail: "This month")
          BYOKStudioMetricCard(theme: settings.theme, title: "Requests", value: "842", detail: "+18%")
        }

        HStack(spacing: 10) {
          BYOKStudioMetricCard(theme: settings.theme, title: "Input", value: "3.2M", detail: "tokens")
          BYOKStudioMetricCard(theme: settings.theme, title: "Output", value: "824K", detail: "tokens")
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text("Daily usage")
                  .font(.headline)
                Text("Last 7 days")
                  .font(.caption)
                  .foregroundStyle(settings.theme.secondaryForegroundColor)
              }
              Spacer()
              Text("$4.86")
                .font(.title3.bold())
                .foregroundStyle(settings.theme.accentColor)
            }

            HStack(alignment: .bottom, spacing: 10) {
              ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                VStack(spacing: 6) {
                  RoundedRectangle(cornerRadius: 5)
                    .fill(
                      index == bars.count - 2
                        ? settings.theme.accentColor
                        : settings.theme.accentColor.opacity(0.35)
                    )
                    .frame(height: 122 * height)
                  Text(["M", "T", "W", "T", "F", "S", "S"][index])
                    .font(.caption2.bold())
                    .foregroundStyle(settings.theme.secondaryForegroundColor)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
              }
            }
            .frame(height: 148, alignment: .bottom)
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Provider performance")
                .font(.headline)
              Spacer()
              Text("TTFT")
                .font(.caption.bold())
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }

            BYOKStudioPerformanceRow(theme: settings.theme, provider: "Anthropic", value: "1.2s", score: 0.91)
            BYOKStudioPerformanceRow(theme: settings.theme, provider: "OpenRouter", value: "1.6s", score: 0.82)
            BYOKStudioPerformanceRow(theme: settings.theme, provider: "Gemini", value: "1.4s", score: 0.86)
          }
        }
      }
    }
  }
}

// MARK: - Layout

/// Scales fixtures from the width only. The screenshot template already owns the
/// page-level horizontal inset, so the fixture fills that available width and is
/// allowed to crop vertically instead of shrinking again to fit the visual slot.
private struct BYOKStudioWidthFixture<Content: View>: View {
  let designSize: CGSize
  private let content: Content

  init(designSize: CGSize, @ViewBuilder content: () -> Content) {
    self.designSize = designSize
    self.content = content()
  }

  var body: some View {
    GeometryReader { proxy in
      let scale = proxy.size.width / designSize.width

      content
        .frame(width: designSize.width, height: designSize.height, alignment: .top)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(
          width: proxy.size.width,
          height: designSize.height * scale,
          alignment: .topLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .allowsHitTesting(false)
  }
}

// MARK: - Components

private struct BYOKStudioCard<Content: View>: View {
  let theme: AppTheme
  private let content: Content

  init(theme: AppTheme, @ViewBuilder content: () -> Content) {
    self.theme = theme
    self.content = content()
  }

  var body: some View {
    content
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(
        theme.elevatedSurfaceColor,
        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .strokeBorder(theme.borderColor)
      }
      .shadow(color: theme.appearance.shadow.color.opacity(0.70), radius: 18, y: 9)
  }
}

private struct BYOKStudioProviderTile: View {
  let theme: AppTheme
  let name: String
  let detail: String
  let symbol: String

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Image(systemName: symbol)
          .font(.title3.bold())
          .foregroundStyle(theme.accentColor)
          .frame(width: 44, height: 44)
          .background(theme.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
        Spacer()
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(name)
          .font(.headline)
        Text(detail)
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
          .lineLimit(1)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }
}

private struct BYOKStudioMiniProject: View {
  let theme: AppTheme
  let title: String
  let symbol: String

  var body: some View {
    VStack(spacing: 9) {
      Image(systemName: symbol)
        .font(.headline)
        .foregroundStyle(theme.accentColor)
      Text(title)
        .font(.caption.bold())
        .lineLimit(1)
    }
    .padding(.vertical, 15)
    .frame(maxWidth: .infinity)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }
}

private struct BYOKStudioChatRow: View {
  let theme: AppTheme
  let title: String
  let detail: String
  let symbol: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(theme.accentColor)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.bold())
        Text(detail)
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption.bold())
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .padding(.vertical, 12)
  }
}

private struct BYOKStudioChip: View {
  let theme: AppTheme
  let text: String
  let symbol: String

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.caption.bold())
      .foregroundStyle(theme.accentColor)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(theme.accentColor.opacity(0.10), in: Capsule())
  }
}

private struct BYOKStudioMetricCard: View {
  let theme: AppTheme
  let title: String
  let value: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.bold())
        .foregroundStyle(theme.secondaryForegroundColor)
      Text(value)
        .font(.system(size: 28, weight: .bold, design: .rounded))
      Text(detail)
        .font(.caption)
        .foregroundStyle(theme.accentColor)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(theme.borderColor)
    }
  }
}

private struct BYOKStudioPerformanceRow: View {
  let theme: AppTheme
  let provider: String
  let value: String
  let score: CGFloat

  var body: some View {
    VStack(spacing: 7) {
      HStack {
        Text(provider)
          .font(.subheadline.bold())
        Spacer()
        Text(value)
          .font(.caption.bold())
          .foregroundStyle(theme.secondaryForegroundColor)
      }

      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(theme.borderColor)
          Capsule()
            .fill(theme.accentColor)
            .frame(width: proxy.size.width * score)
        }
      }
      .frame(height: 7)
    }
  }
}
#endif