import Foundation

/// Kept in state.plist between daemon launches. A restart picks up where the last launch left off, and a
/// bootstrap that keeps failing, or keeps getting cut off, stops after MaxAttempts instead of looping forever.
public struct RunState: Codable, Equatable, Sendable {
    /// Failed or cut-off phases, plus failures before any phase (config, fetch, validation).
    public var attempts: Int
    public var lastError: String?
    /// Finished phases. A restart skips them.
    public var completed: [Phase]
    /// The phase running now. If it's still set at launch, the last launch was cut off part-way.
    public var running: Phase?

    public init(attempts: Int = 0, lastError: String? = nil, completed: [Phase] = [], running: Phase? = nil) {
        self.attempts = attempts
        self.lastError = lastError
        self.completed = completed
        self.running = running
    }

    /// The phases still to run, in order.
    public var remaining: [Phase] { Phase.allCases.filter { !completed.contains($0) } }

    /// Called at launch. A phase that was still running was cut off by a crash, restart or power loss, which
    /// counts as a failed attempt. A restart between phases, such as while waiting for a login, costs nothing.
    /// Returns a failed status when the attempts are used up.
    public mutating func resume(maxAttempts: Int) -> Status? {
        if let phase = running {
            attempts += 1
            lastError = "\(phase.rawValue) was cut off by a crash, restart or power loss"
            running = nil
        }
        return attempts >= maxAttempts ? Status(result: .failed, error: lastError) : nil
    }

    public mutating func start(_ phase: Phase) { running = phase }

    public mutating func complete(_ phase: Phase) {
        running = nil
        if !completed.contains(phase) { completed.append(phase) }
    }

    /// A failed phase, or a failure before any phase. Returns the status to record before uninstalling when the
    /// attempts are used up, or nil to exit non-zero so launchd tries again.
    public mutating func fail(_ error: String, maxAttempts: Int) -> Status? {
        attempts += 1
        lastError = error
        running = nil
        return attempts >= maxAttempts ? Status(result: .failed, error: error) : nil
    }

    /// Reads state.plist, or starts fresh if it's missing or unreadable.
    public static func load(from file: URL) -> RunState {
        (try? Data(contentsOf: file)).flatMap { try? PropertyListDecoder().decode(RunState.self, from: $0) } ?? RunState()
    }

    /// Writes state.plist so only its owner, root, can read it.
    public func save(to file: URL) throws {
        try PropertyListEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// How onramp finished, for the MDM to read from the status plist.
public struct Status: Equatable, Sendable {
    public enum Result: String, Sendable {
        case completed
        case alreadyProvisioned = "already_provisioned"
        case failed
    }

    public let result: Result
    public let error: String?

    public init(result: Result, error: String? = nil) {
        self.result = result
        self.error = error
    }

    public init(_ report: Report) {
        switch report.outcome {
        case .completed: self.init(result: .completed)
        case .alreadyProvisioned: self.init(result: .alreadyProvisioned)
        case .failed:
            guard let last = report.results.last, case let .failed(reason, _) = last.status else {
                self.init(result: .failed, error: "failed")
                return
            }
            self.init(result: .failed, error: "\(last.phase.rawValue) \"\(last.name)\": \(reason)")
        }
    }

    /// The keys written to /Library/Preferences/<domain>.plist.
    public func preferences(failedAttempts: Int, finishedAt: Date) -> [String: Any] {
        var values: [String: Any] = ["Result": result.rawValue, "FailedAttempts": failedAttempts, "FinishedAt": finishedAt, "Version": Identity.version]
        if let error { values["Error"] = error }
        return values
    }
}

/// Where onramp is installed. Tests point it at a temporary directory.
public struct Layout: Sendable {
    public var installDirectory: String
    public var launchDaemons: String

    public static let system = Layout(installDirectory: "/Library/onramp", launchDaemons: "/Library/LaunchDaemons")

    public init(installDirectory: String, launchDaemons: String) {
        self.installDirectory = installDirectory
        self.launchDaemons = launchDaemons
    }

    public var stateFile: String { installDirectory + "/state.plist" }
    public var daemonPlist: String { "\(launchDaemons)/\(Identity.daemonLabel).plist" }

    public enum UninstallStep: Equatable, Sendable {
        case remove(String)
        /// A launchctl service target, like `system/<label>`.
        case bootout(String)
    }

    /// Upstream's cleanup order. The plist goes first, so nothing loads again even if a later step fails.
    /// The daemon's own bootout is last because it ends this process. Logs in /var/log/onramp are kept.
    public func uninstallSteps() -> [UninstallStep] {
        [.remove(daemonPlist), .remove(installDirectory), .bootout("system/\(Identity.daemonLabel)")]
    }
}
