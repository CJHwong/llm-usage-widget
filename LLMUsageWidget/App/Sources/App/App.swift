import AppKit
import SwiftUI
import WidgetKit
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "app")

// UserDefaults keys for the two menu-bar toggles. The host owns both; the
// sandboxed widget never reads them (it reads the derived chatgptStatus the
// scraper writes into usage.json).
let chatGPTEnabledKey = "chatGPTEnabled"
let showDesktopPanelKey = "showDesktopPanel"
// Which browser to read cookies from. "Automatic" means the first detected
// browser in registry order; a specific name pins the source to that browser.
let preferredBrowserKey = "preferredBrowser"
let automaticBrowserValue = "Automatic"

// Menu-bar host: scrapes Ollama + ChatGPT usage every 5 min, feeds the widget
// via the App Group container, and (optionally) shows the floating desktop
// panel. The menu bar controls both the panel and the ChatGPT master switch.
// @MainActor since every callback here runs on the main thread; it lets the
// load() Task inherit the main actor and update panelModel without hopping.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let scraper = Scraper()
  let panelModel = PanelModel()
  private var statusItem: NSStatusItem?
  private var panelWindow: NSWindow?
  private var lockFileDescriptor: Int32 = -1
  private var timer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    guard acquireSingleInstanceLock() else {
      log.notice("Another instance already holds the lock; terminating this one")
      NSApp.terminate(nil)
      return
    }
    UserDefaults.standard.register(defaults: [
      showDesktopPanelKey: true, chatGPTEnabledKey: false,
      preferredBrowserKey: automaticBrowserValue,
    ])
    log.info("App did finish launching")
    // Reap orphaned Playwright sessions left by a previous crash/quit. Safe here
    // because we hold the single-instance lock, so no sibling scrape is live.
    DispatchQueue.global().async { [scraper] in scraper.reapStaleSessions() }

    buildMenu()
    NotificationCenter.default.addObserver(
      self, selector: #selector(chatGPTDone), name: kChatGPTDone, object: nil)

    if UserDefaults.standard.bool(forKey: showDesktopPanelKey) { showPanel() }
    load()
    // target/selector timer avoids capturing non-Sendable self in a @Sendable
    // closure (Swift 6 strict concurrency).
    let t = Timer(timeInterval: 300, target: self, selector: #selector(loadTick), userInfo: nil, repeats: true)
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func buildMenu() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem?.button {
      let img = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "Usage")
      img?.isTemplate = true
      button.image = img
    }
    let menu = NSMenu()
    let panelItem = NSMenuItem(
      title: "Show Desktop Panel", action: #selector(toggleDesktopPanel(_:)), keyEquivalent: "")
    panelItem.target = self
    panelItem.state = UserDefaults.standard.bool(forKey: showDesktopPanelKey) ? .on : .off
    menu.addItem(panelItem)

    let chatGPTItem = NSMenuItem(
      title: "Enable ChatGPT", action: #selector(toggleChatGPT(_:)), keyEquivalent: "")
    chatGPTItem.target = self
    chatGPTItem.state = UserDefaults.standard.bool(forKey: chatGPTEnabledKey) ? .on : .off
    menu.addItem(chatGPTItem)

    let browserItem = NSMenuItem(title: "Browser", action: nil, keyEquivalent: "")
    browserItem.submenu = buildBrowserMenu()
    menu.addItem(browserItem)

    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem?.menu = menu
  }

  private func buildBrowserMenu() -> NSMenu {
    let menu = NSMenu()
    let current = UserDefaults.standard.string(forKey: preferredBrowserKey) ?? automaticBrowserValue
    for name in [automaticBrowserValue] + BrowserRegistry.availableBrowserNames() {
      let item = NSMenuItem(title: name, action: #selector(selectBrowser(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = name
      item.state = current == name ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  @objc private func selectBrowser(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? String else { return }
    UserDefaults.standard.set(value, forKey: preferredBrowserKey)
    for item in sender.menu?.items ?? [] {
      item.state = (item.representedObject as? String) == value ? .on : .off
    }
    load()  // re-scrape from the newly selected browser
  }

  @objc private func toggleDesktopPanel(_ sender: NSMenuItem) {
    let enabled = !UserDefaults.standard.bool(forKey: showDesktopPanelKey)
    UserDefaults.standard.set(enabled, forKey: showDesktopPanelKey)
    sender.state = enabled ? .on : .off
    if enabled { showPanel() } else { panelWindow?.orderOut(nil) }
  }

  @objc private func toggleChatGPT(_ sender: NSMenuItem) {
    let enabled = !UserDefaults.standard.bool(forKey: chatGPTEnabledKey)
    UserDefaults.standard.set(enabled, forKey: chatGPTEnabledKey)
    sender.state = enabled ? .on : .off
    // Reflect the new state immediately (off hides ChatGPT; on shows "Sign in"
    // until a scrape lands), then re-scrape to start/stop the ChatGPT fetch.
    scraper.refreshChatGPTStatus()
    if let d = scraper.read() { panelModel.usage = d }
    WidgetCenter.shared.reloadAllTimelines()
    load()
  }

  // The floating desktop panel: a clear, borderless NSWindow pinned just above
  // the desktop on every Space, hosting the SwiftUI DesktopPanel. Transparent
  // over the wallpaper, which the widget cannot be.
  private func showPanel() {
    if panelWindow == nil {
      let hosting = NSHostingController(rootView: DesktopPanel(model: panelModel))
      let w = NSWindow(contentViewController: hosting)
      w.styleMask = [.titled, .fullSizeContentView]
      w.isOpaque = false
      w.backgroundColor = .clear
      w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
      w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
      w.isExcludedFromWindowsMenu = true
      w.hidesOnDeactivate = false
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      if #available(macOS 14.0, *) { w.titlebarSeparatorStyle = .none }
      w.isMovableByWindowBackground = true
      w.standardWindowButton(.closeButton)?.isHidden = true
      w.standardWindowButton(.miniaturizeButton)?.isHidden = true
      w.standardWindowButton(.zoomButton)?.isHidden = true
      w.styleMask.remove(.resizable)
      w.contentView?.wantsLayer = true
      w.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
      panelWindow = w
    }
    guard let w = panelWindow else { return }
    w.orderFrontRegardless()
    // Let SwiftUI size the window before pinning it to the top-right.
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 60_000_000)
      guard let w = self?.panelWindow, let screen = NSScreen.screens.first else { return }
      let f = w.frame
      w.setFrameOrigin(
        NSPoint(
          x: screen.visibleFrame.maxX - f.width - 20,
          y: screen.visibleFrame.maxY - f.height - 4))
    }
  }

  @objc private func loadTick() { load() }

  // Scraper posts kChatGPTDone once the background Playwright scrape finishes.
  @objc private func chatGPTDone() {
    log.info("kChatGPTDone: refreshing panel + widget")
    if let d = scraper.read() { panelModel.usage = d }
    panelModel.isRefreshing = false
    WidgetCenter.shared.reloadAllTimelines()
  }

  func load() {
    log.info("load() called")
    panelModel.isRefreshing = true
    panelModel.isLoading = true
    panelModel.errorMessage = nil
    if let cached = scraper.read() { panelModel.usage = cached }
    let preflightMessage = scraper.preflightMessage()

    // Created in a @MainActor context, so this Task runs on the main actor:
    // scrape()'s blocking work happens off-main (it's nonisolated async), then
    // control returns here on main to update panelModel and the widget.
    Task { [self] in
      if scraper.read() != nil { WidgetCenter.shared.reloadAllTimelines() }
      let fresh = await scraper.scrape()
      if let fresh {
        panelModel.usage = fresh
        WidgetCenter.shared.reloadAllTimelines()
      } else if scraper.read() == nil {
        panelModel.errorMessage = scraper.latestIssueMessage() ?? preflightMessage ?? "No data."
        log.warning("load(): scrape failed, no cached data")
      } else {
        log.notice("load(): scrape returned nil but cached data exists, keeping stale")
      }
      panelModel.isLoading = false
      // The ChatGPT background scrape clears isRefreshing via kChatGPTDone;
      // if ChatGPT is off there's no background pass, so clear it now.
      if !UserDefaults.standard.bool(forKey: chatGPTEnabledKey) { panelModel.isRefreshing = false }
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

  // No SwiftUI scene: the host is a menu-bar accessory. The desktop panel is an
  // AppKit NSWindow managed by AppDelegate so the menu can toggle it.
  var body: some Scene {
    Settings { EmptyView() }
  }
}
