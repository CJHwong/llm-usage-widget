import SwiftUI

// Pure-SwiftUI, widget-safe view primitives shared by the widget extension.
// No AppKit, no tap gestures, no GeometryReader: those don't compile or behave
// inside a WidgetKit extension. The interactive expand/collapse from the old
// floating window is dropped; the widget navigates via widgetURL instead.

enum GlassTheme {
  static let panelFill = Color.black.opacity(0.22)
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

enum CardSeverity {
  case low
  case normal
  case elevated
  case critical

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

  static func from(pct: Double) -> CardSeverity {
    if pct >= 80 { return .critical }
    if pct >= 50 { return .elevated }
    if pct <= 10 { return .low }
    return .normal
  }
}

struct GlassPanelBackground: View {
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
  }
}

struct GlassCardBackground: View {
  let severity: CardSeverity

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(GlassTheme.cardFill)
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(severity.tint.opacity(severity.tintOpacity))
      LinearGradient(
        colors: [GlassTheme.cardTopGlow, .clear, GlassTheme.cardBottomShade],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(GlassTheme.cardStroke, lineWidth: 0.6)
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

struct SectionDivider: View {
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

struct LlamaBadge: View {
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
  }
}

struct RingView: View {
  let pct: Double
  let color: Color
  let size: CGFloat
  let strokeWidth: CGFloat

  init(pct: Double, color: Color, size: CGFloat = 36, strokeWidth: CGFloat = 3) {
    self.pct = pct
    self.color = color
    self.size = size
    self.strokeWidth = strokeWidth
  }

  var body: some View {
    ZStack {
      Circle().stroke(GlassTheme.ringTrack, lineWidth: strokeWidth)
      Circle().trim(from: 0, to: pct / 100).stroke(
        color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
      ).rotationEffect(.degrees(-90))
      Text("\(Int(pct))%").font(.system(size: 11, weight: .bold)).foregroundColor(GlassTheme.primaryText)
        .shadow(color: GlassTheme.textShadow, radius: 1, y: 1)
    }.frame(width: size, height: size)
  }
}

struct ModelRow: View {
  let model: ModelUsage
  let colors: [Color] = [.blue, .green, .orange, .red, .purple, .pink, .teal]
  private let trackWidth: CGFloat = 60

  var body: some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(colors[abs(model.model.hashValue % colors.count)])
        .frame(width: max(trackWidth * CGFloat(model.pct) / 100, 2), height: 3)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
        .frame(width: trackWidth, height: 3, alignment: .leading)
      Text(model.model).font(.system(size: 11)).foregroundColor(GlassTheme.secondaryText).lineLimit(1)
      Spacer(minLength: 0)
      Text("\(model.requests)").font(.system(size: 11)).foregroundColor(GlassTheme.tertiaryText)
        .monospacedDigit()
    }
  }
}

// Static (non-interactive) card: ring + reset label, optional compact model list
// for the large widget family.
struct UsageCard: View {
  let pct: Double
  let resets: String
  let models: [ModelUsage]
  let showModels: Bool
  private var severity: CardSeverity { CardSeverity.from(pct: pct) }
  private var ringColor: Color {
    pct >= 80 ? .red : pct >= 50 ? .yellow : pct <= 10 ? .blue : .green
  }

  var body: some View {
    VStack(spacing: 7) {
      RingView(pct: pct, color: ringColor)
      Text(resets).font(.system(size: 9, weight: .medium)).foregroundColor(GlassTheme.tertiaryText)
        .lineLimit(1)
      if showModels && !models.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(models.sorted(by: { $0.requests > $1.requests }).prefix(4)) { m in ModelRow(model: m) }
          Text("\(models.reduce(0) { $0 + $1.requests }) requests")
            .font(.system(size: 9)).foregroundColor(GlassTheme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 2)
      }
    }
    .frame(maxWidth: .infinity).padding(.vertical, 13).padding(.horizontal, 8)
    .background(GlassCardBackground(severity: severity))
  }
}