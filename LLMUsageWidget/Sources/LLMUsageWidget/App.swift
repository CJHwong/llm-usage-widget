import AppKit
import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
  let scraper = Scraper()
  var statusItem: NSStatusItem?
  private var lockFileDescriptor: Int32 = -1

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

@main struct LLMUsageWidgetApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @State private var usage: UsageData?
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var isRefreshing = false
  private var scraper: Scraper { appDelegate.scraper }

  var body: some Scene {
    WindowGroup {
      ContentView(usage: $usage, isLoading: $isLoading, errorMessage: $errorMessage, isRefreshing: $isRefreshing, chatGPTTogglePath: scraper.chatGPTTogglePath)
        .frame(width: 300)
        .onAppear { log.info("ContentView appeared"); load() }
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
          log.info("Timer fired (300s), triggering load()")
          load()
        }
        .onReceive(NotificationCenter.default.publisher(for: kChatGPTDone)) { _ in
          log.info("Received kChatGPTDone notification, reading cached data")
          if let d = scraper.read() {
            log.info("kChatGPTDone: updated usage data read from cache")
            usage = d
          } else {
            log.warning("kChatGPTDone: no data found in cache")
          }
          isRefreshing = false
        }
    }
    .windowStyle(.plain).windowResizability(.contentSize)
  }

  func load() {
    log.info("load() called")
    isRefreshing = true
    isLoading = true
    errorMessage = nil
    let chatGPTOn = FileManager.default.fileExists(
      atPath: scraper.chatGPTTogglePath)
    Task {
      // Blocking I/O runs off the main actor
      let preflightMessage = scraper.preflightMessage()
      if let cached = scraper.read() {
        log.info("load(): loaded cached data")
        await MainActor.run { usage = cached }
      }
      log.info("load(): starting async scrape")
      if let fresh = await scraper.scrape() {
        scraper.write(fresh)
        log.info("load(): scrape succeeded, writing & updating UI")
        await MainActor.run { usage = fresh }
      } else if usage == nil {
        let msg = scraper.latestIssueMessage() ?? preflightMessage ?? "No data."
        log.warning("load(): scrape failed, no cached data. message=\(msg)")
        await MainActor.run { errorMessage = msg }
      } else {
        log.notice("load(): scrape returned nil but cached data exists, keeping stale")
      }
      await MainActor.run {
        isLoading = false
        if !chatGPTOn { isRefreshing = false }
      }
    }
  }
}
