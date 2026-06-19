import SwiftUI

// Pure-SwiftUI, widget-safe view primitives shared by the widget extension.
// No AppKit, no tap gestures, no GeometryReader: those don't compile or behave
// inside a WidgetKit extension. The interactive expand/collapse from the old
// floating window is dropped; the widget navigates via widgetURL instead.

enum GlassTheme {
  // Command-bar palette: an opaque dark-slate field with a whisper of top
  // lift, not translucent glass. WidgetKit can't show the wallpaper through
  // it anyway, so an opaque surface is the right call (see WIDGET_NOTES.md).
  static let panelFill = Color(red: 0.102, green: 0.114, blue: 0.137)
  static let panelGlowTop = Color.white.opacity(0.05)
  static let panelGlowMid = Color.white.opacity(0.012)
  static let panelGlowBottom = Color.clear
  static let panelStroke = Color.white.opacity(0.08)
  static let panelInnerStroke = Color.white.opacity(0.03)
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
        colors: [GlassTheme.panelGlowTop, GlassTheme.panelGlowMid, GlassTheme.panelGlowBottom],
        startPoint: .top,
        endPoint: .bottom
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

  init(pct: Double, color: Color, size: CGFloat = 66, strokeWidth: CGFloat = 5) {
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
      Text("\(Int(pct))%").font(.system(size: size * 0.28, weight: .bold)).foregroundColor(GlassTheme.primaryText)
        .shadow(color: GlassTheme.textShadow, radius: 1, y: 1)
    }.frame(width: size, height: size)
  }
}

// Static (non-interactive) card: a ring with its reset label. ringSize lets
// the medium widget use a smaller gauge than the large one.
struct UsageCard: View {
  let pct: Double
  let resets: String
  var ringSize: CGFloat = 66
  private var severity: CardSeverity { CardSeverity.from(pct: pct) }
  private var ringColor: Color {
    pct >= 80 ? .red : pct >= 50 ? .yellow : pct <= 10 ? .blue : .green
  }

  var body: some View {
    VStack(spacing: 6) {
      RingView(pct: pct, color: ringColor, size: ringSize)
      Text(resets).font(.system(size: 11, weight: .medium)).foregroundColor(GlassTheme.tertiaryText)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 8).padding(.horizontal, 8)
    .background(GlassCardBackground(severity: severity))
  }
}