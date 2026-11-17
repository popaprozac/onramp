import ArgumentParser
import Foundation
import OnrampCore
import OnrampPlatform

/// IT's way to rerun setup without reimaging, from Self Service, Munki or Terminal.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the bootstrap now, in the foreground.",
        discussion: """
        Without a path, it fetches the bootstrap the profile points at. If onramp's daemon is still loaded, it's \
        stopped first, so the two never run at once. A run that succeeds removes onramp, as the daemon does. Any \
        other result leaves everything in place, and a stopped daemon comes back at the next boot.
        """
    )

    @Flag(help: "Show what would happen without downloading, installing or running anything.")
    var dryRun = false

    @Flag(help: "Run setupassistant and userland even if preflight would say this Mac is already set up.")
    var skipPreflight = false

    @Argument(help: "A bootstrap.json to run instead of the profile's.")
    var path: String?

    func validate() throws {
        guard dryRun || getuid() == 0 else { throw ValidationError("run needs root: sudo onramp run") }
    }

    var phases: [Phase] { skipPreflight ? [.setupassistant, .userland] : Phase.allCases }

    func run() async throws {
        let config = SystemDaemonEnvironment.currentConfig()
        let downloader = SystemDaemonEnvironment.downloader(for: config)
        let bootstrap = try await load(config, downloader)
        if dryRun {
            try await dryRun(bootstrap)
        } else {
            try await rerun(bootstrap, downloader)
        }
    }

    /// From `path`, or freshly from the profile: never the daemon's cached copy, which may be what went wrong.
    private func load(_ config: Result<Config, ConfigError>, _ downloader: Downloader) async throws -> Bootstrap {
        if let path { return try loadBootstrap(path) }
        do {
            return try await SystemDaemonEnvironment.freshBootstrap(config.get(), downloader: downloader).bootstrap
        } catch {
            print("error: \(error). Pass a bootstrap.json path to run one directly.")
            throw ExitCode.failure
        }
    }

    private func rerun(_ bootstrap: Bootstrap, _ downloader: Downloader) async throws {
        let daemon = "system/\(Identity.daemonLabel)"
        if Host.isLoaded(daemon) {
            Log.line("stopping onramp's daemon so it doesn't run alongside this; unless this run succeeds, it comes back at the next boot")
            guard await Uninstaller.launchctlBootout(daemon) else {
                Log.line("couldn't stop the daemon, so not running")
                throw ExitCode.failure
            }
        }
        let user = ConsoleUsers.current().flatMap { $0.isRealUser ? $0 : nil }
        Log.line(user.map { "userscripts will run as \($0.name)" } ?? "no one is logged in, so userscripts will fail")

        let runner = Runner(actions: SystemActions(downloader: downloader, user: user), isAppleSilicon: Host.isAppleSilicon)
        let report = await runner.run(bootstrap, phases: phases) { Log.line("\($0)") }
        let status = Status(report)
        do { try Uninstaller.writeStatus(status, failedAttempts: report.outcome == .failed ? 1 : 0) } catch { Log.line("\(error)") }
        Log.line("finished: \(status.result.rawValue)" + (status.error.map { ", \($0)" } ?? ""))
        guard status.isSuccess else { throw ExitCode.failure }

        Log.line("uninstalling onramp")
        // The daemon is already stopped, so its bootout step would only report a failure.
        _ = await Uninstaller.run(Layout.system.uninstallSteps(keepBinary: false).filter { $0 != .bootout(daemon) })
    }

    private func dryRun(_ bootstrap: Bootstrap) async throws {
        let actions = DryRunActions(preflightFiles: Set(bootstrap[.preflight].map(\.file)))
        print("dry run: nothing is downloaded, installed or run. Package receipts are read from this Mac, and every preflight script is assumed to exit non-zero (not provisioned).")
        let report = await Runner(actions: actions, isAppleSilicon: Host.isAppleSilicon).run(bootstrap, phases: phases) { result in
            let planned = await actions.takePlanned()
            print("\(result.phase.rawValue): \(result.name)")
            switch result.status {
            case .done: planned.forEach { print("  would \($0)") }
            case let .skipped(reason): print("  skip: \(reason)")
            case let .failed(reason, stopped): print("  failed: \(reason)" + (stopped ? ", stopping the run" : ""))
            }
        }
        print("outcome: \(report.outcome)")
        if report.outcome == .failed { throw ExitCode.failure }
    }
}

/// Records what a real run would do instead of doing it. Receipt lookups are real and read-only.
actor DryRunActions: Actions {
    /// A preflight exiting 0 would end the run, so assume it doesn't and show every phase.
    let preflightFiles: Set<String>
    private var planned: [String] = []

    init(preflightFiles: Set<String>) { self.preflightFiles = preflightFiles }

    /// What the current item would do, clearing it for the next item.
    func takePlanned() -> [String] {
        defer { planned = [] }
        return planned
    }

    nonisolated func installedVersion(ofPackage id: String) -> String? { Host.installedVersion(ofPackage: id) }

    func download(_ item: Item) { planned.append("download \(item.file)") }

    func installPackage(at path: String) { planned.append("install \(path)") }

    func runScript(at path: String, as context: ScriptContext, wait: Bool) -> Int32 {
        planned.append("run \(path) as \(context.rawValue)" + (wait ? "" : " without waiting"))
        return preflightFiles.contains(path) ? 1 : 0
    }
}
