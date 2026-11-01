import SwiftUI

// The floating desktop panel: the original interactive window, ported from the
// pre-widget app. It keeps its own translucent look (distinct from the widget's
// opaque command-bar style) and its expand/collapse per-model breakdown. Types
// are namespaced (Desk*) because the host target also compiles Shared, which
// defines its own RingView / GlassPanelBackground / etc. for the widget.
//
// The host owns a PanelModel and updates it; the panel observes it. ChatGPT is
// shown only when the host reports it as `.on` (enabled + signed in); otherwise
// the section is hidden and the panel reflows smaller, like the original.

final class PanelModel: ObservableObject {
  @Published var usage: UsageData?
  @Published var errorMessage: String?
  @Published var isRefreshing = false
  @Published var isLoading = true
}

private enum DeskTheme {
  static let panelFill = Color.black.opacity(0.13)
  static let panelGlowTop = Color.white.opacity(0.16)
  static let panelGlowMid = Color.white.opacity(0.05)
  static let panelGlowBottom = Color.white.opacity(0.015)
  static let panelStroke = Color.white.opacity(0.16)
  static let panelInnerStroke = Color.white.opacity(0.05)
  static let cardFill = Color.white.opacity(0.075)
  static let cardTopGlow = Color.white.opacity(0.08)
  static let cardBottomShade = Color.black.opacity(0.06)
  static let cardStroke = Color.white.opacity(0.10)
  static let title = Color.white.opacity(0.96)
  static let primaryText = Color.white.opacity(0.92)
  static let secondaryText = Color.white.opacity(0.72)
  static let tertiaryText = Color.white.opacity(0.56)
  static let divider = Color.white.opacity(0.10)
  static let ringTrack = Color.white.opacity(0.22)
  static let textShadow = Color.black.opacity(0.35)
}

private enum DeskSeverity {
  case low, normal, elevated, critical

  var tint: Color {
    switch self {
    case .low: return .blue
    case .normal: return .green
    case .elevated: return .orange
    case .critical: return .red
    }
  }

  var tintOpacity: Double {
    switch self {
    case .low: return 0.05
    case .normal: return 0.025
    case .elevated: return 0.055
    case .critical: return 0.075
    }
  }

  static func from(pct: Double) -> DeskSeverity {
    if pct >= 80 { return .critical }
    if pct >= 50 { return .elevated }
    if pct <= 10 { return .low }
    return .normal
  }
}

private struct DeskPanelBackground: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(DeskTheme.panelFill)
      LinearGradient(
        colors: [DeskTheme.panelGlowTop, DeskTheme.panelGlowMid, DeskTheme.panelGlowBottom, .clear],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(DeskTheme.panelStroke, lineWidth: 0.8)
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(DeskTheme.panelInnerStroke, lineWidth: 0.5)
        .padding(1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .shadow(color: .black.opacity(0.22), radius: 24, y: 14)
  }
}

private struct DeskCardBackground: View {
  let severity: DeskSeverity
  let isExpanded: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(DeskTheme.cardFill)
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(severity.tint.opacity(isExpanded ? severity.tintOpacity + 0.015 : severity.tintOpacity))
      LinearGradient(
        colors: [DeskTheme.cardTopGlow, .clear, DeskTheme.cardBottomShade],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(DeskTheme.cardStroke, lineWidth: 0.6)
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: severity.tint.opacity(isExpanded ? 0.16 : 0.08), radius: isExpanded ? 14 : 8, y: 4)
  }
}

private struct DeskDivider: View {
  var body: some View {
    Capsule(style: .continuous)
      .fill(
        LinearGradient(
          colors: [.clear, DeskTheme.divider, .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .frame(height: 1)
      .padding(.horizontal, 18)
      .padding(.vertical, 2)
  }
}

private struct DeskLlamaBadge: View {
  var body: some View {
    ZStack {
      Circle().fill(Color.white.opacity(0.075))
      Circle().fill(
        LinearGradient(
          colors: [Color.white.opacity(0.12), .clear, Color.black.opacity(0.06)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.7)
      Text("🦙").font(.system(size: 14))
        .shadow(color: DeskTheme.textShadow.opacity(0.7), radius: 1, y: 1)
        .offset(y: -0.2)
    }
    .frame(width: 24, height: 24)
    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
  }
}

private struct DeskRing: View {
  let pct: Double
  let color: Color
  let size: CGFloat = 36
  let strokeWidth: CGFloat = 3
  var body: some View {
    ZStack {
      Circle().stroke(DeskTheme.ringTrack, lineWidth: strokeWidth)
      Circle().trim(from: 0, to: pct / 100).stroke(
        color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
      ).rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.5), value: pct)
      Text("\(Int(pct))%").font(.system(size: 11, weight: .bold)).foregroundColor(DeskTheme.primaryText)
        .shadow(color: DeskTheme.textShadow, radius: 1, y: 1)
    }.frame(width: size, height: size)
  }
}

private struct DeskModelRow: View {
  let model: ModelUsage
  let colors: [Color] = [.blue, .green, .orange, .red, .purple, .pink, .teal]
  var body: some View {
    HStack(spacing: 6) {
      GeometryReader { geo in
        RoundedRectangle(cornerRadius: 1.5).fill(colors[abs(model.model.hashValue % colors.count)])
          .frame(width: max(geo.size.width * CGFloat(model.pct) / 100, 2))
      }
      .frame(width: 60, height: 3).background(Color.white.opacity(0.12)).clipShape(
        RoundedRectangle(cornerRadius: 1.5))
      Text(model.model).font(.system(size: 11)).foregroundColor(DeskTheme.secondaryText).lineLimit(1)
      Spacer()
      Text("\(model.requests)").font(.system(size: 11)).foregroundColor(DeskTheme.tertiaryText)
        .monospacedDigit()
    }
  }
}

private struct DeskCard: View {
  let pct: Double
  let resets: String
  let models: [ModelUsage]
  let isExpanded: Bool
  private var severity: DeskSeverity { DeskSeverity.from(pct: pct) }

  var body: some View {
    VStack(spacing: 7) {
      DeskRing(pct: pct, color: pct >= 80 ? .red : pct >= 50 ? .yellow : pct <= 10 ? .blue : .green)
      Text(resets).font(.system(size: 9, weight: .medium)).foregroundColor(DeskTheme.tertiaryText)
        .lineLimit(1)
      if isExpanded {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(models.sorted(by: { $0.requests > $1.requests })) { m in DeskModelRow(model: m) }
          DeskDivider().padding(.horizontal, -18)
          Text("\(models.reduce(0) { $0 + $1.requests }) requests").font(.system(size: 9))
            .foregroundColor(DeskTheme.tertiaryText).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .frame(maxWidth: .infinity).padding(.vertical, 13).padding(.horizontal, 8)
    .background(DeskCardBackground(severity: severity, isExpanded: isExpanded))
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

private struct DeskProviderSection: View {
  let title: String
  let url: String
  let cards: [(pct: Double, resets: String, models: [ModelUsage])]
  var horizontalPadding: CGFloat = 18
  @State private var expandedIndex: Int? = nil

  private let gap: CGFloat = 8
  private let cardAnimation = Animation.spring(response: 0.32, dampingFraction: 0.84)

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }) {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(DeskTheme.secondaryText)
      }.buttonStyle(.plain)
      if let idx = expandedIndex, idx < cards.count {
        DeskCard(pct: cards[idx].pct, resets: cards[idx].resets, models: cards[idx].models, isExpanded: true)
          .frame(maxWidth: .infinity)
          .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                  removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))))
          .onTapGesture { withAnimation(cardAnimation) { expandedIndex = nil } }
      } else {
        HStack(spacing: gap) {
          ForEach(cards.indices, id: \.self) { i in
            DeskCard(pct: cards[i].pct, resets: cards[i].resets, models: cards[i].models, isExpanded: false)
              .frame(maxWidth: .infinity)
              .onTapGesture {
                guard !cards[i].models.isEmpty else { return }
                withAnimation(cardAnimation) { expandedIndex = i }
              }
          }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity.combined(with: .scale(scale: 0.97))))
      }
    }
    .animation(cardAnimation, value: expandedIndex)
    .padding(.horizontal, horizontalPadding)
  }
}

// Stands in for a provider section when it has no gauges to show: the selected
// browser isn't signed in, or the scrape stopped landing. Same header-as-link
// affordance as DeskProviderSection so it reads as the same kind of block, just
// empty with a reason. Severity above `.low` marks it as a fault, matching the
// widget's ProviderIndicator.
private struct DeskStatusSection: View {
  let title: String
  let message: String
  var detail: [String] = []
  var severity: DeskSeverity = .low
  let url: String
  var horizontalPadding: CGFloat = 18

  private var isFault: Bool { severity != .low }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }) {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(DeskTheme.secondaryText)
      }.buttonStyle(.plain)
      Button(action: { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }) {
        VStack(alignment: isFault ? .leading : .center, spacing: 4) {
          HStack(spacing: 4) {
            if isFault {
              Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            }
            Text(message).font(.system(size: 11, weight: .medium))
          }
          .foregroundColor(isFault ? severity.tint : DeskTheme.tertiaryText)
          ForEach(detail, id: \.self) { line in
            Text(line).font(.system(size: 10)).foregroundColor(DeskTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isFault ? 12 : 18)
        .padding(.horizontal, isFault ? 12 : 0)
        .background(DeskCardBackground(severity: severity, isExpanded: false))
      }.buttonStyle(.plain)
    }
    .padding(.horizontal, horizontalPadding)
  }
}

struct DesktopPanel: View {
  @ObservedObject var model: PanelModel

  private let ollamaURL = "https://ollama.com/settings"
  private let chatGPTURL = "https://chatgpt.com/codex/cloud/settings/analytics"
  private let claudeURL = "https://claude.ai/settings/usage"

  private var chatGPTStatus: ProviderStatus { model.usage?.chatGPTDisplayStatus ?? .off }
  private var claudeStatus: ProviderStatus { model.usage?.claudeDisplayStatus ?? .off }
  private var ollamaStatus: OllamaStatus { model.usage?.ollamaDisplayStatus ?? .unavailable }
  private var providerShown: Bool { chatGPTStatus == .on || claudeStatus == .on }
  private var browserRowVisible: Bool { chatGPTStatus != .off || claudeStatus != .off }

  // The paired browser row shows the 7-day meter only, half each.
  private var chatGPTWeeklyCard: [(pct: Double, resets: String, models: [ModelUsage])] {
    guard let c = model.usage?.chatgpt, let pct = c.weeklyPct else { return [] }
    return [(pct, c.weeklyReset ?? "", [])]
  }

  private var claudeWeeklyCard: [(pct: Double, resets: String, models: [ModelUsage])] {
    guard let c = model.usage?.claude else { return [] }
    return [(c.weeklyPct, c.weeklyReset, [])]
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        DeskLlamaBadge()
        Text("Usage").font(.system(size: 13, weight: .semibold)).foregroundColor(DeskTheme.title)
          .shadow(color: DeskTheme.textShadow, radius: 1, y: 1)
        Spacer()
        VStack(alignment: .trailing, spacing: 1) {
          if model.isRefreshing {
            HStack(spacing: 4) {
              ProgressView().scaleEffect(0.5).frame(height: 10).clipped()
              Text("Refreshing...").font(.system(size: 9.5)).foregroundColor(DeskTheme.secondaryText)
                .monospacedDigit()
            }.frame(height: 12)
          } else if let last = model.usage?.headerUpdatedText() {
            Text("Updated \(last)").font(.system(size: 9.5)).foregroundColor(DeskTheme.secondaryText)
              .monospacedDigit()
          }
          if let note = model.usage?.providerFailureNote() {
            Text(note).font(.system(size: 8.5, weight: .medium)).foregroundColor(.orange)
              .lineLimit(1).minimumScaleFactor(0.8)
          }
        }
      }
      .padding(.horizontal, 18)
      .padding(.bottom, 12)

      if model.isLoading && model.usage == nil && !providerShown {
        Spacer()
        ProgressView().scaleEffect(0.8)
        Spacer()
      } else if model.usage == nil, let err = model.errorMessage, !providerShown {
        Spacer()
        Text(err).font(.system(size: 12)).foregroundColor(DeskTheme.secondaryText)
          .multilineTextAlignment(.center).padding(.horizontal)
        Spacer()
      } else {
        VStack(spacing: 12) {
          if let o = model.usage?.ollama, ollamaStatus == .on {
            DeskProviderSection(
              title: "Ollama", url: ollamaURL,
              cards: [
                (o.sessionPct, o.sessionResetsIn, o.sessionModels),
                (o.weeklyPct, o.weeklyResetsIn, o.weeklyModels),
              ])
          } else if ollamaStatus == .stale {
            DeskStatusSection(
              title: "Ollama", message: "Not updating",
              detail: model.usage?.ollamaStaleDetail ?? [], severity: .elevated, url: ollamaURL)
          } else {
            DeskStatusSection(title: "Ollama", message: "Sign in to Ollama", url: ollamaURL)
          }
          if browserRowVisible {
            DeskDivider()
            HStack(alignment: .top, spacing: 8) {
              chatGPTSlot.frame(maxWidth: .infinity)
              claudeSlot.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 18)
          }
        }
      }
    }
    .frame(width: 300)
    .padding(.vertical, 14)
    .background(DeskPanelBackground())
    .onExitCommand { NSApp.terminate(nil) }
  }

  @ViewBuilder private var chatGPTSlot: some View {
    switch chatGPTStatus {
    case .on:
      DeskProviderSection(
        title: "ChatGPT", url: chatGPTURL, cards: chatGPTWeeklyCard, horizontalPadding: 0)
    case .off:
      DeskStatusSection(
        title: "ChatGPT", message: "ChatGPT off", url: chatGPTURL, horizontalPadding: 0)
    case .unavailable:
      if let issue = model.usage?.chatgptIssue {
        DeskStatusSection(
          title: "ChatGPT", message: "Not updating", detail: [issue], severity: .elevated,
          url: chatGPTURL, horizontalPadding: 0)
      } else {
        DeskStatusSection(
          title: "ChatGPT", message: "Sign in to ChatGPT", url: chatGPTURL, horizontalPadding: 0)
      }
    case .stale:
      DeskStatusSection(
        title: "ChatGPT", message: "Not updating",
        detail: model.usage?.chatgptStaleDetail ?? [], severity: .elevated, url: chatGPTURL,
        horizontalPadding: 0)
    }
  }

  @ViewBuilder private var claudeSlot: some View {
    switch claudeStatus {
    case .on:
      DeskProviderSection(
        title: "Claude", url: claudeURL, cards: claudeWeeklyCard, horizontalPadding: 0)
    case .off:
      DeskStatusSection(title: "Claude", message: "Claude off", url: claudeURL, horizontalPadding: 0)
    case .unavailable:
      if let issue = model.usage?.claudeIssue {
        DeskStatusSection(
          title: "Claude", message: "Not updating", detail: [issue], severity: .elevated,
          url: claudeURL, horizontalPadding: 0)
      } else {
        DeskStatusSection(
          title: "Claude", message: "Sign in to Claude", url: claudeURL, horizontalPadding: 0)
      }
    case .stale:
      DeskStatusSection(
        title: "Claude", message: "Not updating",
        detail: model.usage?.claudeStaleDetail ?? [], severity: .elevated, url: claudeURL,
        horizontalPadding: 0)
    }
  }
}
