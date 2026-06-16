import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "views")
private enum GlassTheme {
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

private enum CardSeverity {
  case low
  case normal
  case elevated
  case critical

  var tint: Color {
    switch self {
    case .low:
      return .blue
    case .normal:
      return .green
    case .elevated:
      return .orange
    case .critical:
      return .red
    }
  }

  var tintOpacity: Double {
    switch self {
    case .low:
      return 0.05
    case .normal:
      return 0.025
    case .elevated:
      return 0.055
    case .critical:
      return 0.075
    }
  }
}

private struct GlassPanelBackground: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(GlassTheme.panelFill)
      LinearGradient(
        colors: [GlassTheme.panelGlowTop, GlassTheme.panelGlowMid, GlassTheme.panelGlowBottom, .clear],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(GlassTheme.panelStroke, lineWidth: 0.8)
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(GlassTheme.panelInnerStroke, lineWidth: 0.5)
        .padding(1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .shadow(color: .black.opacity(0.22), radius: 24, y: 14)
  }
}

private struct GlassCardBackground: View {
  let severity: CardSeverity
  let isExpanded: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(GlassTheme.cardFill)
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(severity.tint.opacity(isExpanded ? severity.tintOpacity + 0.015 : severity.tintOpacity))
      LinearGradient(
        colors: [GlassTheme.cardTopGlow, .clear, GlassTheme.cardBottomShade],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(GlassTheme.cardStroke, lineWidth: 0.6)
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: severity.tint.opacity(isExpanded ? 0.16 : 0.08), radius: isExpanded ? 14 : 8, y: 4)
  }
}

private struct SectionDivider: View {
  var body: some View {
    Capsule(style: .continuous)
      .fill(
        LinearGradient(
          colors: [.clear, GlassTheme.divider, .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .frame(height: 1)
      .padding(.horizontal, 18)
      .padding(.vertical, 2)
  }
}

private struct LlamaBadge: View {
  var body: some View {
    ZStack {
      Circle()
        .fill(Color.white.opacity(0.075))
      Circle()
        .fill(
          LinearGradient(
            colors: [Color.white.opacity(0.12), .clear, Color.black.opacity(0.06)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
      Circle()
        .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
      Text("🦙")
        .font(.system(size: 14))
        .shadow(color: GlassTheme.textShadow.opacity(0.7), radius: 1, y: 1)
        .offset(y: -0.2)
    }
    .frame(width: 24, height: 24)
    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
  }
}

struct ContentView: View {
  @Binding var usage: UsageData?
  @Binding var isLoading: Bool
  @Binding var errorMessage: String?
  @Binding var isRefreshing: Bool
  @State private var window: NSWindow?
  let chatGPTTogglePath: String
  private var chatGPTEnabled: Bool {
    FileManager.default.fileExists(atPath: chatGPTTogglePath)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        LlamaBadge()
        Text("Usage").font(.system(size: 13, weight: .semibold)).foregroundColor(GlassTheme.title)
          .shadow(color: GlassTheme.textShadow, radius: 1, y: 1)
        Spacer()
        if isRefreshing {
          HStack(spacing: 4) {
            ProgressView().scaleEffect(0.5).frame(height: 10).clipped()
            Text("Refreshing...").font(.system(size: 9.5)).foregroundColor(GlassTheme.secondaryText)
              .monospacedDigit()
          }.frame(height: 12)
        } else if let last = usage?.lastUpdated {
          Text("Updated \(last)").font(.system(size: 9.5)).foregroundColor(GlassTheme.secondaryText)
            .monospacedDigit()
        }
      }
      .padding(.horizontal, 18)
      .padding(.bottom, 12)

      if isLoading && usage == nil && !chatGPTEnabled {
        Spacer()
        ProgressView().scaleEffect(0.8)
        Spacer()
      } else if usage == nil, let err = errorMessage, !chatGPTEnabled {
        Spacer()
        Text(err).font(.system(size: 12)).foregroundColor(GlassTheme.secondaryText).multilineTextAlignment(
          .center
        ).padding(.horizontal)
        Spacer()
      } else {
        VStack(spacing: 12) {
          if let o = usage?.ollama {
            ProviderSection(
              title: "Ollama", url: "https://ollama.com/settings",
              cards: [
                (o.sessionPct, o.sessionResetsIn, o.sessionModels),
                (o.weeklyPct, o.weeklyResetsIn, o.weeklyModels),
              ])
          }
          if chatGPTEnabled {
            if usage?.ollama != nil { SectionDivider() }
            ProviderSection(
              title: "ChatGPT", url: "https://chatgpt.com/codex/cloud/settings/analytics",
              cards: [
                (usage?.chatgpt?.fiveHourPct ?? 0, usage?.chatgpt?.resets.first ?? "", []),
                (usage?.chatgpt?.weeklyPct ?? 0, usage?.chatgpt?.resets.last ?? "", []),
              ])
          }
          if usage == nil && !chatGPTEnabled {
            Text("No data yet").font(.system(size: 12)).foregroundColor(GlassTheme.secondaryText)
          }
        }
      }
    }
    .padding(.top, 14).padding(.bottom, 14).padding(.horizontal, 0)
    .background(GlassPanelBackground())
    .background(WindowAccessor(window: $window))
    .onExitCommand { NSApp.terminate(nil) }
  }
}

struct ProviderSection: View {
  let title: String
  let url: String
  let cards: [(pct: Double, resets: String, models: [ModelUsage])]
  @State private var expandedIndex: Int? = nil

  private let gap: CGFloat = 8
  private var cardW: CGFloat { 300 - 36 }
  private let cardAnimation = Animation.spring(response: 0.32, dampingFraction: 0.84)

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }) {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(GlassTheme.secondaryText)
      }.buttonStyle(.plain)
      if let idx = expandedIndex, idx < cards.count {
        ExpandableCard(
          pct: cards[idx].pct, resets: cards[idx].resets, models: cards[idx].models,
          isExpanded: true
        )
        .frame(width: cardW)
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))))
        .onTapGesture {
          withAnimation(cardAnimation) { expandedIndex = nil }
        }
      } else {
        HStack(spacing: gap) {
          ForEach(cards.indices, id: \.self) { i in
            ExpandableCard(
              pct: cards[i].pct, resets: cards[i].resets, models: cards[i].models, isExpanded: false
            )
            .frame(width: (cardW - gap) / 2)
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
    .padding(.horizontal, 18)
  }
}

struct ExpandableCard: View {
  let pct: Double
  let resets: String
  let models: [ModelUsage]
  let isExpanded: Bool
  private var severity: CardSeverity {
    if pct >= 80 { return .critical }
    if pct >= 50 { return .elevated }
    if pct <= 10 { return .low }
    return .normal
  }

  var body: some View {
    VStack(spacing: 7) {
      RingView(pct: pct, color: pct >= 80 ? .red : pct >= 50 ? .yellow : pct <= 10 ? .blue : .green)
      Text(resets).font(.system(size: 9, weight: .medium)).foregroundColor(GlassTheme.tertiaryText)
        .lineLimit(1)
      if isExpanded {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(models.sorted(by: { $0.requests > $1.requests })) { m in ModelRow(model: m) }
          SectionDivider().padding(.horizontal, -18)
          Text("\(models.reduce(0) { $0 + $1.requests }) requests").font(.system(size: 9))
            .foregroundColor(GlassTheme.tertiaryText).frame(
              maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .frame(maxWidth: .infinity).padding(.vertical, 13).padding(.horizontal, 8)
    .background(GlassCardBackground(severity: severity, isExpanded: isExpanded))
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

struct ModelRow: View {
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
      Text(model.model).font(.system(size: 11)).foregroundColor(GlassTheme.secondaryText).lineLimit(1)
      Spacer()
      Text("\(model.requests)").font(.system(size: 11)).foregroundColor(GlassTheme.tertiaryText)
        .monospacedDigit()
    }
  }
}

struct RingView: View {
  let pct: Double
  let color: Color
  let size: CGFloat = 36
  let strokeWidth: CGFloat = 3
  var body: some View {
    ZStack {
      Circle().stroke(GlassTheme.ringTrack, lineWidth: strokeWidth)
      Circle().trim(from: 0, to: pct / 100).stroke(
        color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
      ).rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.5), value: pct)
      Text("\(Int(pct))%").font(.system(size: 11, weight: .bold)).foregroundColor(GlassTheme.primaryText)
        .shadow(color: GlassTheme.textShadow, radius: 1, y: 1)
    }.frame(width: size, height: size)
  }
}
