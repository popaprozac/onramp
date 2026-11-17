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
        var values: [String: Any]
        while true {
            CFPreferencesAppSynchronize(Identity.domain as CFString)
            values = Host.preferences(Config.keys, in: Identity.domain)
            if values["JSONURL"] != nil || values["Bootstrap"] != nil { break }
            if !waiting { Log.line("waiting for a profile that sets JSONURL or Bootstrap in \(Identity.domain)") }
            waiting = true
            try? await Task.sleep(for: .seconds(15))
        }
        let config = Result { () throws(ConfigError) in try Config(values) }
        var downloader = Downloader()
        if case let .success(config) = config, case let .url(url) = config.source {
            downloader = Downloader(headers: config.headers, headerOrigin: url)
        }
        return SystemDaemonEnvironment(layout: layout, config: config, downloader: downloader, executable: executable)
    }

    var stateFile: URL { URL(fileURLWithPath: layout.stateFile) }
    var cachedBootstrap: URL { URL(fileURLWithPath: layout.installDirectory + "/bootstrap.json") }

    public func loadState() async -> RunState { RunState.load(from: stateFile) }

    public func save(_ state: RunState) async {
        do { try state.save(to: stateFile) } catch { Log.line("could not save \(stateFile.path): \(error)") }
    }

    /// A downloaded bootstrap is cached, as upstream does, so a restart uses the same file without the network.
    public func loadBootstrap() async throws -> Bootstrap {
        switch try config.get().source {
        case let .embedded(bootstrap):
            return try Self.validated(bootstrap)
        case let .url(url):
            if let json = try? Data(contentsOf: cachedBootstrap), let cached = try? Bootstrap.decode(json: json) {
                Log.line("using the bootstrap saved at \(cachedBootstrap.path)")
                return try Self.validated(cached)
            }
            Log.line("fetching the bootstrap from \(url.host() ?? "its host")")
            let (bootstrap, json) = try await downloader.fetchBootstrap(from: url)
            _ = try Self.validated(bootstrap)
            // Only root may read it: item URLs can carry tokens.
            try json.write(to: cachedBootstrap, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachedBootstrap.path)
            return bootstrap
        }
    }

    static func validated(_ bootstrap: Bootstrap) throws -> Bootstrap {
        let issues = bootstrap.validate()
        issues.filter { $0.severity == .warning }.forEach { Log.line("\($0)") }
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else { throw PlatformError("the bootstrap has errors: \(errors.map(\.description).joined(separator: "; "))") }
        return bootstrap
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

    public func finish(_ status: Status, failedAttempts: Int) async {
        do {
            try Uninstaller.writeStatus(status.preferences(failedAttempts: failedAttempts, finishedAt: Date()))
        } catch {
            Log.line("\(error)")
        }
        Log.line("uninstalling onramp")
        _ = await Uninstaller.run(layout.uninstallSteps())
    }
}
