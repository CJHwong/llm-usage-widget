import WidgetKit
import SwiftUI

// Sandbox-safe widget that renders cached usage from the shared App Group
// container. The host app drives updates: it mirrors usage.json + the ChatGPT
// flag into the container and calls WidgetCenter.reloadTimelines. The timeline
// policy below is only a fallback for when the host hasn't pushed recently.
//
// Single family (.systemLarge), replicating the old floating panel's default
// (collapsed) layout: a header, two compact ring cards per provider, a divider.
// Widgets cannot hold tap-to-expand state, so the model breakdown is dropped;
// tapping the widget opens ollama.com/settings via widgetURL.

private let widgetKind = "OllamaGaugeWidget"

struct UsageEntry: TimelineEntry {
  let date: Date
  let usage: UsageData?
  let chatGPTEnabled: Bool
}

struct UsageProvider: TimelineProvider {
  func placeholder(in context: Context) -> UsageEntry {
    UsageEntry(date: Date(), usage: nil, chatGPTEnabled: false)
  }

  func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
    completion(currentEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
    let entry = currentEntry()
    // Fallback refresh; the host pushes on change, so this rarely drives an update.
    let next = Date().addingTimeInterval(300)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }

  private func currentEntry() -> UsageEntry {
    UsageEntry(date: Date(), usage: UsageDataStore.readUsage(), chatGPTEnabled: UsageDataStore.chatGPTEnabled)
  }
}

@main
struct OllamaGaugeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: widgetKind, provider: UsageProvider()) { entry in
      OllamaGaugeWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Ollama Gauge")
    .description("Ollama and ChatGPT Codex usage at a glance.")
    .supportedFamilies([.systemLarge])
  }
}

struct OllamaGaugeWidgetEntryView: View {
  let entry: UsageEntry

  var body: some View {
    PanelView(entry: entry)
      // Replicates the old floating window: a dark translucent glass panel
      // (GlassPanelBackground) over a transparent window. Color.clear alone let
      // the system's default light widget material show through (pale white).
      .containerBackground(for: .widget) { GlassPanelBackground() }
      .widgetURL(URL(string: "https://ollama.com/settings"))
  }
}

private struct PanelView: View {
  let entry: UsageEntry
  private var o: OllamaData? { entry.usage?.ollama }
  private var c: ChatGPTData? { entry.usage?.chatgpt }

  var body: some View {
    VStack(spacing: 0) {
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
      .padding(.horizontal, 18)
      .padding(.bottom, 12)

      VStack(spacing: 12) {
        if let o {
          ProviderColumn(title: "Ollama", cards: [
            (o.sessionPct, o.sessionResetsIn),
            (o.weeklyPct, o.weeklyResetsIn),
          ])
        }
        if entry.chatGPTEnabled {
          if o != nil { SectionDivider() }
          ProviderColumn(title: "ChatGPT", cards: [
            (c?.fiveHourPct ?? 0, c?.resets.first ?? ""),
            (c?.weeklyPct ?? 0, c?.resets.last ?? ""),
          ])
        }
        if entry.usage == nil && !entry.chatGPTEnabled {
          Text("No data yet").font(.system(size: 12)).foregroundColor(GlassTheme.secondaryText)
        }
      }
    }
    .padding(.vertical, 14)
  }
}

private struct ProviderColumn: View {
  let title: String
  let cards: [(pct: Double, resets: String)]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(GlassTheme.secondaryText)
      HStack(spacing: 8) {
        ForEach(cards.indices, id: \.self) { i in
          UsageCard(pct: cards[i].pct, resets: cards[i].resets, models: [], showModels: false)
        }
      }
    }
    .padding(.horizontal, 18)
  }
}