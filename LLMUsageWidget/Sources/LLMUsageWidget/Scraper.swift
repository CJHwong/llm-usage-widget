import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "scraper")

final class Scraper: @unchecked Sendable {
  private let paths: AppPaths
  private let dataFile: URL
  private let chatGPTToggleFile: URL
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
  private static let regexChatGPTResets = try! NSRegularExpression(pattern: "Resets[^\\n]*")
  private static let regexChatGPTPct = try! NSRegularExpression(pattern: #"(\d+)%"#)

  private static let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()
  private static let resetTimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "h:mm a"
    return f
  }()
  private static let resetDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d, yyyy h:mm a"
    return f
  }()

  init() {
    paths = AppPaths()
    paths.migrateLegacyDataIfNeeded()
    dataFile = paths.usageFile
    chatGPTToggleFile = paths.chatGPTToggleFile
  }

  var chatGPTTogglePath: String {
    chatGPTToggleFile.path
  }

  func preflightMessage() -> String? {
    let issues = preflightIssues()
    return issues.isEmpty ? nil : issues.joined(separator: "\n")
  }

  func latestIssueMessage() -> String? {
    _lock.withLock { _lastIssueMessage }
  }

  func scrape() async -> UsageData? {
    log.info("scrape() started")
    _lock.withLock { _lastIssueMessage = preflightMessage() }
    guard let browser = BrowserRegistry.firstSupportedProfile() else {
      log.warning("No supported browser profile found")
      return nil
    }
    log.info("Found browser profile: \(browser.profile.browserName) at \(browser.profile.profilePath)")
    let fmt = Self.timeFmt

    if let ch = browser.adapter.cookieHeader(for: browser.profile, domains: ["ollama", "workos"]),
      let ollama = await scrapeOllama(cookies: ch)
    {
      log.info("Ollama scrape succeeded")
      var merged = read() ?? UsageData()
      merged.ollama = ollama
      merged.lastUpdated = fmt.string(from: Date())
      write(merged)
      _lock.withLock { _lastIssueMessage = nil }
    } else {
      log.warning("Ollama scrape: no cookies or parse failed")
      _lock.withLock {
        _lastIssueMessage =
          "Could not read authenticated Ollama usage from \(browser.profile.browserName). Check that you are signed in and the profile still has the required cookies."
      }
    }

    if FileManager.default.fileExists(atPath: chatGPTToggleFile.path) {
      let shouldScrape = _lock.withLock { () -> Bool in
        if _isScrapingChatGPT { return false }
        _isScrapingChatGPT = true
        return true
      }
      if shouldScrape {
        log.info("ChatGPT toggle file found, starting ChatGPT scrape on background thread")
        DispatchQueue.global().async { [self, browser] in
          defer { self._lock.withLock { self._isScrapingChatGPT = false } }
          log.info("BG: scrapeChatGPT() called")
          if let c = self.scrapeChatGPT(using: browser) {
            var d = self.read() ?? UsageData()
            d.chatgpt = c
            d.lastUpdated = fmt.string(from: Date())
            self.write(d)
            log.info("BG: ChatGPT data written, posting notification")
            DispatchQueue.main.async {
              NotificationCenter.default.post(name: kChatGPTDone, object: nil)
            }
          } else {
            log.warning("BG: scrapeChatGPT() returned nil")
          }
        }
      } else {
        log.info("ChatGPT scrape already in progress, skipping")
      }
    } else {
      log.notice("ChatGPT toggle file not found at \(self.chatGPTToggleFile.path)")
    }
    log.info("scrape() returning")
    return read()
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

  private func scrapeChatGPT(using browser: BrowserSelection) -> ChatGPTData? {
    log.info("scrapeChatGPT() START")
    log.info("scrapeChatGPT: using \(browser.profile.browserName) profile at \(browser.profile.profilePath)")

    let tmpDir = URL(fileURLWithPath: "/tmp/pwt-\(ProcessInfo.processInfo.globallyUniqueString)")
    let sessionName = "chatgpt-\(ProcessInfo.processInfo.globallyUniqueString)"
    log.info("scrapeChatGPT: tmpDir=\(tmpDir.path) session=\(sessionName)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    guard browser.adapter.prepareProfileForPlaywright(from: browser.profile, at: tmpDir) else {
      log.error("scrapeChatGPT: prepareProfileForPlaywright failed")
      try? FileManager.default.removeItem(at: tmpDir)
      return nil
    }
    log.info("scrapeChatGPT: profile prepared for playwright")

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: playwrightCLI)
    proc.arguments = [
      "-s=\(sessionName)", "open", "--browser", browser.adapter.playwrightBrowserName,
      "--persistent", "--profile", tmpDir.path,
      "https://chatgpt.com/codex/cloud/settings/analytics",
    ]
    let openOut = Pipe()
    let openErr = Pipe()
    proc.standardOutput = openOut
    proc.standardError = openErr
    guard (try? proc.run()) != nil else {
      log.error("scrapeChatGPT: failed to launch playwright process")
      _lock.withLock { _lastIssueMessage = "Could not launch Playwright for ChatGPT." }
      try? FileManager.default.removeItem(at: tmpDir)
      return nil
    }
    log.info("scrapeChatGPT: playwright launched (PID \(proc.processIdentifier))")
    defer {
      log.info("scrapeChatGPT: cleanup - closing session + terminating proc")
      closePlaywrightSession(sessionName)
      proc.terminate()
      try? FileManager.default.removeItem(at: tmpDir)
    }

    log.info("scrapeChatGPT: entering waitForChatGPTPage loop")
    guard let body = waitForChatGPTPage(sessionName: sessionName) else {
      log.warning("scrapeChatGPT: waitForChatGPTPage returned nil")
      if _lock.withLock({ _lastIssueMessage }) == nil {
        _lock.withLock {
          _lastIssueMessage =
            "ChatGPT opened but the analytics page never became ready. Check that you are signed in and still have access to Codex analytics."
        }
      }
      return nil
    }
    log.info("scrapeChatGPT: page body received, length=\(body.count)")
    log.debug("scrapeChatGPT: body preview=\(body.prefix(500))")

    guard let parsed = parseChatGPTText(body) else {
      log.warning("scrapeChatGPT: parseChatGPTText returned nil")
      return nil
    }
    log.info("scrapeChatGPT: parsed successfully - 5h=\(parsed.fiveHourPct)% weekly=\(parsed.weeklyPct)% resets=\(parsed.resets)")
    return parsed
  }

  private func parseChatGPTText(_ text: String) -> ChatGPTData? {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)

    let pctMatches = Self.regexChatGPTPct.matches(in: text, range: full).map {
      Int(ns.substring(with: $0.range(at: 1))) ?? 0
    }

    let relevant = pctMatches.filter { $0 < 100 && $0 > 0 }
    let fiveHourPct = relevant.count >= 1 ? 100 - Double(relevant[0]) : 0
    let weeklyPct =
      relevant.count >= 2 ? 100 - Double(relevant[1]) : (relevant.count == 1 ? 0 : 100)

    let resets = Self.regexChatGPTResets.matches(in: text, range: full).map {
      normalizeReset(ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return ChatGPTData(fiveHourPct: fiveHourPct, weeklyPct: weeklyPct, resets: resets)
  }

  private func normalizeReset(_ raw: String) -> String {
    let stripped = raw.replacingOccurrences(of: "Resets ", with: "").trimmingCharacters(in: .whitespaces)
    // Already relative (e.g. "Resets in 3 hours")
    if stripped.hasPrefix("in ") { return raw }
    // Time-only format (e.g. "3:00 AM")
    if let time = Self.resetTimeFmt.date(from: stripped) {
      let now = Date()
      let cal = Calendar.current
      var target = cal.date(bySettingHour: cal.component(.hour, from: time), minute: cal.component(.minute, from: time), second: 0, of: now)
        ?? now.addingTimeInterval(86400)
      if target <= now { target = target.addingTimeInterval(86400) }
      return Self.formatResetInterval(target.timeIntervalSinceNow)
    }
    // Full date format (e.g. "Aug 1, 2025 3:00 AM")
    guard let date = Self.resetDateFmt.date(from: stripped) else { return raw }
    let interval = date.timeIntervalSinceNow
    guard interval > 0 else { return raw }
    return Self.formatResetInterval(interval)
  }

  private static func formatResetInterval(_ interval: TimeInterval) -> String {
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

    if BrowserRegistry.firstSupportedProfile() == nil {
      issues.append("No supported Zen or Firefox profile with cookies was found.")
    }
    if !FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") {
      issues.append("Missing required system binary: /usr/bin/sqlite3.")
    }
    if !FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") {
      issues.append("Missing required system binary: /usr/bin/curl.")
    }
    if FileManager.default.fileExists(atPath: chatGPTToggleFile.path) {
      if !FileManager.default.isExecutableFile(atPath: playwrightCLI) {
        issues.append("ChatGPT scraping is enabled but playwright-cli is not installed.")
      } else if !isPlaywrightFirefoxInstalled() {
        issues.append(
          "ChatGPT scraping is enabled but the Playwright Firefox browser is not installed. Run `playwright-cli install-browser firefox`."
        )
      }
    }

    return issues
  }

  private func waitForChatGPTPage(sessionName: String) -> String? {
    let deadline = Date().addingTimeInterval(30)
    log.info("waitForChatGPTPage: polling for up to 30s, session=\(sessionName)")
    var attempt = 0

    // Give playwright time to open the browser and load the page
    log.info("waitForChatGPTPage: initial 3s delay for Playwright browser to start")
    Thread.sleep(forTimeInterval: 3)

    while Date() < deadline {
      attempt += 1
      log.info("waitForChatGPTPage: poll attempt \(attempt)")
      guard let output = runPlaywrightCommand([
        "-s=\(sessionName)", "eval", "document.body?.innerText ?? ''",
      ]) else {
        log.error("waitForChatGPTPage: runPlaywrightCommand returned nil at attempt \(attempt)")
        _lock.withLock { _lastIssueMessage = "Could not read the ChatGPT page from Playwright." }
        return nil
      }

      let body = decodePlaywrightStringResult(output)
      log.debug("waitForChatGPTPage: attempt \(attempt) raw output length=\(output.count), decoded length=\(body.count)")
      log.debug("waitForChatGPTPage: attempt \(attempt) body=\(body.prefix(300))")

      if isChatGPTAnalyticsPageReady(body) {
        log.info("waitForChatGPTPage: analytics page ready at attempt \(attempt)")
        return body
      }
      if body.lowercased().contains("log in") || body.lowercased().contains("sign up") {
        log.warning("waitForChatGPTPage: login page detected at attempt \(attempt)")
        _lock.withLock { _lastIssueMessage = "ChatGPT needs an active signed-in session in the selected browser." }
        return nil
      }
      log.info("waitForChatGPTPage: not ready yet, sleeping 1s")
      Thread.sleep(forTimeInterval: 1)
    }

    log.warning("waitForChatGPTPage: timed out after \(attempt) attempts")
    return nil
  }

  private func isChatGPTAnalyticsPageReady(_ body: String) -> Bool {
    body.contains("Resets") && body.contains("%")
  }

  private func runPlaywrightCommand(_ arguments: [String]) -> String? {
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
      return nil
    }
    if sem.wait(timeout: .now() + 10) == .timedOut {
      proc.terminate()
      log.error("runPlaywrightCommand: timed out after 10s, args=\(arguments.joined(separator: " "))")
      return nil
    }
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if proc.terminationStatus != 0 {
      log.error("runPlaywrightCommand: exit code \(proc.terminationStatus), args=\(arguments.joined(separator: " "))")
      log.error("runPlaywrightCommand: stderr=\(stderr)")
      return nil
    }
    if !stderr.isEmpty {
      log.info("runPlaywrightCommand: stderr=\(stderr)")
    }

    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
  }

  private func closePlaywrightSession(_ sessionName: String) {
    _ = runPlaywrightCommand(["-s=\(sessionName)", "close"])
  }

  private func decodePlaywrightStringResult(_ output: String) -> String {
    guard let resultSection = output.components(separatedBy: "### Result\n").dropFirst().first
    else { return "" }
    guard let firstLine = resultSection.components(separatedBy: "\n").first else { return "" }
    let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
      return trimmed
    }

    let raw = String(trimmed.dropFirst().dropLast())
    // Process \\ first (via placeholder) so it doesn't feed into \n, \t, \"
    return raw
      .replacingOccurrences(of: "\\\\", with: "\u{0001}")
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\t", with: "\t")
      .replacingOccurrences(of: "\\\"", with: "\"")
      .replacingOccurrences(of: "\u{0001}", with: "\\")
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