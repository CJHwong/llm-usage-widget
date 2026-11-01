import WidgetKit
import SwiftUI

// Two widgets, no runtime toggle: the family you add in Notification Center
// decides what's shown. "Ollama" is medium (Ollama only); "Ollama + ChatGPT +
// Claude" is large. The host scrapes the browser providers only while their
// menu-bar switches are on, and one Playwright pass serves both.
//
// Both render cached usage from the shared App Group container; the host pushes
// updates via WidgetCenter.reloadAllTimelines. The 300s timeline policy is only
// a fallback for when the host hasn't pushed recently. Widgets can't hold
// tap-to-expand state, so tapping opens ollama.com/settings via widgetURL.

struct UsageEntry: TimelineEntry {
  let date: Date
  let usage: UsageData?
}

struct UsageProvider: TimelineProvider {
  func placeholder(in context: Context) -> UsageEntry {
    UsageEntry(date: Date(), usage: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
    completion(currentEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
    let next = Date().addingTimeInterval(300)
    completion(Timeline(entries: [currentEntry()], policy: .after(next)))
  }

  private func currentEntry() -> UsageEntry {
    UsageEntry(date: Date(), usage: UsageDataStore.readUsage())
  }
}

@main
struct OllamaGaugeBundle: WidgetBundle {
  var body: some Widget {
    OllamaWidget()
    OllamaChatGPTWidget()
  }
}

struct OllamaWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetKinds.ollama, provider: UsageProvider()) { entry in
      PanelView(entry: entry, showChatGPT: false, ringSize: 54)
        .containerBackground(for: .widget) { GlassPanelBackground() }
        .widgetURL(URL(string: "https://ollama.com/settings"))
    }
    .configurationDisplayName("Ollama")
    .description("Ollama usage at a glance.")
    .supportedFamilies([.systemMedium])
  }
}

struct OllamaChatGPTWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetKinds.ollamaChatGPT, provider: UsageProvider()) { entry in
      PanelView(entry: entry, showChatGPT: true, ringSize: 66)
        .containerBackground(for: .widget) { GlassPanelBackground() }
        .widgetURL(URL(string: "https://ollama.com/settings"))
    }
    .configurationDisplayName("Ollama + ChatGPT + Claude")
    .description("Ollama, ChatGPT Codex, and Claude weekly usage at a glance.")
    .supportedFamilies([.systemLarge])
  }
}

struct PanelView: View {
  let entry: UsageEntry
  let showChatGPT: Bool
  let ringSize: CGFloat
  private var o: OllamaData? { entry.usage?.ollama }
  private var c: ChatGPTData? { entry.usage?.chatgpt }
  private var cl: ClaudeData? { entry.usage?.claude }

  // No manual edge padding: WidgetKit already insets content by its default
  // 16pt content margin. The dark panel (containerBackground) fills edge to
  // edge; only the inter-element spacing lives here.
  var body: some View {
    VStack(spacing: 10) {
      HStack {
        LlamaBadge()
        Text("Usage").font(.system(size: 13, weight: .semibold)).foregroundColor(GlassTheme.title)
          .shadow(color: GlassTheme.textShadow, radius: 1, y: 1)
        Spacer()
        VStack(alignment: .trailing, spacing: 1) {
          if let last = entry.usage?.headerUpdatedText(includeBrowserProviders: showChatGPT) {
            Text("Updated \(last)").font(.system(size: 9.5)).foregroundColor(GlassTheme.secondaryText)
              .monospacedDigit().lineLimit(1)
          }
          if let note = entry.usage?.providerFailureNote(includeBrowserProviders: showChatGPT) {
            Text(note).font(.system(size: 8.5, weight: .medium)).foregroundColor(.orange)
              .lineLimit(1).minimumScaleFactor(0.8)
          }
        }
      }

      if let usage = entry.usage {
        switch usage.ollamaDisplayStatus {
        case .on:
          if let o {
            // Ollama-only widget drops the redundant "Ollama" header (the widget
            // is named Ollama); the combined widget keeps it to pair "ChatGPT".
            ProviderColumn(title: "Ollama", cards: [
              (o.sessionPct, o.sessionResetsIn),
              (o.weeklyPct, o.weeklyResetsIn),
            ], ringSize: ringSize, showTitle: showChatGPT)
          }
        case .unavailable:
          ProviderIndicator(
            title: "Ollama", message: "Sign in to Ollama", ringSize: ringSize, showTitle: showChatGPT)
        case .stale:
          ProviderIndicator(
            title: "Ollama", message: "Not updating", detail: usage.ollamaStaleDetail,
            severity: .elevated, ringSize: ringSize, showTitle: showChatGPT)
        }
      }
      if showChatGPT {
        SectionDivider()
        // The two browser providers share one row, half each, and show only the
        // 7-day meter.
        HStack(alignment: .top, spacing: 10) {
          chatGPTSlot.frame(maxWidth: .infinity)
          claudeSlot.frame(maxWidth: .infinity)
        }
      }
      if entry.usage == nil {
        Text("No data yet").font(.system(size: 12)).foregroundColor(GlassTheme.secondaryText)
      }
    }
  }

  @ViewBuilder private var chatGPTSlot: some View {
    switch entry.usage?.chatGPTDisplayStatus ?? .off {
    case .on:
      if let pct = c?.weeklyPct {
        ProviderColumn(
          title: "ChatGPT", cards: [(pct, c?.weeklyReset ?? "")], ringSize: ringSize)
      } else {
        ProviderIndicator(title: "ChatGPT", message: "No weekly meter", ringSize: ringSize)
      }
    case .off:
      ProviderIndicator(title: "ChatGPT", message: "ChatGPT off", ringSize: ringSize)
    case .unavailable:
      // A scrape issue explains why; only a clean not-signed-in (issue nil) is
      // a sign-in prompt.
      if let issue = entry.usage?.chatgptIssue {
        ProviderIndicator(
          title: "ChatGPT", message: "Not updating", detail: [issue], severity: .elevated,
          ringSize: ringSize)
      } else {
        ProviderIndicator(title: "ChatGPT", message: "Sign in to ChatGPT", ringSize: ringSize)
      }
    case .stale:
      ProviderIndicator(
        title: "ChatGPT", message: "Not updating",
        detail: entry.usage?.chatgptStaleDetail ?? [], severity: .elevated, ringSize: ringSize)
    }
  }

  @ViewBuilder private var claudeSlot: some View {
    switch entry.usage?.claudeDisplayStatus ?? .off {
    case .on:
      if let pct = cl?.weeklyPct {
        ProviderColumn(
          title: "Claude", cards: [(pct, cl?.weeklyReset ?? "")], ringSize: ringSize)
      } else {
        ProviderIndicator(title: "Claude", message: "No weekly meter", ringSize: ringSize)
      }
    case .off:
      ProviderIndicator(title: "Claude", message: "Claude off", ringSize: ringSize)
    case .unavailable:
      if let issue = entry.usage?.claudeIssue {
        ProviderIndicator(
          title: "Claude", message: "Not updating", detail: [issue], severity: .elevated,
          ringSize: ringSize)
      } else {
        ProviderIndicator(title: "Claude", message: "Sign in to Claude", ringSize: ringSize)
      }
    case .stale:
      ProviderIndicator(
        title: "Claude", message: "Not updating",
        detail: entry.usage?.claudeStaleDetail ?? [], severity: .elevated, ringSize: ringSize)
    }
  }
}

private struct ProviderColumn: View {
  let title: String
  let cards: [(pct: Double, resets: String)]
  var ringSize: CGFloat = 66
  var showTitle: Bool = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showTitle {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(GlassTheme.secondaryText)
      }
      HStack(spacing: 8) {
        ForEach(cards.indices, id: \.self) { i in
          UsageCard(pct: cards[i].pct, resets: cards[i].resets, ringSize: ringSize)
        }
      }
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
  }
}

// Stands in for a provider slot when it can't show gauges: off, not signed in,
// or no longer updating. A fixed-size widget can't reflow away the section, so
// it says why it's empty. Heights roughly match a gauge row so toggling doesn't
// jump the layout. Anything above `.low` severity reads as a fault and gets the
// warning glyph and tint; plain states stay quiet and centered.
private struct ProviderIndicator: View {
  let title: String
  let message: String
  var detail: [String] = []
  var severity: CardSeverity = .low
  let ringSize: CGFloat
  var showTitle: Bool = true

  private var isFault: Bool { severity != .low }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showTitle {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(GlassTheme.secondaryText)
      }
      VStack(alignment: isFault ? .leading : .center, spacing: 5) {
        HStack(spacing: 5) {
          if isFault {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
          }
          Text(message).font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(isFault ? severity.tint : GlassTheme.tertiaryText)
        ForEach(detail, id: \.self) { line in
          Text(line).font(.system(size: 11)).foregroundColor(GlassTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(isFault ? 12 : 0)
      .frame(maxWidth: .infinity)
      .frame(minHeight: ringSize + 36)
      .background(GlassCardBackground(severity: severity))
    }
  }
}