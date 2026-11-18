import Foundation
import OnrampCore

/// The daemon's real environment: managed preferences, files under `layout`, launchd and the console user.
public struct SystemDaemonEnvironment: DaemonEnvironment {
    let layout: Layout
    let config: Result<Config, ConfigError>
    let downloader: Downloader
    /// This binary, which runs `wait-desktop` in the user's session.
    let executable: String

    /// From the profile, or upstream's default of 3 when the profile is invalid.
    public var maxAttempts: Int { (try? config.get())?.maxAttempts ?? 3 }

    /// Reads the config, waiting until it arrives. MDMs often install the package before the profile, and that
    /// shouldn't count as a failure. A profile that's present but invalid fails later, in `loadBootstrap`.
    public static func start(executable: String, layout: Layout = .system) async -> SystemDaemonEnvironment {
        var waiting = false
        while !configIsSet() {
            if !waiting { Log.line("waiting for a profile that sets JSONURL or Bootstrap in \(Identity.domain)") }
            waiting = true
            try? await Task.sleep(for: .seconds(15))
        }
        let config = currentConfig()
        return SystemDaemonEnvironment(layout: layout, config: config, downloader: downloader(for: config), executable: executable)
    }

    static func configIsSet() -> Bool {
        CFPreferencesAppSynchronize(Identity.domain as CFString)
        let values = Host.preferences(["JSONURL", "Bootstrap"], in: Identity.domain)
        return !values.isEmpty
    }

    /// The managed config as it is now.
    public static func currentConfig() -> Result<Config, ConfigError> {
        CFPreferencesAppSynchronize(Identity.domain as CFString)
        let values = Host.preferences(Config.keys, in: Identity.domain)
        return Result { () throws(ConfigError) in try Config(values) }
    }

    /// Sends the profile's headers to the bootstrap's origin only.
    public static func downloader(for config: Result<Config, ConfigError>) -> Downloader {
        guard case let .success(config) = config, case let .url(url) = config.source else { return Downloader() }
        return Downloader(headers: config.headers, headerOrigin: url)
    }

    /// The bootstrap the config points at, fetched now or embedded, and validated.
    public static func freshBootstrap(_ config: Config, downloader: Downloader) async throws -> Bootstrap {
        switch config.source {
        case let .embedded(bootstrap):
            return try validated(bootstrap)
        case let .url(url):
            Log.line("fetching the bootstrap from \(url.host() ?? "its host")")
            return try await validated(downloader.fetchBootstrap(from: url).bootstrap)
        }
    }

    static func validated(_ bootstrap: Bootstrap) throws -> Bootstrap {
        let issues = bootstrap.validate()
        issues.filter { $0.severity == .warning }.forEach { Log.line("\($0)") }
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else { throw PlatformError("the bootstrap has errors: \(errors.map(\.description).joined(separator: "; "))") }
        return bootstrap
    }

    var stateFile: URL { URL(fileURLWithPath: layout.stateFile) }
    var cachedBootstrap: URL { URL(fileURLWithPath: layout.cachedBootstrap) }

    public func loadState() async -> RunState { RunState.load(from: stateFile) }

    public func save(_ state: RunState) async {
        do { try state.save(to: stateFile) } catch { Log.line("could not save \(stateFile.path): \(error)") }
    }

    /// Fetched again on every launch, as InstallApplications and go-installapplications do, so a fix to the JSON takes
    /// effect on the next attempt. The last good copy is kept and used only when fetching fails or takes more than two
    /// minutes, so a restart without a network carries on. A fetched bootstrap that fails validation is an error,
    /// never a reason to fall back to the old one.
    public func loadBootstrap() async throws -> Bootstrap {
        let config = try config.get()
        guard case let .url(url) = config.source else {
            return try await Self.freshBootstrap(config, downloader: downloader)
        }
        let downloader = downloader
        let (json, fromCache) = try await Self.fetchOrCached(cached: try? Data(contentsOf: cachedBootstrap), cacheAfter: .seconds(120)) {
            Log.line("fetching the bootstrap from \(url.host() ?? "its host")")
            return try await downloader.fetchBootstrap(from: url).json
        }
        let bootstrap = try Self.validated(Bootstrap.decode(json: json))
        if !fromCache {
            // Only root may read it: item URLs can carry tokens.
            try json.write(to: cachedBootstrap, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachedBootstrap.path)
        }
        return bootstrap
    }

    /// The fetched JSON, or `cached` when fetching fails or takes longer than `cacheAfter`. With nothing cached,
    /// it waits for the fetch however long it takes.
    static func fetchOrCached(cached: Data?, cacheAfter: Duration,
                              fetch: @escaping @Sendable () async throws -> Data) async throws -> (json: Data, fromCache: Bool) {
        guard let cached else { return (try await fetch(), false) }
        let fetching = Task { try await fetch() }
        let deadline = Task {
            try await Task.sleep(for: cacheAfter)
            fetching.cancel()
        }
        defer { deadline.cancel() }
        do {
            return (try await fetching.value, false)
        } catch {
            Log.line("couldn't fetch the bootstrap in time (\(error)); using the copy saved from the last fetch")
            return (cached, true)
        }
    }

    public func actions(for user: ConsoleUser?) -> any Actions { SystemActions(downloader: downloader, user: user) }

    public func waitForUser() async -> ConsoleUser {
        Log.line("waiting for someone to log in")
        while true {
            for await user in ConsoleUsers.updates() {
                if let user, user.isRealUser { return user }
            }
        }
    }

    /// Runs `wait-desktop` in the user's session. Right after a login the session may not take commands yet,
    /// so a failure to start it is retried.
    public func waitForDesktop(of user: ConsoleUser) async {
        for attempt in 1...10 {
            let status = (try? await Spawn.run("/bin/launchctl", user.inSession(executable, ["wait-desktop"]), wait: true)) ?? -1
            switch status {
            case 0:
                Log.line("\(user.name)'s desktop is ready")
                return
            case Desktop.gaveUpExitStatus:
                Log.line("Dock or Finder never appeared for \(user.name); carrying on")
                return
            default:
                Log.line("couldn't check \(user.name)'s desktop (exit \(status)), try \(attempt) of 10")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Log.line("couldn't check \(user.name)'s desktop; carrying on")
    }

    public func log(_ message: String) async { Log.line(message) }

    /// Records the result, then removes the daemon. Only a success removes the binary too; otherwise it stays
    /// so IT can run `sudo /Library/onramp/onramp run`.
    public func finish(_ status: Status, failedAttempts: Int) async {
        do { try Uninstaller.writeStatus(status, failedAttempts: failedAttempts) } catch { Log.line("\(error)") }
        Log.line(status.isSuccess ? "uninstalling onramp" : "removing the daemon; keeping \(layout.binary) for IT to rerun")
        _ = await Uninstaller.run(layout.uninstallSteps(keepBinary: !status.isSuccess))
    }
}
