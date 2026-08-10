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

private struct BYOKStudioChatFixture: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKStudioScaledFixture(designSize: CGSize(width: 520, height: 930)) {
      VStack(spacing: 16) {
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

            Text("MCP 3")
              .font(.caption.bold())
              .foregroundStyle(settings.theme.accentColor)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(settings.theme.accentColor.opacity(0.12), in: Capsule())
          }
        }

        VStack(spacing: 14) {
          HStack {
            Spacer(minLength: 58)
            Text("Compare the launch risks and give me the three things I should fix first.")
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(settings.theme.backgroundColor)
              .padding(.horizontal, 16)
              .padding(.vertical, 13)
              .background(settings.theme.accentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
          }

          BYOKStudioCard(theme: settings.theme) {
            VStack(alignment: .leading, spacing: 14) {
              HStack(spacing: 8) {
                Image(systemName: "brain.head.profile.fill")
                Text("Reasoned for 8s")
              }
              .font(.caption.bold())
              .foregroundStyle(settings.theme.secondaryForegroundColor)

              Text("The highest-risk areas are purchase configuration, local-network permissions, and release validation. I’d fix them in that order.")
                .font(.system(size: 16))
                .fixedSize(horizontal: false, vertical: true)

              Divider().overlay(settings.theme.borderColor)

              Label("Checked project configuration", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(settings.theme.accentColor)
            }
          }

          BYOKStudioCard(theme: settings.theme) {
            HStack(spacing: 12) {
              Image(systemName: "shippingbox.fill")
                .foregroundStyle(settings.theme.accentColor)
              VStack(alignment: .leading, spacing: 3) {
                Text("GitHub · repository search")
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

        Spacer(minLength: 0)

        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 12) {
            Image(systemName: "plus")
              .foregroundStyle(settings.theme.secondaryForegroundColor)
            Text("Message Claude Sonnet 4")
              .foregroundStyle(settings.theme.secondaryForegroundColor)
            Spacer()
            Image(systemName: "arrow.up.circle.fill")
              .font(.title2)
              .foregroundStyle(settings.theme.accentColor)
          }
        }
      }
    }
  }
}

private struct BYOKStudioProvidersFixture: View {
  let settings: BYOKScreenshotStudioSettings

  private let providers = [
    ("OpenRouter", "openrouter.ai", "bolt.horizontal.fill", "240+ models"),
    ("Anthropic", "Personal", "sparkles", "Claude Sonnet 4"),
    ("Gemini", "Google AI", "diamond.fill", "Gemini 2.5 Pro"),
    ("DeepSeek", "Primary", "brain.fill", "DeepSeek Chat"),
    ("Local Server", "192.168.1.42", "network", "Qwen3 30B"),
  ]

  var body: some View {
    BYOKStudioScaledFixture(designSize: CGSize(width: 520, height: 920)) {
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

        ForEach(Array(providers.enumerated()), id: \.offset) { _, provider in
          BYOKStudioCard(theme: settings.theme) {
            HStack(spacing: 14) {
              Image(systemName: provider.2)
                .font(.title3.bold())
                .foregroundStyle(settings.theme.accentColor)
                .frame(width: 44, height: 44)
                .background(settings.theme.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))

              VStack(alignment: .leading, spacing: 4) {
                Text(provider.0)
                  .font(.headline)
                HStack(spacing: 6) {
                  Text(provider.1)
                  Text("•")
                  Text(provider.3)
                }
                .font(.caption)
                .foregroundStyle(settings.theme.secondaryForegroundColor)
              }

              Spacer()

              Text("Connected")
                .font(.caption.bold())
                .foregroundStyle(settings.theme.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(settings.theme.accentColor.opacity(0.10), in: Capsule())
            }
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
              .foregroundStyle(settings.theme.accentColor)
            Text("No BYOK account. No proxy. Your app talks directly to your providers.")
              .font(.subheadline.weight(.semibold))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}

private struct BYOKStudioMCPFixture: View {
  let settings: BYOKScreenshotStudioSettings

  private let tools = [
    ("search_repositories", "Search repositories", "Always Allow", "checkmark.shield.fill"),
    ("fetch_file", "Read repository files", "Always Allow", "checkmark.shield.fill"),
    ("create_issue", "Create GitHub issues", "Ask", "questionmark.circle.fill"),
    ("delete_file", "Delete repository files", "Disabled", "nosign"),
  ]

  var body: some View {
    BYOKStudioScaledFixture(designSize: CGSize(width: 520, height: 920)) {
      VStack(spacing: 16) {
        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
              Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(settings.theme.accentColor)
                .frame(width: 48, height: 48)
                .background(settings.theme.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))

              VStack(alignment: .leading, spacing: 4) {
                Text("GitHub MCP")
                  .font(.title3.bold())
                Text("Remote · 12 tools discovered")
                  .font(.caption)
                  .foregroundStyle(settings.theme.secondaryForegroundColor)
              }

              Spacer()

              Circle()
                .fill(.green)
                .frame(width: 10, height: 10)
            }

            Divider().overlay(settings.theme.borderColor)

            HStack {
              Label("Enabled for this chat", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(settings.theme.accentColor)
              Spacer()
              Text("HTTPS")
                .font(.caption.bold())
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 0) {
            Text("Tool permissions")
              .font(.headline)
              .padding(.bottom, 12)

            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
              if index > 0 {
                Divider().overlay(settings.theme.borderColor)
              }

              HStack(spacing: 12) {
                Image(systemName: tool.3)
                  .foregroundStyle(tool.2 == "Disabled" ? settings.theme.secondaryForegroundColor : settings.theme.accentColor)
                  .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                  Text(tool.1)
                    .font(.subheadline.bold())
                  Text(tool.0)
                    .font(.caption.monospaced())
                    .foregroundStyle(settings.theme.secondaryForegroundColor)
                }

                Spacer()

                Text(tool.2)
                  .font(.caption.bold())
                  .foregroundStyle(tool.2 == "Disabled" ? settings.theme.secondaryForegroundColor : settings.theme.accentColor)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 5)
                  .background(
                    (tool.2 == "Disabled" ? settings.theme.secondaryForegroundColor : settings.theme.accentColor).opacity(0.10),
                    in: Capsule()
                  )
              }
              .padding(.vertical, 12)
            }
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
              .foregroundStyle(settings.theme.accentColor)
            Text("Sensitive tools can ask every time before anything runs.")
              .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
          }
        }
      }
    }
  }
}

private struct BYOKStudioProjectsFixture: View {
  let settings: BYOKScreenshotStudioSettings

  var body: some View {
    BYOKStudioScaledFixture(designSize: CGSize(width: 520, height: 920)) {
      VStack(spacing: 16) {
        HStack(spacing: 14) {
          BYOKStudioProjectTile(
            theme: settings.theme,
            title: "BYOK Launch",
            detail: "12 chats · Claude Sonnet 4",
            symbol: "paperplane.fill",
            selected: true
          )
          BYOKStudioProjectTile(
            theme: settings.theme,
            title: "Research",
            detail: "8 chats · Gemini 2.5 Pro",
            symbol: "magnifyingglass",
            selected: false
          )
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text("BYOK Launch")
                  .font(.title3.bold())
                Text("Project workspace")
                  .font(.caption)
                  .foregroundStyle(settings.theme.secondaryForegroundColor)
              }
              Spacer()
              Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }

            HStack(spacing: 8) {
              BYOKStudioChip(theme: settings.theme, text: "Claude Sonnet 4", symbol: "sparkles")
              BYOKStudioChip(theme: settings.theme, text: "3 MCP", symbol: "shippingbox.fill")
              BYOKStudioChip(theme: settings.theme, text: "6 files", symbol: "paperclip")
            }
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 0) {
            Text("Recent chats")
              .font(.headline)
              .padding(.bottom, 10)

            BYOKStudioChatRow(theme: settings.theme, title: "Release readiness review", detail: "2 min ago", symbol: "checkmark.seal.fill")
            Divider().overlay(settings.theme.borderColor)
            BYOKStudioChatRow(theme: settings.theme, title: "App Store screenshot copy", detail: "Yesterday", symbol: "photo.stack.fill")
            Divider().overlay(settings.theme.borderColor)
            BYOKStudioChatRow(theme: settings.theme, title: "Provider pricing research", detail: "Yesterday", symbol: "dollarsign.circle.fill")
            Divider().overlay(settings.theme.borderColor)
            BYOKStudioChatRow(theme: settings.theme, title: "MCP permission design", detail: "3 days ago", symbol: "shippingbox.fill")
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 12) {
            Image(systemName: "text.quote")
              .foregroundStyle(settings.theme.accentColor)
            VStack(alignment: .leading, spacing: 3) {
              Text("Project instructions")
                .font(.subheadline.bold())
              Text("Ship BYOK 1.0 with a minimal, native iPhone experience.")
                .font(.caption)
                .foregroundStyle(settings.theme.secondaryForegroundColor)
            }
            Spacer()
          }
        }
      }
    }
  }
}

private struct BYOKStudioAnalyticsFixture: View {
  let settings: BYOKScreenshotStudioSettings

  private let bars: [CGFloat] = [0.42, 0.58, 0.36, 0.72, 0.63, 0.88, 0.76]

  var body: some View {
    BYOKStudioScaledFixture(designSize: CGSize(width: 520, height: 920)) {
      VStack(spacing: 16) {
        HStack(spacing: 12) {
          BYOKStudioMetricCard(theme: settings.theme, title: "Spend", value: "$12.48", detail: "This month")
          BYOKStudioMetricCard(theme: settings.theme, title: "Requests", value: "842", detail: "+18%")
        }

        HStack(spacing: 12) {
          BYOKStudioMetricCard(theme: settings.theme, title: "Input", value: "3.2M", detail: "tokens")
          BYOKStudioMetricCard(theme: settings.theme, title: "Output", value: "824K", detail: "tokens")
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
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

            HStack(alignment: .bottom, spacing: 12) {
              ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                VStack(spacing: 7) {
                  RoundedRectangle(cornerRadius: 5)
                    .fill(
                      index == bars.count - 2
                        ? settings.theme.accentColor
                        : settings.theme.accentColor.opacity(0.35)
                    )
                    .frame(height: 150 * height)
                  Text(["M", "T", "W", "T", "F", "S", "S"][index])
                    .font(.caption2.bold())
                    .foregroundStyle(settings.theme.secondaryForegroundColor)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
              }
            }
            .frame(height: 180, alignment: .bottom)
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          VStack(alignment: .leading, spacing: 14) {
            Text("Provider performance")
              .font(.headline)

            BYOKStudioPerformanceRow(theme: settings.theme, provider: "Anthropic", value: "1.2s TTFT", score: 0.91)
            BYOKStudioPerformanceRow(theme: settings.theme, provider: "OpenRouter", value: "1.6s TTFT", score: 0.82)
            BYOKStudioPerformanceRow(theme: settings.theme, provider: "Gemini", value: "1.4s TTFT", score: 0.86)
          }
        }

        BYOKStudioCard(theme: settings.theme) {
          HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
              .foregroundStyle(settings.theme.accentColor)
            Text("Usage telemetry stays on-device and excludes prompts, responses, and credentials.")
              .font(.subheadline.weight(.semibold))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}

private struct BYOKStudioScaledFixture<Content: View>: View {
  let designSize: CGSize
  private let content: Content

  init(designSize: CGSize, @ViewBuilder content: () -> Content) {
    self.designSize = designSize
    self.content = content()
  }

  var body: some View {
    GeometryReader { proxy in
      let scale = min(
        proxy.size.width / designSize.width,
        proxy.size.height / designSize.height
      )

      content
        .frame(width: designSize.width, height: designSize.height, alignment: .top)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(
          width: designSize.width * scale,
          height: designSize.height * scale,
          alignment: .topLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    .allowsHitTesting(false)
  }
}

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

private struct BYOKStudioProjectTile: View {
  let theme: AppTheme
  let title: String
  let detail: String
  let symbol: String
  let selected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: symbol)
        .font(.title2.bold())
        .foregroundStyle(theme.accentColor)
        .frame(width: 44, height: 44)
        .background(theme.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.caption)
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      selected ? theme.accentColor.opacity(0.12) : theme.elevatedSurfaceColor,
      in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .strokeBorder(selected ? theme.accentColor : theme.borderColor, lineWidth: selected ? 2 : 1)
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
    .padding(.vertical, 11)
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
    VStack(alignment: .leading, spacing: 7) {
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
