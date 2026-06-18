import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "browser-adapter")

struct BrowserProfile {
  let browserName: String
  let profilePath: String
}

protocol BrowserAdapter: Sendable {
  var playwrightBrowserName: String { get }
  func findProfile() -> BrowserProfile?
  func cookieHeader(for profile: BrowserProfile, domains: [String]) -> String?
  func prepareProfileForPlaywright(from profile: BrowserProfile, at tmpDir: URL) -> Bool
}

struct BrowserSelection {
  let adapter: any BrowserAdapter
  let profile: BrowserProfile
}

enum BrowserRegistry {
  static func firstSupportedProfile() -> BrowserSelection? {
    firefoxFamilyAdapters.compactMap { adapter in
      adapter.findProfile().map { BrowserSelection(adapter: adapter, profile: $0) }
    }.first
  }

  private static var firefoxFamilyAdapters: [FirefoxFamilyBrowserAdapter] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      FirefoxFamilyBrowserAdapter(
        browserName: "Zen",
        applicationSupportDir: home.appendingPathComponent("Library/Application Support/zen")),
      FirefoxFamilyBrowserAdapter(
        browserName: "Firefox",
        applicationSupportDir: home.appendingPathComponent("Library/Application Support/Firefox")),
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

  func cookieHeader(for profile: BrowserProfile, domains: [String]) -> String? {
    log.info("cookieHeader: reading cookies for \(profile.browserName) profile, domains=\(domains)")
    let src = (profile.profilePath as NSString).appendingPathComponent("cookies.sqlite")
    let tmp = "/tmp/occ-\(ProcessInfo.processInfo.globallyUniqueString).sqlite"
    guard (try? FileManager.default.copyItem(atPath: src, toPath: tmp)) != nil else {
      log.error("cookieHeader: failed to copy cookies.sqlite from \(src)")
      return nil
    }
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let filters = domains.map { domain in
      let escaped = domain.replacingOccurrences(of: "'", with: "''")
      return "host LIKE '%\(escaped)%'"
    }.joined(separator: " OR ")

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    proc.arguments = [tmp, "SELECT host, name, value FROM moz_cookies WHERE \(filters);"]

    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    guard (try? proc.run()) != nil else {
      log.error("cookieHeader: sqlite3 launch failed")
      return nil
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      log.warning("cookieHeader: sqlite3 exit code \(proc.terminationStatus)")
      return nil
    }
    guard let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    else {
      log.warning("cookieHeader: sqlite3 output not UTF-8")
      return nil
    }

    var parts: [String] = []
    for line in raw.components(separatedBy: "\n") where !line.isEmpty {
      let columns = line.components(separatedBy: "|")
      if columns.count >= 3 {
        parts.append("\(columns[1])=\(columns[2])")
      }
    }
    log.info("cookieHeader: found \(parts.count) cookies for \(domains)")
    return parts.isEmpty ? nil : parts.joined(separator: "; ")
  }

  func prepareProfileForPlaywright(from profile: BrowserProfile, at tmpDir: URL) -> Bool {
    let cookieSrc = (profile.profilePath as NSString).appendingPathComponent("cookies.sqlite")
    let cookieDst = tmpDir.appendingPathComponent("cookies.sqlite").path
    return (try? FileManager.default.copyItem(atPath: cookieSrc, toPath: cookieDst)) != nil
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
      .flatMap { resolveProfilePath(path: $0.values["Path"], isRelative: $0.values["IsRelative"] == "1") }
    if let defaultProfile, hasCookies(at: defaultProfile) { return defaultProfile }

    let namedProfiles = parser.sections
      .filter { $0.name.hasPrefix("Profile") }
      .compactMap { section in
        resolveProfilePath(path: section.values["Path"], isRelative: section.values["IsRelative"] == "1")
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