import Foundation

// Derived browser-provider display state, computed by the host and read by
// both the widget and the desktop panel. `on` = enabled and signed in (data
// present); `off` = disabled in the menu bar; `unavailable` = enabled but no
// data yet (not signed in / scrape failing); `stale` = we still hold numbers
// but the scrape stopped landing long enough ago that showing them as live
// would lie.
enum ProviderStatus: String, Codable {
  case on
  case off
  case unavailable
  case stale
}

// Derived Ollama display state. `on` = signed in and recently read;
// `unavailable` = the selected browser has no Ollama session; `stale` = we
// hold numbers but the last successful read is too old to call live. No master
// toggle, so no `off`.
enum OllamaStatus: String, Codable {
  case on
  case unavailable
  case stale
}

struct UsageData: Codable {
  var ollama: OllamaData?
  var chatgpt: ChatGPTData?
  var claude: ClaudeData?
  // Optional so older usage.json without the key still decodes; nil reads as off.
  var chatgptStatus: ProviderStatus?
  var claudeStatus: ProviderStatus?
  // Optional for the same reason; a nil value is resolved from the data below.
  var ollamaStatus: OllamaStatus?
  var lastUpdated: String = ""
  // When the last read of each provider actually landed, and the short reason
  // the current one is failing. `lastUpdated` can't answer either: it's
  // rewritten by every cycle, so a dead scrape would still look freshly
  // stamped. Dates use JSONEncoder's default strategy, matching the plain
  // decoders in Scraper.read and UsageDataStore.readUsage.
  var ollamaUpdatedAt: Date?
  var chatgptUpdatedAt: Date?
  var chatgptIssue: String?
  var claudeUpdatedAt: Date?
  var claudeIssue: String?
  var ollamaIssue: String?
  enum CodingKeys: String, CodingKey {
    case ollama, chatgpt, claude
    case chatgptStatus = "chatgpt_status"
    case claudeStatus = "claude_status"
    case ollamaStatus = "ollama_status"
    case lastUpdated = "last_updated"
    case ollamaUpdatedAt = "ollama_updated_at"
    case chatgptUpdatedAt = "chatgpt_updated_at"
    case chatgptIssue = "chatgpt_issue"
    case claudeUpdatedAt = "claude_updated_at"
    case claudeIssue = "claude_issue"
    case ollamaIssue = "ollama_issue"
  }

  // Shared cutoff for calling a number live. The host applies it when it writes
  // a status; the UI applies it again at render time, so a dead host loop
  // cannot keep a frozen number looking live.
  static let staleAfter: TimeInterval = 15 * 60

  private func agedStatus(
    _ stored: ProviderStatus?, hasData: Bool, updatedAt: Date?
  ) -> ProviderStatus {
    let base = stored ?? (hasData ? .on : .off)
    guard base != .off, base != .unavailable else { return base }
    guard let updatedAt else { return .stale }
    return Date().timeIntervalSince(updatedAt) > Self.staleAfter ? .stale : .on
  }

  var chatGPTDisplayStatus: ProviderStatus {
    agedStatus(chatgptStatus, hasData: chatgpt != nil, updatedAt: chatgptUpdatedAt)
  }

  var claudeDisplayStatus: ProviderStatus {
    agedStatus(claudeStatus, hasData: claude != nil, updatedAt: claudeUpdatedAt)
  }

  var ollamaDisplayStatus: OllamaStatus {
    guard ollama != nil else { return .unavailable }
    guard let updatedAt = ollamaUpdatedAt else { return .stale }
    return Date().timeIntervalSince(updatedAt) > Self.staleAfter ? .stale : .on
  }

  // The newest successful read among the providers this surface shows. The
  // header prints this instead of the cycle time, which is rewritten even when
  // every fetch failed.
  func headerUpdatedText(includeBrowserProviders: Bool = true) -> String? {
    let stamps =
      includeBrowserProviders
      ? [ollamaUpdatedAt, chatgptUpdatedAt, claudeUpdatedAt]
      : [ollamaUpdatedAt]
    guard let at = stamps.compactMap({ $0 }).max() else { return nil }
    return Self.headerTimeFmt.string(from: at)
  }

  // Enabled providers whose last fetch failed or whose numbers aged out. The
  // card carries the detail; this line keeps the header honest while the gauge
  // still looks fresh. A signed-out provider counts: the fetch failed. The
  // medium widget shows Ollama only, so it can exclude the browser providers.
  func providerFailureNote(includeBrowserProviders: Bool = true) -> String? {
    var names: [String] = []
    if ollamaDisplayStatus != .on || ollamaIssue != nil {
      names.append("Ollama")
    }
    if includeBrowserProviders {
      if chatGPTDisplayStatus != .off,
        chatGPTDisplayStatus != .on || chatgptIssue != nil
      {
        names.append("ChatGPT")
      }
      if claudeDisplayStatus != .off,
        claudeDisplayStatus != .on || claudeIssue != nil
      {
        names.append("Claude")
      }
    }
    guard !names.isEmpty else { return nil }
    return names.joined(separator: ", ") + " not updating"
  }

  // Lines a `stale` card prints under its headline: when the numbers stopped
  // moving, and what is stopping them. Lives here so the widget and the panel
  // render the same words instead of drifting apart.
  var chatgptStaleDetail: [String] {
    Self.staleDetail(updatedAt: chatgptUpdatedAt, issue: chatgptIssue)
  }

  var claudeStaleDetail: [String] {
    Self.staleDetail(updatedAt: claudeUpdatedAt, issue: claudeIssue)
  }

  var ollamaStaleDetail: [String] {
    Self.staleDetail(updatedAt: ollamaUpdatedAt, issue: ollamaIssue)
  }

  private static func staleDetail(updatedAt: Date?, issue: String?) -> [String] {
    var lines: [String] = []
    if let at = updatedAt {
      lines.append("Last read \(lastReadFmt.string(from: at))")
    }
    if let issue { lines.append(issue) }
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

  // The compact clock the header shows. Same timezone as the old cycle stamp.
  private static let headerTimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
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

struct ClaudeData: Codable {
  // The plan's weekly (7-day) meter. Claude has no 5-hour meter on every plan,
  // and the widget only shows the 7-day share, so that is all we keep.
  let weeklyPct: Double
  let weeklyReset: String
  enum CodingKeys: String, CodingKey {
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

let kBrowserScrapeDone = Notification.Name("LLMUsageWidgetBrowserScrapeDone")

