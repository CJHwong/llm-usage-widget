import Foundation

// Single store shared by the unsandboxed host and the sandboxed widget. Both
// compile this file and both reach the same App Group container, so usage.json
// lives there once, with no home-directory copy to keep in sync. The host
// writes usage.json (via the scraper); the widget reads it.

// Widget kinds, shared so the host can ask WidgetCenter which widgets are
// installed and the widget extension can declare matching StaticConfigurations.
enum WidgetKinds {
  static let ollama = "OllamaWidget"
  static let ollamaChatGPT = "OllamaChatGPTWidget"
}

enum UsageDataStore {
  static let appGroupID = "3GXP3XQ69M.com.hoss.ollama-gauge"

  static var containerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
  }

  static var sharedUsageFile: URL? {
    containerURL?.appendingPathComponent("usage.json")
  }

  static func readUsage() -> UsageData? {
    guard let url = sharedUsageFile, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(UsageData.self, from: data)
  }
}
