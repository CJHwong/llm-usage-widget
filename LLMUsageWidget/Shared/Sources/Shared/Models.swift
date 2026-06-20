import Foundation

// Derived ChatGPT display state, computed by the host and read by both the
// widget and the desktop panel. `on` = enabled and signed in (data present);
// `off` = disabled in the menu bar; `unavailable` = enabled but no data yet
// (not signed in / scrape failing).
enum ChatGPTStatus: String, Codable {
  case on
  case off
  case unavailable
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
  enum CodingKeys: String, CodingKey {
    case ollama, chatgpt
    case chatgptStatus = "chatgpt_status"
    case ollamaStatus = "ollama_status"
    case lastUpdated = "last_updated"
  }

  // Defaults a nil status (old payloads) from whether data is present.
  var resolvedOllamaStatus: OllamaStatus {
    ollamaStatus ?? (ollama != nil ? .on : .unavailable)
  }
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
  let fiveHourPct: Double
  let weeklyPct: Double
  let resets: [String]
  enum CodingKeys: String, CodingKey {
    case fiveHourPct = "five_hour_pct"
    case weeklyPct = "weekly_pct"
    case resets
  }
}

struct ModelUsage: Codable, Identifiable {
  let model: String
  let requests: Int
  let pct: Double
  var id: String { model }
}

let kChatGPTDone = Notification.Name("LLMUsageWidgetChatGPTDone")

