import CommonCrypto
import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "chromium-adapter")

// Chromium-family browsers (Chrome, Edge, Brave, ...) on macOS encrypt cookie
// values with AES-128-CBC. The key is PBKDF2(SHA1) over the browser's
// "<name> Safe Storage" password from the login Keychain. Each value is tagged
// "v10" and, since Chrome M127, prefixed with SHA256(host_key) inside the
// plaintext. Firefox cookies are plaintext, which is why only this family needs
// the crypto dance.
struct ChromiumFamilyBrowserAdapter: BrowserAdapter {
  let browserName: String
  let applicationSupportDir: URL
  let playwrightBrowserName: String  // "chrome", "msedge", ...
  let keychainService: String  // "Chrome Safe Storage", "Microsoft Edge Safe Storage", ...

  func findProfile() -> BrowserProfile? {
    log.info("findProfile: searching for \(self.browserName) profile")
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        atPath: applicationSupportDir.path)
    else {
      log.warning("findProfile: no \(self.browserName) application support dir")
      return nil
    }
    let candidates = ["Default"] + entries.filter { $0.hasPrefix("Profile ") }.sorted()
    for name in candidates {
      let dir = applicationSupportDir.appendingPathComponent(name).path
      if cookieDBPath(inProfile: dir) != nil {
        log.info("findProfile: found \(self.browserName) profile at \(dir)")
        return BrowserProfile(browserName: browserName, profilePath: dir)
      }
    }
    log.warning("findProfile: no \(self.browserName) profile with a cookie DB")
    return nil
  }

  func cookies(for profile: BrowserProfile, domains: [String]) -> [BrowserCookie] {
    log.info("cookies: reading \(profile.browserName) cookies, domains=\(domains)")
    guard let dbPath = cookieDBPath(inProfile: profile.profilePath) else { return [] }
    guard let key = decryptionKey() else {
      log.error("cookies: could not derive decryption key for \(self.browserName)")
      return []
    }
    let query =
      "SELECT host_key, name, hex(encrypted_value), value, path, expires_utc, "
      + "is_secure, is_httponly, samesite FROM cookies "
      + "WHERE \(domainFilter(domains, column: "host_key"))"
    guard let rows = SQLiteReader.rows(dbPath: dbPath, query: query) else { return [] }

    let parsed = rows.compactMap { decodeRow($0, key: key) }
    log.info("cookies: parsed \(parsed.count) cookies for \(domains)")
    return parsed
  }

  // Current Chrome keeps cookies under <profile>/Network/Cookies; older builds
  // used <profile>/Cookies.
  private func cookieDBPath(inProfile profile: String) -> String? {
    let networkPath = (profile as NSString).appendingPathComponent("Network/Cookies")
    if FileManager.default.fileExists(atPath: networkPath) { return networkPath }
    let legacyPath = (profile as NSString).appendingPathComponent("Cookies")
    if FileManager.default.fileExists(atPath: legacyPath) { return legacyPath }
    return nil
  }

  private func decodeRow(_ columns: [String], key: Data) -> BrowserCookie? {
    guard columns.count >= 9 else { return nil }
    let host = columns[0]
    let name = columns[1]
    let encryptedHex = columns[2]
    let plainValue = columns[3]

    let value: String
    if !encryptedHex.isEmpty, let blob = Data(hex: encryptedHex),
      let decrypted = decryptValue(blob, host: host, key: key)
    {
      value = decrypted
    } else if !plainValue.isEmpty {
      value = plainValue  // pre-encryption entry
    } else {
      return nil
    }

    return BrowserCookie(
      domain: host, name: name, value: value,
      path: columns[4].isEmpty ? "/" : columns[4],
      expires: chromeTimeToUnix(Double(columns[5]) ?? 0),
      isSecure: columns[6] == "1", isHTTPOnly: columns[7] == "1",
      sameSite: Self.sameSite(columns[8]))
  }

  private func decryptValue(_ blob: Data, host: String, key: Data) -> String? {
    guard blob.count > 3, String(data: blob.prefix(3), encoding: .utf8) == "v10" else {
      // v11/app-bound encryption isn't used on macOS; nothing to decrypt.
      return nil
    }
    guard let plain = aesCBCDecrypt(Data(blob.dropFirst(3)), key: key) else { return nil }
    // M127+ prepends SHA256(host_key) to the plaintext; strip it when present.
    let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
    let body = plain.prefix(32) == hostHash ? plain.dropFirst(32) : plain
    return String(data: Data(body), encoding: .utf8)
  }

  // Chrome stores expiry as microseconds since 1601-01-01; 0 means a session cookie.
  private func chromeTimeToUnix(_ micros: Double) -> Double {
    micros == 0 ? -1 : micros / 1_000_000 - 11_644_473_600
  }

  // Chromium sameSite enum: -1 unspecified, 0 none, 1 lax, 2 strict.
  private static func sameSite(_ raw: String) -> String {
    switch raw {
    case "0": return "None"
    case "2": return "Strict"
    default: return "Lax"
    }
  }

  // MARK: - Crypto

  private func decryptionKey() -> Data? {
    guard let password = keychainPassword() else { return nil }
    let salt = Data("saltysalt".utf8)
    let passwordData = Data(password.utf8)
    var derived = Data(count: 16)
    let status = derived.withUnsafeMutableBytes { keyBuffer in
      passwordData.withUnsafeBytes { passwordBuffer in
        salt.withUnsafeBytes { saltBuffer in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBuffer.bindMemory(to: Int8.self).baseAddress, passwordData.count,
            saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
            keyBuffer.bindMemory(to: UInt8.self).baseAddress, 16)
        }
      }
    }
    guard status == kCCSuccess else {
      log.error("decryptionKey: PBKDF2 failed (\(status))")
      return nil
    }
    return derived
  }

  // Reads "<name> Safe Storage" from the login Keychain via /usr/bin/security.
  // Doing it through `security` (not direct SecItem calls) keeps the prompt
  // attributed to the system tool and sidesteps hardened-runtime keychain
  // entitlements; the user authorizes once.
  private func keychainPassword() -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-w", "-s", keychainService]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    guard (try? proc.run()) != nil else {
      log.error("keychainPassword: security launch failed")
      return nil
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      log.warning("keychainPassword: security exit code \(proc.terminationStatus)")
      return nil
    }
    let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func aesCBCDecrypt(_ ciphertext: Data, key: Data) -> Data? {
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
    let outCapacity = out.count
    var moved = 0
    let status = out.withUnsafeMutableBytes { outBuffer in
      ciphertext.withUnsafeBytes { inBuffer in
        key.withUnsafeBytes { keyBuffer in
          iv.withUnsafeBytes { ivBuffer in
            CCCrypt(
              CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
              CCOptions(kCCOptionPKCS7Padding),
              keyBuffer.baseAddress, key.count,
              ivBuffer.baseAddress,
              inBuffer.baseAddress, ciphertext.count,
              outBuffer.baseAddress, outCapacity,
              &moved)
          }
        }
      }
    }
    guard status == kCCSuccess else {
      log.warning("aesCBCDecrypt: CCCrypt failed (\(status))")
      return nil
    }
    out.removeSubrange(moved..<out.count)
    return out
  }
}

extension Data {
  // Parses a hex string (sqlite3 hex() output) into bytes; nil on odd/invalid input.
  init?(hex: String) {
    guard hex.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}
