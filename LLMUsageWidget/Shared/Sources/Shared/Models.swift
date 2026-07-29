import Foundation

// Derived ChatGPT display state, computed by the host and read by both the
// widget and the desktop panel. `on` = enabled and signed in (data present);
// `off` = disabled in the menu bar; `unavailable` = enabled but no data yet
// (not signed in / scrape failing); `stale` = we still hold numbers but the
// scrape stopped landing long enough ago that showing them as live would lie.
enum ChatGPTStatus: String, Codable {
  case on
  case off
  case unavailable
  case stale
}

// Derived Ollama display state. `on` = signed in (data present); `unavailable`
// = the selected browser has no Ollama session. No master toggle, so no `off`.
enum OllamaStatus: String, Codable {
  case on
  case unavailable
}

struct UsageData: Codable {
  var ollama: OllamaData?
  var chatgpt: ChatGPTData?
  // Optional so older usage.json without the key still decodes; nil reads as off.
  var chatgptStatus: ChatGPTStatus?
  // Optional for the same reason; a nil value is resolved from `ollama` below.
  var ollamaStatus: OllamaStatus?
  var lastUpdated: String = ""
  // When the last ChatGPT scrape actually landed, and the short reason the
  // current one is failing. `lastUpdated` can't answer either: it's rewritten by
  // every Ollama cycle, so a dead ChatGPT scrape still looks freshly stamped.
  // Dates use JSONEncoder's default strategy, matching the plain decoders in
  // Scraper.read and UsageDataStore.readUsage.
  var chatgptUpdatedAt: Date?
  var chatgptIssue: String?
  enum CodingKeys: String, CodingKey {
    case ollama, chatgpt
    case chatgptStatus = "chatgpt_status"
    case ollamaStatus = "ollama_status"
    case lastUpdated = "last_updated"
    case chatgptUpdatedAt = "chatgpt_updated_at"
    case chatgptIssue = "chatgpt_issue"
  }

  // Defaults a nil status (old payloads) from whether data is present.
  var resolvedOllamaStatus: OllamaStatus {
    ollamaStatus ?? (ollama != nil ? .on : .unavailable)
  }

  // Lines the `stale` card prints under its headline: when the numbers stopped
  // moving, and what is stopping them. Lives here so the widget and the panel
  // render the same words instead of drifting apart.
  var chatgptStaleDetail: [String] {
    var lines: [String] = []
    if let at = chatgptUpdatedAt {
      lines.append("Last read \(Self.lastReadFmt.string(from: at))")
    }
    if let chatgptIssue { lines.append(chatgptIssue) }
    return lines
  }

  // Absolute, not relative: for a meter that stopped, the moment it stopped is
  // more actionable than "4 days ago".
  private static let lastReadFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d HH:mm"
    return f
  }()
}

struct OllamaData: Codable {
  let sessionPct: Double
  let sessionResetsIn: String
  let weeklyPct: Double
  let weeklyResetsIn: String
  let sessionModels: [ModelUsage]
  let weeklyModels: [ModelUsage]
  enum CodingKeys: String, CodingKey {
    case sessionPct = "session_pct"
    case sessionResetsIn = "session_resets_in"
    case weeklyPct = "weekly_pct"
    case weeklyResetsIn = "weekly_resets_in"
    case sessionModels = "session_models"
    case weeklyModels = "weekly_models"
  }
}

struct ChatGPTData: Codable {
  // Optional: OpenAI can pull a meter off the analytics page (they dropped the
  // 5-hour limit in Jul 2026). nil means "not on the page", which the UI renders
  // by hiding that card rather than faking a 0% ring.
  let fiveHourPct: Double?
  let fiveHourReset: String?
  let weeklyPct: Double?
  let weeklyReset: String?
  enum CodingKeys: String, CodingKey {
    case fiveHourPct = "five_hour_pct"
    case fiveHourReset = "five_hour_reset"
    case weeklyPct = "weekly_pct"
    case weeklyReset = "weekly_reset"
  }
}

struct ModelUsage: Codable, Identifiable {
  let model: String
  let requests: Int
  let pct: Double
  var id: String { model }
}

let kChatGPTDone = Notification.Name("LLMUsageWidgetChatGPTDone")

