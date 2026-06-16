import AppKit
import SwiftUI
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    log.info("App did finish launching")
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
}

@main struct LLMUsageWidgetApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @State private var usage: UsageData?
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var isRefreshing = false
  let scraper = Scraper()

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
