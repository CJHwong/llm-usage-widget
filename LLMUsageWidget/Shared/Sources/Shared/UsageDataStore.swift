import Foundation
import OSLog

// Bridge between the unsandboxed host app and the sandboxed widget extension.
// Both compile this file. The host writes; the widget reads.
//
// The host keeps writing ~/.llm-usage-widget/usage.json (source of truth, unchanged
// from the original app) and mirrors a copy into the shared App Group container so
// the sandboxed widget can reach it. The ChatGPT enable flag is mirrored too,
// since the widget cannot read the include-chatgpt toggle file outside its sandbox.

private let log = Logger(subsystem: "com.llmwidget", category: "shared-store")

enum UsageDataStore {
  static let appGroupID = "3GXP3XQ69M.com.hoss.ollama-gauge"

  static var containerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
  }

  static var sharedUsageFile: URL? {
    containerURL?.appendingPathComponent("usage.json")
  }

  // Presence of this file in the group container = ChatGPT scraping enabled.
  static var sharedChatGPTFlagFile: URL? {
    containerURL?.appendingPathComponent("chatgpt_enabled")
  }

  static func writeUsage(_ data: UsageData) {
    guard let url = sharedUsageFile else {
      log.warning("writeUsage: no App Group container for \(appGroupID); is the entitlement present?")
      return
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let json = try? enc.encode(data) else {
      log.error("writeUsage: encode failed")
      return
    }
    try? json.write(to: url, options: .atomic)
  }

  static func readUsage() -> UsageData? {
    guard let url = sharedUsageFile, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(UsageData.self, from: data)
  }

  static func setChatGPTEnabled(_ enabled: Bool) {
    guard let url = sharedChatGPTFlagFile else { return }
    if enabled {
      try? Data("1".utf8).write(to: url, options: .atomic)
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }

  static var chatGPTEnabled: Bool {
    guard let url = sharedChatGPTFlagFile else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }
}