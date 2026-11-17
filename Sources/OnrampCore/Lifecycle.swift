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
    /// Items in finished phases that failed without stopping the run, because their fail_policy allowed it.
    public var failedItems: [String]

    public init(attempts: Int = 0, lastError: String? = nil, completed: [Phase] = [], running: Phase? = nil, failedItems: [String] = []) {
        self.attempts = attempts
        self.lastError = lastError
        self.completed = completed
        self.running = running
        self.failedItems = failedItems
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

    /// `failedItems` are the phase's items that failed without stopping the run.
    public mutating func complete(_ phase: Phase, failedItems: [String] = []) {
        running = nil
        if !completed.contains(phase) {
            completed.append(phase)
            self.failedItems += failedItems
        }
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
        /// Every phase ran, but items whose fail_policy let them fail did fail. Not a success.
        case completedWithFailures = "completed_with_failures"
        case alreadyProvisioned = "already_provisioned"
        case failed
    }

    /// Every key the status can write. Writing a status clears the others, so an old `Error` doesn't linger.
    public static let keys = ["Result", "Error", "FailedAttempts", "FinishedAt", "Version"]

    public let result: Result
    public let error: String?

    public init(result: Result, error: String? = nil) {
        self.result = result
        self.error = error
    }

    /// Completed, or completed with failures when any item failed without stopping the run.
    public static func completed(failedItems: [String]) -> Status {
        failedItems.isEmpty ? Status(result: .completed) : Status(result: .completedWithFailures, error: failedItems.joined(separator: "; "))
    }

    public init(_ report: Report) {
        switch report.outcome {
        case .completed: self = .completed(failedItems: report.failedItems)
        case .alreadyProvisioned: self.init(result: .alreadyProvisioned)
        case .failed: self.init(result: .failed, error: report.failedItems.last ?? "failed")
        }
    }

    /// Only a real success removes onramp entirely. Anything else leaves the binary for IT to rerun.
    public var isSuccess: Bool { result == .completed || result == .alreadyProvisioned }

    /// The keys written to /Library/Preferences/<domain>.plist.
    public func preferences(failedAttempts: Int, finishedAt: Date) -> [String: Any] {
        var values: [String: Any] = ["Result": result.rawValue, "FailedAttempts": failedAttempts, "FinishedAt": finishedAt, "Version": Identity.version]
        if let error { values["Error"] = error }
        return values
    }
}

extension Report {
    /// Each failed item as `phase "name": reason`, in order.
    public var failedItems: [String] {
        results.compactMap { result in
            guard case let .failed(reason, _) = result.status else { return nil }
            return "\(result.phase.rawValue) \"\(result.name)\": \(reason)"
        }
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

    public var binary: String { installDirectory + "/onramp" }
    public var stateFile: String { installDirectory + "/state.plist" }
    public var cachedBootstrap: String { installDirectory + "/bootstrap.json" }
    public var daemonPlist: String { "\(launchDaemons)/\(Identity.daemonLabel).plist" }

    public enum UninstallStep: Equatable, Sendable {
        case remove(String)
        /// A launchctl service target, like `system/<label>`.
        case bootout(String)
    }

    /// Upstream's cleanup order. The plist goes first, so nothing loads again even if a later step fails.
    /// The daemon's own bootout is last because it ends the daemon. Logs in /var/log/onramp are kept.
    /// With `keepBinary`, used whenever a run didn't succeed, only the daemon and its files go, so IT can still
    /// run `sudo /Library/onramp/onramp run`.
    public func uninstallSteps(keepBinary: Bool) -> [UninstallStep] {
        let files: [UninstallStep] = keepBinary ? [.remove(stateFile), .remove(cachedBootstrap)] : [.remove(installDirectory)]
        return [.remove(daemonPlist)] + files + [.bootout("system/\(Identity.daemonLabel)")]
    }
}
