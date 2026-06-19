import WidgetKit
import SwiftUI

// Two widgets, no runtime toggle: the family you add in Notification Center
// decides what's shown. "Ollama" is medium (Ollama only); "Ollama + ChatGPT"
// is large (both providers). The host scrapes ChatGPT only when the large
// widget is installed (Scraper.isChatGPTWidgetInstalled), so adding/removing
// a widget is the single source of truth for both display and scraping.
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
    .configurationDisplayName("Ollama + ChatGPT")
    .description("Ollama and ChatGPT Codex usage at a glance.")
    .supportedFamilies([.systemLarge])
  }
}

private struct PanelView: View {
  let entry: UsageEntry
  let showChatGPT: Bool
  let ringSize: CGFloat
  private var o: OllamaData? { entry.usage?.ollama }
  private var c: ChatGPTData? { entry.usage?.chatgpt }

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
        if let last = entry.usage?.lastUpdated {
          Text("Updated \(last)").font(.system(size: 9.5)).foregroundColor(GlassTheme.secondaryText)
            .monospacedDigit().lineLimit(1)
        }
      }

      if let o {
        // Ollama-only widget drops the redundant "Ollama" header (the widget is
        // named Ollama); the combined widget keeps it to pair with "ChatGPT".
        ProviderColumn(title: "Ollama", cards: [
          (o.sessionPct, o.sessionResetsIn),
          (o.weeklyPct, o.weeklyResetsIn),
        ], ringSize: ringSize, showTitle: showChatGPT)
      }
      if showChatGPT {
        if o != nil { SectionDivider() }
        switch entry.usage?.chatgptStatus ?? .off {
        case .on:
          ProviderColumn(title: "ChatGPT", cards: [
            (c?.fiveHourPct ?? 0, c?.resets.first ?? ""),
            (c?.weeklyPct ?? 0, c?.resets.last ?? ""),
          ], ringSize: ringSize, showTitle: true)
        case .off:
          ChatGPTIndicator(message: "ChatGPT off", ringSize: ringSize)
        case .unavailable:
          ChatGPTIndicator(message: "Sign in to ChatGPT", ringSize: ringSize)
        }
      }
      if entry.usage == nil {
        Text("No data yet").font(.system(size: 12)).foregroundColor(GlassTheme.secondaryText)
      }
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
    }
  }
}

// Shown in the large widget's ChatGPT slot when it's off or not signed in. A
// fixed-size widget can't reflow away the section, so it says why it's empty.
// Heights roughly match a gauge row so toggling doesn't jump the layout.
private struct ChatGPTIndicator: View {
  let message: String
  let ringSize: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("ChatGPT").font(.system(size: 12, weight: .semibold)).foregroundColor(GlassTheme.secondaryText)
      Text(message)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(GlassTheme.tertiaryText)
        .frame(maxWidth: .infinity)
        .frame(height: ringSize + 36)
        .background(GlassCardBackground(severity: .low))
    }
  }
}