import AppKit
import SwiftUI
import WidgetKit
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "app")

// Menu-bar accessory app: scrapes Ollama + ChatGPT Codex usage every 5 min and
// pushes it to the widget via the shared App Group container. No window; the
// display surface is the WidgetKit extension in OllamaGaugeWidget.appex.
final class AppDelegate: NSObject, NSApplicationDelegate {
  let scraper = Scraper()
  private var statusItem: NSStatusItem?
  private var lockFileDescriptor: Int32 = -1
  private var timer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    guard acquireSingleInstanceLock() else {
      log.notice("Another instance already holds the lock; terminating this one")
      NSApp.terminate(nil)
      return
    }
    log.info("App did finish launching")
    // Reap orphaned Playwright sessions left by a previous crash/quit. Safe here
    // because we hold the single-instance lock, so no sibling scrape is live.
    DispatchQueue.global().async { [scraper] in scraper.reapStaleSessions() }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem?.button {
      let img = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "Usage")
      img?.isTemplate = true
      button.image = img
    }
    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem?.menu = menu

    NotificationCenter.default.addObserver(
      self, selector: #selector(chatGPTDone), name: kChatGPTDone, object: nil)

    load()
    // target/selector timer avoids capturing non-Sendable self in a @Sendable
    // closure (Swift 6 strict concurrency).
    let t = Timer(timeInterval: 300, target: self, selector: #selector(loadTick), userInfo: nil, repeats: true)
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  @objc private func loadTick() { load() }

  // Scraper posts kChatGPTDone from its background thread once the Playwright
  // scrape finishes. The scrape already wrote the container; just refresh.
  @objc private func chatGPTDone() {
    log.info("kChatGPTDone: reloading widget")
    if scraper.read() != nil {
      WidgetCenter.shared.reloadAllTimelines()
    }
  }

  func load() {
    log.info("load() called")
    let scraper = self.scraper  // local Sendable capture; keeps self out of the Task
    let preflightMessage = scraper.preflightMessage()

    Task {
      if scraper.read() != nil {
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
      }
      if await scraper.scrape() != nil {
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
      } else if scraper.read() == nil {
        let msg = scraper.latestIssueMessage() ?? preflightMessage ?? "No data."
        log.warning("load(): scrape failed, no cached data. message=\(msg)")
      } else {
        log.notice("load(): scrape returned nil but cached data exists, keeping stale")
      }
    }
  }

  // flock on a lockfile in the data dir. The lock is held for the process
  // lifetime via the open fd and released automatically by the OS on exit or
  // crash, so a stale lock can never wedge a future launch. Returns false only
  // when another live instance already holds it.
  private func acquireSingleInstanceLock() -> Bool {
    let dataDir = AppPaths().dataDir
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let lockPath = dataDir.appendingPathComponent("instance.lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
      log.warning("acquireSingleInstanceLock: could not open \(lockPath), proceeding anyway")
      return true  // don't strand the user over a lockfile we can't create
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      return false
    }
    lockFileDescriptor = fd  // keep open to hold the lock
    return true
  }
}

@main struct OllamaGaugeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  // No window: the app is a menu-bar accessory that only feeds the widget.
  var body: some Scene {
    Settings { EmptyView() }
  }
}