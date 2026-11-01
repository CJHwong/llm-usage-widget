import Foundation
import OSLog

private let log = Logger(subsystem: "com.llmwidget", category: "process")

// Result of a child process the app itself bounded.
struct CommandResult: Sendable {
  let status: Int32
  let stdout: Data
  let stderr: Data
  let timedOut: Bool
}

// Carries the process and its pipes into the waiting queue. @unchecked because
// Process is not Sendable, but every mutable field is guarded here or owned by
// the single queue that reads it.
private final class ProcessHandle: @unchecked Sendable {
  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()
  let stdoutData = DataBox()
  let stderrData = DataBox()
}

private final class DataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func set(_ value: Data) { lock.withLock { data = value } }
  var value: Data { lock.withLock { data } }
}

enum ProcessRunner {
  // curl's --max-time is advisory: a stalled HTTP/2 read ignored it for 11 hours
  // in the field. This runner owns the deadline. It drains both pipes while the
  // child runs, so a full pipe cannot stall it, and it escalates terminate to
  // SIGKILL. Never call it on a cooperative thread; the caller hops to a queue.
  static func run(
    executable: String, arguments: [String], timeout: TimeInterval
  ) -> CommandResult {
    let h = ProcessHandle()
    h.process.executableURL = URL(fileURLWithPath: executable)
    h.process.arguments = arguments
    h.process.standardOutput = h.stdout
    h.process.standardError = h.stderr
    do {
      try h.process.run()
    } catch {
      log.error("run: launch failed for \(executable)")
      return CommandResult(status: -1, stdout: Data(), stderr: Data(), timedOut: false)
    }
    // The parent must close its own write ends or readDataToEndOfFile never
    // sees EOF while the child lives.
    try? h.stdout.fileHandleForWriting.close()
    try? h.stderr.fileHandleForWriting.close()

    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      h.process.waitUntilExit()
      h.stdoutData.set(h.stdout.fileHandleForReading.readDataToEndOfFile())
      h.stderrData.set(h.stderr.fileHandleForReading.readDataToEndOfFile())
      finished.signal()
    }

    var timedOut = false
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      log.warning(
        "run: \(executable) exceeded \(Int(timeout))s, terminating pid \(h.process.processIdentifier)")
      h.process.terminate()
      if finished.wait(timeout: .now() + 1) == .timedOut {
        kill(h.process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 1)
      }
    }
    return CommandResult(
      status: h.process.terminationStatus,
      stdout: h.stdoutData.value,
      stderr: h.stderrData.value,
      timedOut: timedOut)
  }
}
