import ArgumentParser
import Foundation
import OnrampCore
import OnrampPlatform

/// launchd starts this from onramp's LaunchDaemon. People use `run` instead.
struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run as onramp's LaunchDaemon: every phase, then record the result and uninstall.",
        shouldDisplay: false
    )

    func run() async throws {
        guard getuid() == 0 else { throw ValidationError("the daemon must run as root") }
        Log.line("onramp \(Identity.version) daemon started")
        let environment = await SystemDaemonEnvironment.start(executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
        let daemon = Daemon(environment: environment, maxAttempts: environment.maxAttempts, isAppleSilicon: Host.isAppleSilicon)
        // After `finished`, the uninstall's last step has normally ended this process already.
        if await daemon.run() == .retry { throw ExitCode.failure }
    }
}

/// The daemon runs this as the logged-in user, inside their session, before userland.
struct WaitDesktopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait-desktop",
        abstract: "Wait until this user's desktop is usable: Setup Assistant closed, Dock and Finder up.",
        shouldDisplay: false
    )

    func run() async throws {
        Log.line("wait-desktop started as \(NSUserName())")
        guard await Desktop.waitUntilReady(timeout: .seconds(120)) else { throw ExitCode(Desktop.gaveUpExitStatus) }
    }
}
