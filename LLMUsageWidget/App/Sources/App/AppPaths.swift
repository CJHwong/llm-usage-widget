import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "app-paths")

struct AppPaths {
  let dataDir: URL
  let legacyDataDir: URL

  init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    dataDir = home.appendingPathComponent(".llm-usage-widget", isDirectory: true)
    legacyDataDir = home.appendingPathComponent(".ollama-usage", isDirectory: true)
  }

  var usageFile: URL {
    dataDir.appendingPathComponent("usage.json")
  }

  var chatGPTToggleFile: URL {
    dataDir.appendingPathComponent("include-chatgpt")
  }

  func migrateLegacyDataIfNeeded() {
    let fm = FileManager.default
    let newExists = fm.fileExists(atPath: dataDir.path)
    let legacyExists = fm.fileExists(atPath: legacyDataDir.path)
    log.info("migrateLegacyData: dataDir=\(self.dataDir.path) exists=\(newExists), legacyDir=\(self.legacyDataDir.path) exists=\(legacyExists)")

    if !newExists, legacyExists {
      if (try? fm.moveItem(at: legacyDataDir, to: dataDir)) != nil {
        log.info("migrateLegacyData: moved legacy dir to data dir")
        return
      }
    }

    try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

    guard legacyExists else { return }
    guard let items = try? fm.contentsOfDirectory(
      at: legacyDataDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return }

    for item in items {
      let dst = dataDir.appendingPathComponent(item.lastPathComponent)
      guard !fm.fileExists(atPath: dst.path) else { continue }
      try? fm.moveItem(at: item, to: dst)
    }

    if let remaining = try? fm.contentsOfDirectory(
      at: legacyDataDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
      remaining.isEmpty
    {
      try? fm.removeItem(at: legacyDataDir)
      log.info("migrateLegacyData: cleaned up empty legacy dir")
    }
  }
}
