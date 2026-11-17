/// What the daemon needs from the system. The real one is in OnrampPlatform; tests use a fake.
public protocol DaemonEnvironment: Sendable {
    func loadState() async -> RunState
    func save(_ state: RunState) async
    /// The validated bootstrap: cached by an earlier launch, fetched, or embedded in the profile.
    func loadBootstrap() async throws -> Bootstrap
    /// The real side effects. Userscripts run as `user`, once someone is logged in.
    func actions(for user: ConsoleUser?) -> any Actions
    /// Waits for someone to log in, for as long as it takes.
    func waitForUser() async -> ConsoleUser
    /// Waits until `user`'s desktop is usable: the per-user Setup Assistant closed, Dock and Finder up.
    func waitForDesktop(of user: ConsoleUser) async
    func log(_ message: String) async
    /// Records `status` for the MDM and uninstalls onramp. The real one ends the process.
    func finish(_ status: Status, failedAttempts: Int) async
}

/// The daemon's whole job, from launch to uninstall, resuming wherever the last launch stopped.
public struct Daemon: Sendable {
    public enum Exit: Equatable, Sendable {
        /// onramp recorded its status and uninstalled itself.
        case finished(Status)
        /// An attempt failed. Exit non-zero so launchd starts the daemon again.
        case retry
    }

    let environment: any DaemonEnvironment
    let maxAttempts: Int
    let isAppleSilicon: Bool

    public init(environment: any DaemonEnvironment, maxAttempts: Int, isAppleSilicon: Bool) {
        self.environment = environment
        self.maxAttempts = maxAttempts
        self.isAppleSilicon = isAppleSilicon
    }

    public func run() async -> Exit {
        var state = await environment.loadState()
        if let status = state.resume(maxAttempts: maxAttempts) { return await finish(status, state) }
        await environment.save(state)

        let bootstrap: Bootstrap
        do {
            bootstrap = try await environment.loadBootstrap()
        } catch {
            return await fail("\(error)", &state)
        }

        for phase in state.remaining {
            var user: ConsoleUser?
            if phase == .userland {
                await runner(for: nil).prefetch(bootstrap, phase: .userland)
                let someone = await environment.waitForUser()
                await environment.log("\(someone.name) (uid \(someone.uid)) is logged in")
                await environment.waitForDesktop(of: someone)
                user = someone
            }
            // Marked as running only now, so a restart while waiting for a login doesn't count as an attempt.
            state.start(phase)
            await environment.save(state)
            await environment.log("starting \(phase.rawValue)")

            let report = await runner(for: user).run(bootstrap, phases: [phase]) { await environment.log("\($0)") }
            switch report.outcome {
            case .completed:
                state.complete(phase, failedItems: report.failedItems)
                await environment.save(state)
            case .alreadyProvisioned:
                state.complete(phase)
                return await finish(Status(report), state)
            case .failed:
                return await fail(Status(report).error ?? "\(phase.rawValue) failed", &state)
            }
        }
        return await finish(.completed(failedItems: state.failedItems), state)
    }

    private func runner(for user: ConsoleUser?) -> Runner {
        Runner(actions: environment.actions(for: user), isAppleSilicon: isAppleSilicon)
    }

    private func fail(_ error: String, _ state: inout RunState) async -> Exit {
        let status = state.fail(error, maxAttempts: maxAttempts)
        await environment.save(state)
        await environment.log("attempt \(state.attempts) of \(maxAttempts) failed: \(error)")
        guard let status else { return .retry }
        return await finish(status, state)
    }

    private func finish(_ status: Status, _ state: RunState) async -> Exit {
        await environment.save(state)
        await environment.log("finished: \(status.result.rawValue)" + (status.error.map { ", \($0)" } ?? ""))
        await environment.finish(status, failedAttempts: state.attempts)
        return .finished(status)
    }
}

/// Whether a user's desktop is ready for onramp's userland, from the apps running in the session.
public enum DesktopState: Equatable, Sendable {
    case ready
    /// The per-user Setup Assistant is on screen. Wait as long as it takes, since the user may have walked away.
    case setupAssistantOpen
    /// No Setup Assistant, but Dock or Finder isn't up yet.
    case notUp

    public init(running bundleIDs: Set<String>) {
        if bundleIDs.contains("com.apple.SetupAssistant") {
            self = .setupAssistantOpen
        } else if bundleIDs.contains("com.apple.dock"), bundleIDs.contains("com.apple.finder") {
            self = .ready
        } else {
            self = .notUp
        }
    }
}
