import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "browser-adapter")

struct BrowserProfile {
  let browserName: String
  let profilePath: String
}

// One decrypted cookie, browser-agnostic. Feeds both the curl "Cookie:" header
// (Ollama path) and the Playwright storage_state (ChatGPT path), so each browser
// only has to know how to read its own store — not how the cookies get used.
struct BrowserCookie: Sendable {
  let domain: String
  let name: String
  let value: String
  let path: String
  let expires: Double  // unix seconds; -1 for a session cookie
  let isSecure: Bool
  let isHTTPOnly: Bool
  let sameSite: String  // "Strict" | "Lax" | "None"
}

protocol BrowserAdapter: Sendable {
  var browserName: String { get }
  var playwrightBrowserName: String { get }
  func findProfile() -> BrowserProfile?
  func cookies(for profile: BrowserProfile, domains: [String]) -> [BrowserCookie]
}

struct BrowserSelection {
  let adapter: any BrowserAdapter
  let profile: BrowserProfile
}

// Curl-ready "Cookie:" header value.
func cookieHeader(from cookies: [BrowserCookie]) -> String? {
  cookies.isEmpty ? nil : cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
}

// Playwright storage_state document for `state-load`. Playwright rejects a
// SameSite=None cookie that isn't Secure, so downgrade those to Lax.
func storageStateData(from cookies: [BrowserCookie]) -> Data? {
  guard !cookies.isEmpty else { return nil }
  let entries: [[String: Any]] = cookies.map { cookie in
    let sameSite = (cookie.sameSite == "None" && !cookie.isSecure) ? "Lax" : cookie.sameSite
    return [
      "name": cookie.name, "value": cookie.value, "domain": cookie.domain,
      "path": cookie.path, "expires": cookie.expires, "httpOnly": cookie.isHTTPOnly,
      "secure": cookie.isSecure, "sameSite": sameSite,
    ]
  }
  return try? JSONSerialization.data(withJSONObject: ["cookies": entries, "origins": []])
}

// SQL `OR` of substring matches against a host column, e.g. host LIKE '%ollama%'.
func domainFilter(_ domains: [String], column: String) -> String {
  domains.map { domain in
    let escaped = domain.replacingOccurrences(of: "'", with: "''")
    return "\(column) LIKE '%\(escaped)%'"
  }.joined(separator: " OR ")
}

// Reads a (possibly locked) browser cookie DB by copying it to /tmp first, then
// runs the query with ASCII unit/record separators so cookie values containing
// '|' or newlines don't corrupt the row split.
enum SQLiteReader {
  static func rows(dbPath: String, query: String) -> [[String]]? {
    let tmp = "/tmp/occ-\(ProcessInfo.processInfo.globallyUniqueString).sqlite"
    guard (try? FileManager.default.copyItem(atPath: dbPath, toPath: tmp)) != nil else {
      log.error("SQLiteReader: failed to copy \(dbPath)")
      return nil
    }
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    proc.arguments = ["-separator", "\u{1f}", "-newline", "\u{1e}", tmp, query]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    guard (try? proc.run()) != nil else {
      log.error("SQLiteReader: sqlite3 launch failed")
      return nil
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      log.warning("SQLiteReader: sqlite3 exit code \(proc.terminationStatus)")
      return nil
    }
    guard let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    else {
      log.warning("SQLiteReader: output not UTF-8")
      return nil
    }
    return raw.split(separator: "\u{1e}", omittingEmptySubsequences: true).map {
      $0.components(separatedBy: "\u{1f}")
    }
  }
}

enum BrowserRegistry {
  // Returns the cookie source. With no preference (or "Automatic") it's the
  // first browser found in adapter order; otherwise the named browser only.
  static func firstSupportedProfile() -> BrowserSelection? {
    let preferred = UserDefaults.standard.string(forKey: preferredBrowserKey)
    let pool = adapters.filter { adapter in
      preferred == nil || preferred == automaticBrowserValue || adapter.browserName == preferred
    }
    return pool.lazy.compactMap { adapter in
      adapter.findProfile().map { BrowserSelection(adapter: adapter, profile: $0) }
    }.first
  }

  // Browser names that currently have a usable profile, for the menu picker.
  static func availableBrowserNames() -> [String] {
    adapters.compactMap { $0.findProfile() != nil ? $0.browserName : nil }
  }

  private static var adapters: [any BrowserAdapter] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      ChromiumFamilyBrowserAdapter(
        browserName: "Chrome",
        applicationSupportDir: home.appendingPathComponent(
          "Library/Application Support/Google/Chrome"),
        playwrightBrowserName: "chrome",
        keychainService: "Chrome Safe Storage"),
      FirefoxFamilyBrowserAdapter(
        browserName: "Firefox",
        applicationSupportDir: home.appendingPathComponent("Library/Application Support/Firefox")),
      FirefoxFamilyBrowserAdapter(
        browserName: "Zen",
        applicationSupportDir: home.appendingPathComponent("Library/Application Support/zen")),
    ]
  }
}

struct FirefoxFamilyBrowserAdapter: BrowserAdapter {
  let browserName: String
  let applicationSupportDir: URL

  var playwrightBrowserName: String { "firefox" }

  func findProfile() -> BrowserProfile? {
    log.info("findProfile: searching for \(self.browserName) profile")
    let profilePath =
      profilePathFromINI()
      ?? fallbackProfilePath()
    guard let profilePath else {
      log.warning("findProfile: no profile found for \(self.browserName)")
      return nil
    }
    log.info("findProfile: found \(self.browserName) profile at \(profilePath)")
    return BrowserProfile(browserName: browserName, profilePath: profilePath)
  }

  // Firefox stores cookies in plaintext, so this is a straight read of moz_cookies.
  func cookies(for profile: BrowserProfile, domains: [String]) -> [BrowserCookie] {
    log.info("cookies: reading \(profile.browserName) cookies, domains=\(domains)")
    let src = (profile.profilePath as NSString).appendingPathComponent("cookies.sqlite")
    let query =
      "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite "
      + "FROM moz_cookies WHERE \(domainFilter(domains, column: "host"))"
    guard let rows = SQLiteReader.rows(dbPath: src, query: query) else { return [] }

    let parsed = rows.compactMap { columns -> BrowserCookie? in
      guard columns.count >= 8 else { return nil }
      // moz_cookies.expiry is milliseconds here; Playwright's storage_state
      // wants unix seconds, so divide before handing it over.
      let expiry = (Double(columns[4]) ?? 0) / 1000
      return BrowserCookie(
        domain: columns[0], name: columns[1], value: columns[2],
        path: columns[3].isEmpty ? "/" : columns[3],
        expires: expiry == 0 ? -1 : expiry,
        isSecure: columns[5] == "1", isHTTPOnly: columns[6] == "1",
        sameSite: Self.sameSite(columns[7]))
    }
    log.info("cookies: parsed \(parsed.count) cookies for \(domains)")
    return parsed
  }

  // Firefox sameSite enum: 0 unset/none, 1 lax, 2 strict.
  private static func sameSite(_ raw: String) -> String {
    switch raw {
    case "2": return "Strict"
    case "0": return "None"
    default: return "Lax"
    }
  }

  private func profilePathFromINI() -> String? {
    let iniURL = applicationSupportDir.appendingPathComponent("profiles.ini")
    guard let raw = try? String(contentsOf: iniURL, encoding: .utf8) else { return nil }

    let parser = INIParser(text: raw)
    let installDefault = parser.sections
      .filter { $0.name.hasPrefix("Install") }
      .compactMap { resolveProfilePath(path: $0.values["Default"], isRelative: true) }
      .first(where: hasCookies(at:))
    if let installDefault { return installDefault }

    let defaultProfile = parser.sections
      .filter { $0.name.hasPrefix("Profile") }
      .first { $0.values["Default"] == "1" }
      .flatMap {
        resolveProfilePath(path: $0.values["Path"], isRelative: $0.values["IsRelative"] == "1")
      }
    if let defaultProfile, hasCookies(at: defaultProfile) { return defaultProfile }

    let namedProfiles = parser.sections
      .filter { $0.name.hasPrefix("Profile") }
      .compactMap { section in
        resolveProfilePath(
          path: section.values["Path"], isRelative: section.values["IsRelative"] == "1")
      }
    for candidate in namedProfiles where hasCookies(at: candidate) {
      return candidate
    }
    return nil
  }

  private func fallbackProfilePath() -> String? {
    let profilesDir = applicationSupportDir.appendingPathComponent("Profiles").path
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else {
      return nil
    }

    let candidates = items.sorted { lhs, rhs in
      profileScore(for: lhs) > profileScore(for: rhs)
    }

    for candidate in candidates {
      let path = (profilesDir as NSString).appendingPathComponent(candidate)
      if hasCookies(at: path) {
        return path
      }
    }
    return nil
  }

  private func resolveProfilePath(path: String?, isRelative: Bool) -> String? {
    guard let path, !path.isEmpty else { return nil }
    if isRelative {
      return applicationSupportDir.appendingPathComponent(path).path
    }
    return path
  }

  private func hasCookies(at profilePath: String) -> Bool {
    FileManager.default.fileExists(
      atPath: (profilePath as NSString).appendingPathComponent("cookies.sqlite"))
  }

  private func profileScore(for name: String) -> Int {
    let lower = name.lowercased()
    if lower.contains("default-release") || lower.contains("release") { return 3 }
    if lower.contains("default") { return 2 }
    return 1
  }
}

private struct INISection {
  let name: String
  var values: [String: String]
}

private struct INIParser {
  let sections: [INISection]

  init(text: String) {
    var parsed: [INISection] = []
    var currentName: String?
    var currentValues: [String: String] = [:]

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") {
        continue
      }

      if line.hasPrefix("[") && line.hasSuffix("]") {
        if let currentName {
          parsed.append(INISection(name: currentName, values: currentValues))
        }
        currentName = String(line.dropFirst().dropLast())
        currentValues = [:]
        continue
      }

      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      currentValues[String(parts[0])] = String(parts[1])
    }

    if let currentName {
      parsed.append(INISection(name: currentName, values: currentValues))
    }
    sections = parsed
  }
}
