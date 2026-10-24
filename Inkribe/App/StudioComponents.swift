import AppFoundation
import SwiftUI

/// Shared chrome only. Caption artwork and video colors are never themed here.
private struct StudioCard: ViewModifier {
    @Environment(\.appFoundationTheme) private var theme
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(theme.borderColor, lineWidth: 1) }
    }
}

extension View {
    func studioCard(radius: CGFloat = 20) -> some View { modifier(StudioCard(radius: radius)) }
}

struct ProjectCreationHero: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let isEmpty: Bool
    let isBusy: Bool
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CAPTION STUDIO").font(.caption.weight(.semibold)).tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(isEmpty ? "Bring your words\nto the screen." : "Your words.\nReady to share.")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    Image(systemName: "captions.bubble.fill")
                        .font(.title2)
                        .foregroundStyle(theme.accentColor)
                        .padding(14)
                        .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                }
            }
            Text("Turn video or audio into captions, then make every line your own.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: create) {
                Label(isBusy ? "Preparing project…" : "New Project", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(isBusy)
            .accessibilityHint("Choose video or audio from Photos, Files or a direct media URL")
            .accessibilityIdentifier("home.newProject")
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(theme.surfaceColor)
                .overlay {
                    LinearGradient(colors: [theme.accentColor.opacity(0.14), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(theme.borderColor, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

struct StudioActivityLabel: View {
    @Environment(\.appFoundationTheme) private var theme
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(theme.accentColor)
                .frame(minWidth: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .studioCard()
        .accessibilityElement(children: .combine)
    }
}
