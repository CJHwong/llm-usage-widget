import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "scraper")

// What a scrape cycle hands back to load(): the fresh data plus whether this
// cycle started a background browser pass. That pass is what posts
// kBrowserScrapeDone, which clears the panel's isRefreshing; when it wasn't
// started (both providers off, nothing to scrape, or one already running),
// load() must clear the flag itself or the panel spins forever.
struct ScrapeOutcome {
  let usage: UsageData?
  let spawnedBrowserPass: Bool
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
  private var _isRunningBrowserPass = false

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

  // The Claude switch. Browser scraping is the expensive part, so each provider
  // has its own gate; one background pass serves both.
  private var claudeEnabled: Bool { UserDefaults.standard.bool(forKey: claudeEnabledKey) }

  // How long a failing scrape may keep its last numbers before the UI has to
  // call them stale. The UI re-applies the same cutoff at render time.
  private static let staleAfter = UsageData.staleAfter

  private func providerStatus(
    enabled: Bool, data: Bool, updatedAt: Date?
  ) -> ProviderStatus {
    if !enabled { return .off }
    guard data else { return .unavailable }
    guard let updatedAt else { return .stale }
    return Date().timeIntervalSince(updatedAt) > Self.staleAfter ? .stale : .on
  }

  private func ollamaStatus(data: OllamaData?, updatedAt: Date?) -> OllamaStatus {
    guard data != nil else { return .unavailable }
    guard let updatedAt else { return .stale }
    return Date().timeIntervalSince(updatedAt) > Self.staleAfter ? .stale : .on
  }

  // Rewrite usage.json's provider statuses from the current toggles + cached
  // data, without scraping, so a menu toggle reflects in the widget/panel
  // immediately.
  func refreshProviderStatuses() {
    guard var d = read() else { return }
    d.chatgptStatus = providerStatus(
      enabled: chatGPTEnabled, data: d.chatgpt != nil, updatedAt: d.chatgptUpdatedAt)
    d.claudeStatus = providerStatus(
      enabled: claudeEnabled, data: d.claude != nil, updatedAt: d.claudeUpdatedAt)
    d.ollamaStatus = ollamaStatus(data: d.ollama, updatedAt: d.ollamaUpdatedAt)
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
    let wantClaude = claudeEnabled
    let preflight = preflightMessage()
    _lock.withLock { _lastIssueMessage = preflight }
    let fmt = Self.timeFmt
    guard let browser = BrowserRegistry.firstSupportedProfile() else {
      log.warning("No supported browser profile found")
      // A missing profile is a fetch failure for every source. Record it so the
      // header says so instead of freezing on the last good numbers.
      var d = read() ?? UsageData()
      let issue = "No browser profile found"
      d.ollamaIssue = issue
      d.ollamaStatus = ollamaStatus(data: d.ollama, updatedAt: d.ollamaUpdatedAt)
      if wantChatGPT {
        d.chatgptIssue = issue
        d.chatgptStatus = providerStatus(
          enabled: true, data: d.chatgpt != nil, updatedAt: d.chatgptUpdatedAt)
      }
      if wantClaude {
        d.claudeIssue = issue
        d.claudeStatus = providerStatus(
          enabled: true, data: d.claude != nil, updatedAt: d.claudeUpdatedAt)
      }
      d.lastUpdated = fmt.string(from: Date())
      write(d)
      return ScrapeOutcome(usage: read(), spawnedBrowserPass: false)
    }
    log.info("Found browser profile: \(browser.profile.browserName) at \(browser.profile.profilePath)")

    let ollamaCookies = browser.adapter.cookies(for: browser.profile, domains: ["ollama", "workos"])
    var merged = read() ?? UsageData()
    if let ch = cookieHeader(from: ollamaCookies),
      let ollama = await scrapeOllama(cookies: ch)
    {
      log.info("Ollama scrape succeeded")
      merged.ollama = ollama
      merged.ollamaUpdatedAt = Date()
      merged.ollamaIssue = nil
      merged.ollamaStatus = .on
      // Back to the preflight baseline, not nil: Ollama working says nothing
      // about whether the browser providers' prerequisites are in place, and
      // clearing the preflight text here is what hid a missing Playwright
      // browser for days.
      _lock.withLock { _lastIssueMessage = preflight }
    } else if ollamaCookies.isEmpty {
      // Not signed in to Ollama in the selected browser: drop any stale numbers
      // (e.g. left over from another browser) so the panel shows the truth.
      log.warning("Ollama: no cookies in \(browser.profile.browserName)")
      merged.ollama = nil
      merged.ollamaUpdatedAt = nil
      merged.ollamaIssue = nil
      merged.ollamaStatus = .unavailable
      _lock.withLock {
        _lastIssueMessage = "Not signed in to Ollama in \(browser.profile.browserName)."
      }
    } else {
      // Cookies exist but the fetch/parse failed (transient): keep the last
      // good data and let its timestamp decide whether it still reads live.
      log.warning("Ollama scrape failed despite cookies present")
      merged.ollamaIssue = "Fetch failed"
      merged.ollamaStatus = ollamaStatus(
        data: merged.ollama, updatedAt: merged.ollamaUpdatedAt)
      _lock.withLock {
        _lastIssueMessage =
          "Could not read Ollama usage from \(browser.profile.browserName). Check that you are signed in and the profile still has the required cookies."
      }
    }
    merged.lastUpdated = fmt.string(from: Date())
    merged.chatgptStatus = providerStatus(
      enabled: wantChatGPT, data: merged.chatgpt != nil, updatedAt: merged.chatgptUpdatedAt)
    merged.claudeStatus = providerStatus(
      enabled: wantClaude, data: merged.claude != nil, updatedAt: merged.claudeUpdatedAt)
    write(merged)

    var spawnedBrowserPass = false
    if wantChatGPT || wantClaude {
      let shouldScrape = _lock.withLock { () -> Bool in
        if _isRunningBrowserPass { return false }
        _isRunningBrowserPass = true
        return true
      }
      if shouldScrape {
        spawnedBrowserPass = true
        log.info("Starting browser pass (chatgpt=\(wantChatGPT), claude=\(wantClaude))")
        DispatchQueue.global().async { [self, browser] in
          defer { self._lock.withLock { self._isRunningBrowserPass = false } }
          self.runBrowserPass(using: browser, wantChatGPT: wantChatGPT, wantClaude: wantClaude)
          DispatchQueue.main.async {
            NotificationCenter.default.post(name: kBrowserScrapeDone, object: nil)
          }
        }
      } else {
        log.info("Browser pass already in progress, skipping")
      }
    } else {
      log.notice("ChatGPT and Claude disabled; skipping browser pass")
    }
    log.info("scrape() returning")
    return ScrapeOutcome(usage: read(), spawnedBrowserPass: spawnedBrowserPass)
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

  // Outcome of a ChatGPT scrape. The cookie check happens before the browser
  // opens, so this only carries success or a transient failure.
  private enum ChatGPTScrapeOutcome {
    case success(ChatGPTData)
    // Carries a short reason the widget prints verbatim, so keep it to a few
    // words. The verbose remediation text stays in _lastIssueMessage.
    case transientFailure(String)
  }

  // Same shape, without a not-signed-in case: the cookie check happens before
  // the browser opens.
  private enum ClaudeScrapeOutcome {
    case success(ClaudeData)
    case transientFailure(String)
  }

  // General settings no longer requests usage. Open Usage through the settings
  // navigation because a direct visit does not reliably request the numbers.
  // History endpoints share the usage prefix but do not contain usage windows.
  private static let usageCaptureScript = """
    async (page) => {
      const usageResponse = page.waitForResponse(
        response => new URL(response.url()).pathname === '/backend-api/wham/usage'
          && response.status() === 200,
        { timeout: 30000 }
      ).catch(() => null);
      try {
        await page.goto('https://chatgpt.com/settings/general-settings', {
          waitUntil: 'domcontentloaded', timeout: 25000,
        });
        await page.getByText('Usage', { exact: true }).click({ timeout: 5000 });
        const response = await usageResponse;
        return JSON.stringify(response ? await response.json() : null);
      } catch (error) {
        return JSON.stringify(null);
      }
    }
    """

  // A missing response does not prove a block. Keep the response status and
  // parse errors separate so the widget can report the observed failure.
  private static let claudeCaptureScript = """
    async (page) => {
      let captured = null;
      let pageStatus = null;
      let navigationFailed = false;
      const usagePage = await page.context().newPage();
      usagePage.on('response', async (response) => {
        const usagePath = new URL(response.url()).pathname;
        if (!/^[/]api[/]organizations[/][^/]+[/]usage$/.test(usagePath)) return;
        if (response.status() !== 200) {
          captured = { issue: 'Claude usage returned HTTP ' + response.status() };
          return;
        }
        try {
          captured = { usage: await response.json() };
        } catch (error) {
          captured = { issue: 'Claude usage response was not JSON' };
        }
      });
      try {
        try {
          const navigation = await usagePage.goto('https://claude.ai/new#settings/usage', {
            waitUntil: 'domcontentloaded', timeout: 25000,
          });
          pageStatus = navigation?.status() ?? null;
        } catch (error) {
          navigationFailed = true;
        }
        for (let attempt = 0; attempt < 24 && captured === null; attempt++) {
          await usagePage.waitForTimeout(500);
        }
        if (captured !== null) return JSON.stringify(captured);
        if (pageStatus >= 400) {
          return JSON.stringify({ issue: 'Claude page returned HTTP ' + pageStatus });
        }
        return JSON.stringify({
          issue: navigationFailed ? 'Claude page did not load' : 'No Claude usage response',
        });
      } finally {
        await usagePage.close();
      }
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

  private struct ClaudeCaptureResponse: Decodable {
    let usage: ClaudeUsageResponse?
    let issue: String?
  }

  // The slice of /api/organizations/<org>/usage we read. `limits` is the
  // structured view the settings page renders; `seven_day` is the older
  // account-level meter and serves as a fallback. Unknown keys are ignored.
  private struct ClaudeUsageResponse: Decodable {
    let limits: [Limit]?
    let sevenDay: Window?
    enum CodingKeys: String, CodingKey {
      case limits
      case sevenDay = "seven_day"
    }

    struct Limit: Decodable {
      let kind: String?
      let percent: Double?
      let resetsAt: String?
      enum CodingKeys: String, CodingKey {
        case kind, percent
        case resetsAt = "resets_at"
      }
    }

    struct Window: Decodable {
      let utilization: Double?
      let resetsAt: String?
      enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
      }
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

  // One Playwright browser serves both providers: open once, load the cookies,
  // then run each capture independently. A ChatGPT failure must not cost the
  // Claude number, and vice versa.
  private func runBrowserPass(
    using browser: BrowserSelection, wantChatGPT: Bool, wantClaude: Bool
  ) {
    log.info("runBrowserPass: chatgpt=\(wantChatGPT) claude=\(wantClaude)")
    // Inject cookies through a Playwright storage_state instead of copying the
    // browser profile: Chromium can't decrypt Chrome's cookie DB (different Safe
    // Storage key), so we hand Playwright already-decrypted cookies. This works
    // uniformly for Chrome and Firefox.
    let cookies = browser.adapter.cookies(
      for: browser.profile, domains: ["chatgpt", "openai", "claude"])
    // Logging out deletes the session cookie while leaving cf_clearance behind,
    // so checking it here is more reliable than scraping the page: a logged-out
    // hit just stalls on Cloudflare's "Just a moment..." wall.
    let chatSignedIn = cookies.contains { $0.name.contains("session-token") }
    let claudeSignedIn = cookies.contains {
      $0.name == "sessionKey" || $0.name == "sessionKeyV3"
    }
    let chatNeedsScrape = wantChatGPT && chatSignedIn
    let claudeNeedsScrape = wantClaude && claudeSignedIn

    var d = read() ?? UsageData()
    if wantChatGPT && !chatSignedIn {
      log.warning("runBrowserPass: no ChatGPT session-token cookie")
      _lock.withLock {
        _lastIssueMessage =
          "No ChatGPT session found in \(browser.profile.browserName). Sign in to ChatGPT in that browser."
      }
      d.chatgpt = nil
      d.chatgptUpdatedAt = nil
      d.chatgptIssue = nil
      d.chatgptStatus = .unavailable
    }
    if wantClaude && !claudeSignedIn {
      log.warning("runBrowserPass: no Claude sessionKey cookie")
      _lock.withLock {
        _lastIssueMessage =
          "No Claude session found in \(browser.profile.browserName). Sign in to Claude in that browser."
      }
      d.claude = nil
      d.claudeUpdatedAt = nil
      d.claudeIssue = nil
      d.claudeStatus = .unavailable
    }
    guard chatNeedsScrape || claudeNeedsScrape else {
      write(d)
      return
    }
    guard let stateData = storageStateData(from: cookies) else {
      failBoth(&d, chat: chatNeedsScrape, claude: claudeNeedsScrape,
               reason: "Could not stage the browser session")
      write(d)
      return
    }

    let tmpDir = URL(fileURLWithPath: "/tmp/pwt-\(ProcessInfo.processInfo.globallyUniqueString)")
    let stateFile = tmpDir.appendingPathComponent("state.json")
    let sessionName = "\(Self.sessionPrefix)\(ProcessInfo.processInfo.globallyUniqueString)"
    log.info("runBrowserPass: tmpDir=\(tmpDir.path) session=\(sessionName)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer {
      log.info("runBrowserPass: cleanup - closing session")
      closePlaywrightSession(sessionName)
      try? FileManager.default.removeItem(at: tmpDir)
    }
    guard (try? stateData.write(to: stateFile)) != nil else {
      log.error("runBrowserPass: failed to write storage_state")
      failBoth(&d, chat: chatNeedsScrape, claude: claudeNeedsScrape,
               reason: "Could not stage the browser session")
      write(d)
      return
    }

    // Open a blank context, load the cookies, then navigate authenticated.
    let openResult = runPlaywrightCommand(
      ["-s=\(sessionName)", "open", "--browser", browser.adapter.playwrightBrowserName, "about:blank"],
      timeout: 30)
    guard openResult.output != nil else {
      let issue = playwrightLaunchIssue(
        for: browser.adapter.playwrightBrowserName, stderr: openResult.stderr)
      log.error("runBrowserPass: open failed (\(issue))")
      _lock.withLock { _lastIssueMessage = preflightMessage() ?? "Could not launch Playwright." }
      failBoth(&d, chat: chatNeedsScrape, claude: claudeNeedsScrape, reason: issue)
      write(d)
      return
    }
    guard runPlaywrightCommand(["-s=\(sessionName)", "state-load", stateFile.path]).output != nil else {
      log.error("runBrowserPass: state-load failed")
      failBoth(&d, chat: chatNeedsScrape, claude: claudeNeedsScrape,
               reason: "Could not load the browser session")
      write(d)
      return
    }

    if chatNeedsScrape {
      apply(captureChatGPT(sessionName: sessionName, tmpDir: tmpDir), to: &d)
    }
    if claudeNeedsScrape {
      apply(captureClaude(sessionName: sessionName, tmpDir: tmpDir), to: &d)
    }
    d.lastUpdated = Self.timeFmt.string(from: Date())
    write(d)
  }

  private func failBoth(
    _ d: inout UsageData, chat: Bool, claude: Bool, reason: String
  ) {
    if chat {
      d.chatgptIssue = reason
      d.chatgptStatus = providerStatus(
        enabled: true, data: d.chatgpt != nil, updatedAt: d.chatgptUpdatedAt)
    }
    if claude {
      d.claudeIssue = reason
      d.claudeStatus = providerStatus(
        enabled: true, data: d.claude != nil, updatedAt: d.claudeUpdatedAt)
    }
  }

  private func apply(_ outcome: ChatGPTScrapeOutcome, to d: inout UsageData) {
    switch outcome {
    case .success(let c):
      d.chatgpt = c
      d.chatgptUpdatedAt = Date()
      d.chatgptIssue = nil
      d.chatgptStatus = .on
      log.info("BG: ChatGPT data written")
    case .transientFailure(let reason):
      // Keep the last good data, record why the refresh failed, and let the
      // timestamp age it into `stale` so the UI stops presenting a frozen
      // number as the current one.
      d.chatgptIssue = reason
      d.chatgptStatus = providerStatus(
        enabled: true, data: d.chatgpt != nil, updatedAt: d.chatgptUpdatedAt)
      log.warning("BG: ChatGPT scrape failed: \(reason)")
    }
  }

  private func apply(_ outcome: ClaudeScrapeOutcome, to d: inout UsageData) {
    switch outcome {
    case .success(let c):
      d.claude = c
      d.claudeUpdatedAt = Date()
      d.claudeIssue = nil
      d.claudeStatus = .on
      log.info("BG: Claude data written - weekly=\(c.weeklyPct)")
    case .transientFailure(let reason):
      d.claudeIssue = reason
      d.claudeStatus = providerStatus(
        enabled: true, data: d.claude != nil, updatedAt: d.claudeUpdatedAt)
      log.warning("BG: Claude scrape failed: \(reason)")
    }
  }

  private func captureChatGPT(sessionName: String, tmpDir: URL) -> ChatGPTScrapeOutcome {
    let scriptFile = tmpDir.appendingPathComponent("capture-chatgpt.js")
    guard (try? Self.usageCaptureScript.write(to: scriptFile, atomically: true, encoding: .utf8)) != nil
    else {
      log.error("captureChatGPT: failed to write the capture script")
      return .transientFailure("Could not stage the usage capture")
    }

    // --raw drops playwright-cli's "### Result" wrapper, so stdout is exactly the
    // script's return value: a JSON string holding the captured payload.
    let capture = runPlaywrightCommand(
      ["-s=\(sessionName)", "--raw", "run-code", "--filename", scriptFile.path],
      timeout: 40)
    guard let output = capture.output else {
      log.error("captureChatGPT: run-code failed, stderr=\(capture.stderr)")
      return .transientFailure("Could not read the usage API")
    }

    // Signed out, or a page that never fired the call, yields the literal "null".
    // Both land here, and both are worth the same message.
    guard let json = try? JSONDecoder().decode(String.self, from: Data(output.utf8)),
      let response = try? JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8)),
      let parsed = chatGPTData(from: response)
    else {
      log.warning("captureChatGPT: capture held no usable usage window")
      _lock.withLock {
        _lastIssueMessage =
          "ChatGPT opened but reported no usage window. Check that you are signed in and still have Codex access."
      }
      return .transientFailure("No usage window reported")
    }
    log.info(
      "captureChatGPT: parsed - 5h=\(String(describing: parsed.fiveHourPct)) weekly=\(String(describing: parsed.weeklyPct))")
    return .success(parsed)
  }

  private func captureClaude(sessionName: String, tmpDir: URL) -> ClaudeScrapeOutcome {
    let scriptFile = tmpDir.appendingPathComponent("capture-claude.js")
    guard
      (try? Self.claudeCaptureScript.write(to: scriptFile, atomically: true, encoding: .utf8)) != nil
    else {
      log.error("captureClaude: failed to write the capture script")
      return .transientFailure("Could not stage the Claude capture")
    }

    // Intermittent failures get one retry without discarding the last good usage.
    var lastIssue = "No Claude usage response"
    for attempt in 1...2 {
      let capture = runPlaywrightCommand(
        ["-s=\(sessionName)", "--raw", "run-code", "--filename", scriptFile.path],
        timeout: 45)
      guard let output = capture.output else {
        lastIssue = "Could not read Claude usage"
        log.error("captureClaude: run-code failed, stderr=\(capture.stderr)")
        continue
      }
      guard let json = try? JSONDecoder().decode(String.self, from: Data(output.utf8)),
        let captured = try? JSONDecoder().decode(ClaudeCaptureResponse.self, from: Data(json.utf8))
      else {
        lastIssue = "Could not decode the Claude capture"
        log.warning("captureClaude: attempt \(attempt): \(lastIssue, privacy: .public)")
        continue
      }
      if let issue = captured.issue {
        lastIssue = issue
        log.warning("captureClaude: attempt \(attempt): \(lastIssue, privacy: .public)")
        continue
      }
      guard let response = captured.usage,
        let parsed = claudeData(from: response)
      else {
        lastIssue = "No Claude weekly usage reported"
        log.warning("captureClaude: attempt \(attempt): \(lastIssue, privacy: .public)")
        continue
      }
      log.info("captureClaude: parsed - weekly=\(parsed.weeklyPct) reset=\(parsed.weeklyReset)")
      return .success(parsed)
    }
    _lock.withLock {
      _lastIssueMessage = lastIssue
    }
    return .transientFailure(lastIssue)
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

  // Claude reports an ISO-8601 reset. Prefer the labelled weekly_all limit; fall
  // back to the account-level seven_day meter if the limits array changes.
  private func claudeData(from response: ClaudeUsageResponse) -> ClaudeData? {
    let weekly = response.limits?.first { $0.kind == "weekly_all" }
    guard let pct = weekly?.percent ?? response.sevenDay?.utilization else { return nil }
    let resetISO = weekly?.resetsAt ?? response.sevenDay?.resetsAt
    return ClaudeData(
      weeklyPct: pct,
      weeklyReset: resetISO.flatMap(resetText(iso:)) ?? "")
  }

  private func resetText(iso: String) -> String? {
    // Formatters are not Sendable, so build them here instead of sharing statics.
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    guard let date = fractional.date(from: iso) ?? plain.date(from: iso) else {
      return nil
    }
    let interval = date.timeIntervalSinceNow
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
    let arguments = [
      "-sL", "--max-time", "15", "-H", "Cookie: \(cookie)",
      "-H",
      "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:135.0) Gecko/20100101 Firefox/135.0",
      url,
    ]
    // Hop off the cooperative pool: the wait below parks a thread for up to 25s.
    let result = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(
          returning: ProcessRunner.run(
            executable: "/usr/bin/curl", arguments: arguments, timeout: 25))
      }
    }
    if result.timedOut {
      log.error("httpGet: killed curl after 25s")
      return nil
    }
    guard result.status == 0 else {
      log.warning("httpGet: curl exit code \(result.status)")
      return nil
    }
    guard let text = String(data: result.stdout, encoding: .utf8) else {
      log.warning("httpGet: response not UTF-8")
      return nil
    }
    log.info("httpGet: received \(text.count) bytes")
    return text
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
    if chatGPTEnabled || claudeEnabled {
      if !FileManager.default.isExecutableFile(atPath: playwrightCLI) {
        issues.append("A browser provider is enabled but playwright-cli is not installed.")
      } else if selection?.adapter.playwrightBrowserName == "firefox", !isPlaywrightFirefoxInstalled()
      {
        // The Chrome channel uses the installed Google Chrome, so only the
        // Firefox path needs Playwright's bundled browser.
        issues.append(
          "A browser provider is enabled but the Playwright Firefox browser is not installed. Run `playwright-cli install-browser firefox`."
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
  // only teardown is the in-process `defer` in runBrowserPass. If the app quits
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
