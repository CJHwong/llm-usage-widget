import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "app-paths")

// Single store for host + widget: the App Group container. The host is
// unsandboxed and the widget is sandboxed, but both can reach the group
// container, so there's one copy of usage.json and the ChatGPT toggle and
// nothing has to be mirrored across a home directory.
struct AppPaths {
  let dataDir: URL

  init() {
    if let container = UsageDataStore.containerURL {
      dataDir = container
    } else {
      // The container always resolves when the App Group entitlement is
      // present; fall back to home so a misconfigured build still runs.
      log.warning("No App Group container; falling back to ~/.llm-usage-widget")
      dataDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".llm-usage-widget", isDirectory: true)
    }
  }

  var usageFile: URL {
    dataDir.appendingPathComponent("usage.json")
  }
}
