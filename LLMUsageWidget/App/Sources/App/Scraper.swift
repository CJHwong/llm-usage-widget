import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "scraper")

// What a scrape cycle hands back to load(): the fresh data plus whether this
// cycle started a background ChatGPT scrape. That background pass is what posts
// kChatGPTDone, which clears the panel's isRefreshing; when it wasn't started
// (ChatGPT off, nothing to scrape, or one already running), load() must clear
// the flag itself or the panel spins forever.
struct ScrapeOutcome {
  let usage: UsageData?
  let spawnedChatGPTScrape: Bool
}

final class Scraper: @unchecked Sendable {
  private let paths: AppPaths
  private let dataFile: URL
  private let playwrightCLI: String = {
    let silicon = "/opt/homebrew/bin/playwright-cli"
    if FileManager.default.isExecutableFile(atPath: silicon) { return silicon }
    let intel = "/usr/local/bin/playwright-cli"
    if FileManager.default.isExecutableFile(atPath: intel) { return intel }
    return silicon  // fallback, preflight will catch it
  }()
  private let _lock = NSLock()
  private var _lastIssueMessage: String?
  private var _isScrapingChatGPT = false

  // Namespaces every Playwright session this app opens, so the startup reaper
  // can recognize its own leftovers without touching unrelated sessions the
  // user may have opened by hand.
  static let sessionPrefix = "llmwidget-"

  // Compiled once — avoids per-cycle regex and DateFormatter allocation
  private static let regexOllamaTrack = try! NSRegularExpression(
    pattern: #"data-usage-track[^>]*aria-label="([^"]*)""#, options: [.dotMatchesLineSeparators])
  private static let regexOllamaSegmentButtons = try! NSRegularExpression(
    pattern: #"<button[^>]*data-usage-segment[^>]*>"#, options: [.dotMatchesLineSeparators])
  private static let regexOllamaModel = try! NSRegularExpression(pattern: #"data-model="([^"]*)""#)
  private static let regexOllamaRequests = try! NSRegularExpression(pattern: #"data-requests="([^"]*)""#)
  private static let regexOllamaWidth = try! NSRegularExpression(pattern: #"width:\s*([\d.]+)%"#)
  private static let regexOllamaPct = try! NSRegularExpression(pattern: #"([\d.]+)%"#)
  private static let regexOllamaResets = try! NSRegularExpression(pattern: "Resets[^<]*")

  private static let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()

  init() {
    paths = AppPaths()
    dataFile = paths.usageFile
  }

  // The ChatGPT master switch, set from the menu bar (host UserDefaults). The
  // sandboxed widget never reads this; it reads the derived chatgptStatus the
  // host writes into usage.json.
  private var chatGPTEnabled: Bool { UserDefaults.standard.bool(forKey: chatGPTEnabledKey) }

  // How long a failing ChatGPT scrape may keep its last numbers before the UI
  // has to call them stale. Three missed 300s cycles: rides out a hiccup, but
  // can never let a number sit there for days looking live.
  private static let staleAfter: TimeInterval = 15 * 60

  private func chatGPTStatus(
    enabled: Bool, data: ChatGPTData?, updatedAt: Date?, failing: Bool
  ) -> ChatGPTStatus {
    if !enabled { return .off }
    guard data != nil else { return .unavailable }
    guard failing else { return .on }
    // Numbers of unknown age plus a live failure: no basis to call them fresh.
    guard let updatedAt else { return .stale }
    return Date().timeIntervalSince(updatedAt) > Self.staleAfter ? .stale : .on
  }

  // Rewrite usage.json's chatgptStatus from the current toggle + cached data,
  // without scraping, so a menu toggle reflects in the widget/panel immediately.
  func refreshChatGPTStatus() {
    guard var d = read() else { return }
    d.chatgptStatus = chatGPTStatus(
      enabled: chatGPTEnabled, data: d.chatgpt, updatedAt: d.chatgptUpdatedAt,
      failing: d.chatgptIssue != nil)
    write(d)
  }

  func preflightMessage() -> String? {
    let issues = preflightIssues()
    return issues.isEmpty ? nil : issues.joined(separator: "\n")
  }

  func latestIssueMessage() -> String? {
    _lock.withLock { _lastIssueMessage }
  }

  func scrape() async -> ScrapeOutcome {
    log.info("scrape() started")
    let wantChatGPT = chatGPTEnabled
    let preflight = preflightMessage()
    _lock.withLock { _lastIssueMessage = preflight }
    guard let browser = BrowserRegistry.firstSupportedProfile() else {
      log.warning("No supported browser profile found")
      return ScrapeOutcome(usage: nil, spawnedChatGPTScrape: false)
    }
    log.info("Found browser profile: \(browser.profile.browserName) at \(browser.profile.profilePath)")
    let fmt = Self.timeFmt

    let ollamaCookies = browser.adapter.cookies(for: browser.profile, domains: ["ollama", "workos"])
    var merged = read() ?? UsageData()
    if let ch = cookieHeader(from: ollamaCookies),
      let ollama = await scrapeOllama(cookies: ch)
    {
      log.info("Ollama scrape succeeded")
      merged.ollama = ollama
      merged.ollamaStatus = .on
      // Back to the preflight baseline, not nil: Ollama working says nothing
      // about whether ChatGPT's prerequisites are in place, and clearing the
      // preflight text here is what hid a missing Playwright browser for days.
      _lock.withLock { _lastIssueMessage = preflight }
    } else if ollamaCookies.isEmpty {
      // Not signed in to Ollama in the selected browser: drop any stale numbers
      // (e.g. left over from another browser) so the panel shows the truth.
      log.warning("Ollama: no cookies in \(browser.profile.browserName)")
      merged.ollama = nil
      merged.ollamaStatus = .unavailable
      _lock.withLock {
        _lastIssueMessage = "Not signed in to Ollama in \(browser.profile.browserName)."
      }
    } else {
      // Cookies exist but the fetch/parse failed (transient): keep the last good data.
      log.warning("Ollama scrape failed despite cookies present")
      merged.ollamaStatus = merged.ollama != nil ? .on : .unavailable
      _lock.withLock {
        _lastIssueMessage =
          "Could not read Ollama usage from \(browser.profile.browserName). Check that you are signed in and the profile still has the required cookies."
      }
    }
    merged.lastUpdated = fmt.string(from: Date())
    merged.chatgptStatus = chatGPTStatus(
      enabled: wantChatGPT, data: merged.chatgpt, updatedAt: merged.chatgptUpdatedAt,
      failing: merged.chatgptIssue != nil)
    write(merged)

    var spawnedChatGPTScrape = false
    if wantChatGPT {
      let shouldScrape = _lock.withLock { () -> Bool in
        if _isScrapingChatGPT { return false }
        _isScrapingChatGPT = true
        return true
      }
      if shouldScrape {
        spawnedChatGPTScrape = true
        log.info("ChatGPT enabled, starting ChatGPT scrape on background thread")
        DispatchQueue.global().async { [self, browser] in
          defer { self._lock.withLock { self._isScrapingChatGPT = false } }
          log.info("BG: scrapeChatGPT() called")
          var d = self.read() ?? UsageData()
          switch self.scrapeChatGPT(using: browser) {
          case .success(let c):
            d.chatgpt = c
            d.chatgptUpdatedAt = Date()
            d.chatgptIssue = nil
            d.lastUpdated = fmt.string(from: Date())
            d.chatgptStatus = .on
            log.info("BG: ChatGPT data written, posting notification")
          case .notSignedIn:
            // Definitive logout: drop stale numbers and surface the sign-in
            // prompt instead of freezing on the last good data.
            log.warning("BG: ChatGPT not signed in")
            d.chatgpt = nil
            d.chatgptUpdatedAt = nil
            d.chatgptIssue = nil
            d.chatgptStatus = .unavailable
          case .transientFailure(let reason):
            // Fetch/parse hiccup: keep the last good data, but record why the
            // refresh failed and let it age into `stale` so the UI stops
            // presenting a frozen number as the current one.
            d.chatgptIssue = reason
            d.chatgptStatus = self.chatGPTStatus(
              enabled: true, data: d.chatgpt, updatedAt: d.chatgptUpdatedAt, failing: true)
            log.warning(
              "BG: ChatGPT scrape failed: \(reason), status=\(d.chatgptStatus?.rawValue ?? "-")")
          }
          self.write(d)
          DispatchQueue.main.async {
            NotificationCenter.default.post(name: kChatGPTDone, object: nil)
          }
        }
      } else {
        log.info("ChatGPT scrape already in progress, skipping")
      }
    } else {
      log.notice("ChatGPT disabled; skipping ChatGPT scrape")
    }
    log.info("scrape() returning")
    return ScrapeOutcome(usage: read(), spawnedChatGPTScrape: spawnedChatGPTScrape)
  }

  private func scrapeOllama(cookies: String) async -> OllamaData? {
    guard let html = await httpGet("https://ollama.com/settings", cookie: cookies),
      html.contains("data-usage-meter")
    else { return nil }
    let ns = html as NSString
    let full = NSRange(location: 0, length: ns.length)

    // One regex serves both: range(1)=label, range(0)=position
    let trackMatches = Self.regexOllamaTrack.matches(in: html, range: full)
    let labels = trackMatches.map { ns.substring(with: $0.range(at: 1)) }
    let trackPositions = trackMatches.map { $0.range.location }

    let buttonRanges = Self.regexOllamaSegmentButtons.matches(in: html, range: full).map { $0.range }

    func parseSegments(_ ranges: [NSRange]) -> [ModelUsage] {
      var result: [ModelUsage] = []
      for r in ranges {
        let t = ns.substring(with: r)
        let tn = t as NSString
        let tr = NSRange(location: 0, length: tn.length)
        guard let model = Self.regexOllamaModel.firstMatch(in: t, range: tr).map({ tn.substring(with: $0.range(at: 1)) }),
              !model.isEmpty,
              let rc = Int(Self.regexOllamaRequests.firstMatch(in: t, range: tr).map({ tn.substring(with: $0.range(at: 1)) }) ?? "0"),
              rc > 0,
              let pc = Double(Self.regexOllamaWidth.firstMatch(in: t, range: tr).map({ tn.substring(with: $0.range(at: 1)) }) ?? "0")
        else { continue }
        result.append(ModelUsage(model: model, requests: rc, pct: pc))
      }
      return result
    }

    // Buttons before the second track belong to session; after the second track belong to weekly
    let secondTrackPos = trackPositions.count >= 2 ? trackPositions[1] : trackPositions.first ?? Int.max
    let sessionButtons = buttonRanges.filter { $0.location < secondTrackPos }
    let weeklyButtons = buttonRanges.filter { $0.location >= secondTrackPos }

    let sessionModels = parseSegments(sessionButtons)
    let weeklyModels = parseSegments(weeklyButtons)

    func pct(_ l: String) -> Double {
      Self.regexOllamaPct.firstMatch(
        in: l, range: NSRange(l.startIndex..., in: l))
        .flatMap { Range($0.range(at: 1), in: l).flatMap { Double(l[$0]) } } ?? 0
    }
    let resets = Self.regexOllamaResets.matches(in: html, range: full)
      .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }
    return OllamaData(
      sessionPct: labels.count > 0 ? pct(labels[0]) : 0,
      sessionResetsIn: resets.count > 0 ? resets[0] : "",
      weeklyPct: labels.count > 1 ? pct(labels[1]) : 0,
      weeklyResetsIn: resets.count > 1 ? resets[1] : "",
      sessionModels: sessionModels, weeklyModels: weeklyModels
    )
  }

  // Outcome of a ChatGPT scrape. `notSignedIn` is a definitive auth failure that
  // should clear stale data; `transientFailure` is a hiccup worth keeping the
  // last good data for.
  private enum ChatGPTScrapeOutcome {
    case success(ChatGPTData)
    case notSignedIn
    // Carries a short reason the widget prints verbatim, so keep it to a few
    // words. The verbose remediation text stays in _lastIssueMessage.
    case transientFailure(String)
  }

  // OpenAI rewrote the ChatGPT settings UI in Oct 2026 and the analytics page the
  // old scrape read is gone (the URL now redirects, and a cold automated visit
  // meets a Cloudflare challenge). The page still fetches its own numbers from
  // /backend-api/wham/usage, so we load a page and read that response instead of
  // matching rendered text. Nothing here depends on page copy, so the next
  // redesign does not break it.
  private static let usageCaptureScript = """
    async (page) => {
      let captured = null;
      page.on('response', async (res) => {
        if (!res.url().includes('/backend-api/wham/usage')) return;
        try { captured = await res.json(); } catch (e) { /* not JSON */ }
      });
      try {
        await page.goto('https://chatgpt.com/settings/general-settings', {
          waitUntil: 'domcontentloaded', timeout: 25000,
        });
      } catch (e) { /* a slow load can still have fired the request */ }
      for (let i = 0; i < 20 && captured === null; i++) await page.waitForTimeout(500);
      return JSON.stringify(captured);
    }
    """

  // The slice of /backend-api/wham/usage we read. Every field is optional and
  // unknown keys are ignored, so an added or removed field cannot fail the decode.
  private struct UsageResponse: Decodable {
    let rateLimit: RateLimit?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
  }

  private struct RateLimit: Decodable {
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?
    enum CodingKeys: String, CodingKey {
      case primaryWindow = "primary_window"
      case secondaryWindow = "secondary_window"
    }
  }

  private struct UsageWindow: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAt: Double?
    enum CodingKeys: String, CodingKey {
      case usedPercent = "used_percent"
      case limitWindowSeconds = "limit_window_seconds"
      case resetAt = "reset_at"
    }
  }

  // Why a Playwright launch most likely failed, in UI-sized words. Checks the
  // two prerequisites we can verify locally before falling back to the daemon's
  // own stderr, because "Playwright would not launch" is useless on its own and
  // the real error names the missing browser build and its fix.
  private func playwrightLaunchIssue(for browserName: String, stderr: String) -> String {
    if !FileManager.default.isExecutableFile(atPath: playwrightCLI) {
      return "playwright-cli not installed"
    }
    if browserName == "firefox", !isPlaywrightFirefoxInstalled() {
      return "Playwright Firefox not installed"
    }
    // The daemon prints the cause last, e.g. `Error: Browser "firefox" is not
    // installed; expected executable at ... Run \`playwright-cli install-browser
    // firefox\` to install`.
    if let line = stderr.components(separatedBy: "\n").last(where: { $0.hasPrefix("Error: ") }) {
      return String(line.dropFirst("Error: ".count))
    }
    return "Playwright would not launch"
  }

  private func scrapeChatGPT(using browser: BrowserSelection) -> ChatGPTScrapeOutcome {
    log.info("scrapeChatGPT() START")
    log.info("scrapeChatGPT: using \(browser.profile.browserName) profile at \(browser.profile.profilePath)")

    // Inject cookies through a Playwright storage_state instead of copying the
    // browser profile: Chromium can't decrypt Chrome's cookie DB (different Safe
    // Storage key), so we hand Playwright already-decrypted cookies. This works
    // uniformly for Chrome and Firefox.
    let cookies = browser.adapter.cookies(for: browser.profile, domains: ["chatgpt", "openai"])
    // The NextAuth session-token cookie is the auth signal. Logging out deletes
    // it while leaving cf_clearance/csrf behind, so checking it here is more
    // reliable than scraping the page — a logged-out hit just stalls on
    // Cloudflare's "Just a moment..." wall and never yields a login page.
    let signedIn = cookies.contains { $0.name.contains("session-token") }
    guard signedIn, let stateData = storageStateData(from: cookies) else {
      log.warning("scrapeChatGPT: no ChatGPT session-token cookie in \(browser.profile.browserName)")
      _lock.withLock {
        _lastIssueMessage =
          "No ChatGPT session found in \(browser.profile.browserName). Sign in to ChatGPT in that browser."
      }
      return .notSignedIn
    }

    let tmpDir = URL(fileURLWithPath: "/tmp/pwt-\(ProcessInfo.processInfo.globallyUniqueString)")
    let stateFile = tmpDir.appendingPathComponent("state.json")
    let sessionName = "\(Self.sessionPrefix)\(ProcessInfo.processInfo.globallyUniqueString)"
    log.info("scrapeChatGPT: tmpDir=\(tmpDir.path) session=\(sessionName)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    guard (try? stateData.write(to: stateFile)) != nil else {
      log.error("scrapeChatGPT: failed to write storage_state")
      try? FileManager.default.removeItem(at: tmpDir)
      return .transientFailure("Could not stage the ChatGPT session")
    }
    defer {
      log.info("scrapeChatGPT: cleanup - closing session")
      closePlaywrightSession(sessionName)
      try? FileManager.default.removeItem(at: tmpDir)
    }

    // open a blank context, load the cookies, then navigate authenticated.
    let openResult = runPlaywrightCommand(
      ["-s=\(sessionName)", "open", "--browser", browser.adapter.playwrightBrowserName, "about:blank"],
      timeout: 30)
    guard openResult.output != nil else {
      let issue = playwrightLaunchIssue(
        for: browser.adapter.playwrightBrowserName, stderr: openResult.stderr)
      log.error("scrapeChatGPT: open failed (\(issue))")
      _lock.withLock {
        _lastIssueMessage = preflightMessage() ?? "Could not launch Playwright for ChatGPT."
      }
      return .transientFailure(issue)
    }
    guard runPlaywrightCommand(["-s=\(sessionName)", "state-load", stateFile.path]).output != nil else {
      log.error("scrapeChatGPT: state-load failed")
      return .transientFailure("Could not load the ChatGPT session")
    }
    let scriptFile = tmpDir.appendingPathComponent("capture-usage.js")
    guard (try? Self.usageCaptureScript.write(to: scriptFile, atomically: true, encoding: .utf8)) != nil
    else {
      log.error("scrapeChatGPT: failed to write the capture script")
      return .transientFailure("Could not stage the usage capture")
    }

    // --raw drops playwright-cli's "### Result" wrapper, so stdout is exactly the
    // script's return value: a JSON string holding the captured payload.
    let capture = runPlaywrightCommand(
      ["-s=\(sessionName)", "--raw", "run-code", "--filename", scriptFile.path],
      timeout: 40)
    guard let output = capture.output else {
      log.error("scrapeChatGPT: run-code failed, stderr=\(capture.stderr)")
      return .transientFailure("Could not read the usage API")
    }

    // Signed out, or a page that never fired the call, yields the literal "null".
    // Both land here, and both are worth the same message.
    guard let json = try? JSONDecoder().decode(String.self, from: Data(output.utf8)),
      let response = try? JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8)),
      let parsed = chatGPTData(from: response)
    else {
      log.warning("scrapeChatGPT: capture held no usable usage window")
      _lock.withLock {
        _lastIssueMessage =
          "ChatGPT opened but reported no usage window. Check that you are signed in and still have Codex access."
      }
      return .transientFailure("No usage window reported")
    }
    log.info("scrapeChatGPT: parsed successfully - 5h=\(String(describing: parsed.fiveHourPct)) weekly=\(String(describing: parsed.weeklyPct)) resets=[\(parsed.fiveHourReset ?? "-"), \(parsed.weeklyReset ?? "-")]")
    return .success(parsed)
  }

  // The 5-hour window, in seconds. The API does not label its windows, so the
  // only way to tell them apart is their length.
  private static let fiveHourWindowSeconds: Double = 5 * 3600
  private static let dayInSeconds: Double = 24 * 3600

  // Maps the response's two windows onto the widget's two meters. Which slot a
  // window arrives in is not fixed: a team plan reports the weekly window as
  // `primary_window` with `secondary_window` null, the reverse of the older
  // Plus layout. Classify by duration, never by position.
  private func chatGPTData(from response: UsageResponse) -> ChatGPTData? {
    let windows = [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow]
      .compactMap { $0 }

    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    for window in windows {
      guard let seconds = window.limitWindowSeconds else { continue }
      // Within an hour of 5h counts as the 5-hour meter; anything a day or
      // longer is the weekly one. A window of an unknown length is ignored
      // rather than guessed into a slot.
      if abs(seconds - Self.fiveHourWindowSeconds) <= 3600 {
        fiveHour = window
      } else if seconds >= Self.dayInSeconds {
        weekly = window
      }
    }
    guard fiveHour != nil || weekly != nil else { return nil }

    return ChatGPTData(
      fiveHourPct: fiveHour?.usedPercent,
      fiveHourReset: fiveHour.flatMap { resetText(for: $0) },
      weeklyPct: weekly?.usedPercent,
      weeklyReset: weekly.flatMap { resetText(for: $0) })
  }

  // The API reports an absolute unix reset; the UI prints a relative interval.
  // `formatResetInterval` already rounds up, so a window that has just reset
  // reads as minutes rather than "0 hours".
  private func resetText(for window: UsageWindow) -> String? {
    guard let resetAt = window.resetAt else { return nil }
    let interval = Date(timeIntervalSince1970: resetAt).timeIntervalSinceNow
    guard interval > 0 else { return nil }
    return Self.formatResetInterval(interval)
  }

  private static func formatResetInterval(_ interval: TimeInterval) -> String {
    let minutes = Int(ceil(interval / 60))
    if minutes < 60 { return "Resets in \(minutes) minute\(minutes == 1 ? "" : "s")." }
    let hours = Int(ceil(interval / 3600))
    if hours >= 24 { return "Resets in \(hours / 24) day\(hours / 24 == 1 ? "" : "s")." }
    return "Resets in \(hours) hour\(hours == 1 ? "" : "s")."
  }

  private func httpGet(_ url: String, cookie: String) async -> String? {
    log.info("httpGet: fetching \(url)")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    proc.arguments = [
      "-sL", "--max-time", "15", "-H", "Cookie: \(cookie)",
      "-H",
      "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:135.0) Gecko/20100101 Firefox/135.0",
      url,
    ]
    let o = Pipe()
    proc.standardOutput = o
    proc.standardError = Pipe()
    guard (try? proc.run()) != nil else {
      log.error("httpGet: curl launch failed")
      return nil
    }
    proc.waitUntilExit()  // curl --max-time 15 provides the timeout
    guard proc.terminationStatus == 0 else {
      log.warning("httpGet: curl exit code \(proc.terminationStatus)")
      return nil
    }
    let result = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    if let result {
      log.info("httpGet: received \(result.count) bytes")
    } else {
      log.warning("httpGet: response not UTF-8")
    }
    return result
  }

  func write(_ d: UsageData) {
    log.info("write: writing usage data to \(self.dataFile.path)")
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let j = try? enc.encode(d) else {
      log.error("write: JSON encoding failed")
      return
    }
    let dir = dataFile.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? j.write(to: dataFile)
  }

  func read() -> UsageData? {
    guard let d = try? Data(contentsOf: dataFile) else {
      log.notice("read: no data file at \(self.dataFile.path)")
      return nil
    }
    let result = try? JSONDecoder().decode(UsageData.self, from: d)
    if result != nil {
      log.info("read: loaded cached data")
    } else {
      log.warning("read: JSON decode failed")
    }
    return result
  }

  private func preflightIssues() -> [String] {
    var issues: [String] = []

    let selection = BrowserRegistry.firstSupportedProfile()
    if selection == nil {
      issues.append("No supported Zen, Firefox, or Chrome profile with cookies was found.")
    }
    if !FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") {
      issues.append("Missing required system binary: /usr/bin/sqlite3.")
    }
    if !FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") {
      issues.append("Missing required system binary: /usr/bin/curl.")
    }
    if chatGPTEnabled {
      if !FileManager.default.isExecutableFile(atPath: playwrightCLI) {
        issues.append("ChatGPT is enabled but playwright-cli is not installed.")
      } else if selection?.adapter.playwrightBrowserName == "firefox", !isPlaywrightFirefoxInstalled()
      {
        // The Chrome channel uses the installed Google Chrome, so only the
        // Firefox path needs Playwright's bundled browser.
        issues.append(
          "ChatGPT is enabled but the Playwright Firefox browser is not installed. Run `playwright-cli install-browser firefox`."
        )
      }
    }

    return issues
  }

  // What a Playwright invocation returned: stdout (nil when the command failed)
  // plus stderr, which names the real cause when a launch fails (missing browser
  // build, daemon crash) and is worth surfacing instead of a generic guess.
  private struct PlaywrightResult {
    let output: String?
    let stderr: String
  }

  private func runPlaywrightCommand(_ arguments: [String], timeout: TimeInterval = 10) -> PlaywrightResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: playwrightCLI)
    proc.arguments = arguments

    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    let sem = DispatchSemaphore(value: 0)
    proc.terminationHandler = { _ in sem.signal() }
    guard (try? proc.run()) != nil else {
      log.error("runPlaywrightCommand: failed to launch playwright process")
      return PlaywrightResult(output: nil, stderr: "")
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
      proc.terminate()
      log.error("runPlaywrightCommand: timed out after 10s, args=\(arguments.joined(separator: " "))")
      return PlaywrightResult(output: nil, stderr: "")
    }
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if proc.terminationStatus != 0 {
      log.error("runPlaywrightCommand: exit code \(proc.terminationStatus), args=\(arguments.joined(separator: " "))")
      log.error("runPlaywrightCommand: stderr=\(stderr)")
      return PlaywrightResult(output: nil, stderr: stderr)
    }
    if !stderr.isEmpty {
      log.info("runPlaywrightCommand: stderr=\(stderr)")
    }

    return PlaywrightResult(
      output: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
      stderr: stderr)
  }

  private func closePlaywrightSession(_ sessionName: String) {
    _ = runPlaywrightCommand(["-s=\(sessionName)", "close"])
  }

  // The Playwright daemon is spawned detached (re-parented to launchd), and the
  // only teardown is the in-process `defer` in scrapeChatGPT. If the app quits
  // or crashes mid-scrape (a rebuild during development is enough), that defer
  // never runs and a headless Firefox is orphaned forever. Run this once at
  // launch — gated by the single-instance lock so it can't reap a live sibling's
  // session — to close anything we left behind.
  func reapStaleSessions() {
    guard FileManager.default.isExecutableFile(atPath: playwrightCLI) else { return }
    guard let output = runPlaywrightCommand(["list"]).output else {
      log.warning("reapStaleSessions: could not list Playwright sessions")
      return
    }
    let stale = output.components(separatedBy: "\n").compactMap { line -> String? in
      guard line.hasPrefix("- "), line.hasSuffix(":") else { return nil }
      let name = String(line.dropFirst(2).dropLast())
      return name.hasPrefix(Self.sessionPrefix) ? name : nil
    }
    guard !stale.isEmpty else {
      log.info("reapStaleSessions: no stale sessions")
      return
    }
    log.notice("reapStaleSessions: closing \(stale.count) orphaned session(s)")
    for name in stale {
      log.info("reapStaleSessions: closing \(name)")
      closePlaywrightSession(name)
    }
  }

  private func isPlaywrightFirefoxInstalled() -> Bool {
    let cacheDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/ms-playwright")
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else {
      return false
    }
    return items.contains { $0.hasPrefix("firefox-") }
  }
}