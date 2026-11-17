import AppKit
import ArgumentParser
import OnrampCore
import OnrampPlatform

/// Diagnostics for login timing. Each prints timestamped lines, unbuffered so a launchd log file keeps up.
struct Debug: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnostics for login detection.",
        shouldDisplay: false,
        subcommands: [ConsoleUsersProbe.self, SessionProbe.self]
    )
}

/// Logs every console-user change, the way the daemon sees them, to watch logins.
struct ConsoleUsersProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "console-users")

    func run() async throws {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        Log.line("watching console users, booted \(Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)))")

        for await user in ConsoleUsers.updates() {
            guard let user else { Log.line("console: none"); continue }
            Log.line("console: \(user.name) uid=\(user.uid) real=\(user.isRealUser)")
        }
    }
}

/// Run in a user's session: logs when it started, what was running, and every app launch and quit after that.
struct SessionProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "session")

    func run() async throws {
        let uid = getuid()
        let name = ConsoleUsers.current()?.name ?? "?"
        Log.line("agent started uid=\(uid) console=\(name)")
        guard ConsoleUser(name: NSUserName(), uid: uid).isRealUser else {
            Log.line("agent: not a real user's session, exiting")
            return
        }

        // This runs off the main thread, so NSWorkspace is set up on the main actor, whose
        // thread Swift keeps serving while this task sleeps.
        await MainActor.run {
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).sorted()
            Log.line("running at start: \(running.joined(separator: " "))")
            let center = NSWorkspace.shared.notificationCenter
            for (notification, verb) in [(NSWorkspace.didLaunchApplicationNotification, "launched"), (NSWorkspace.didTerminateApplicationNotification, "quit")] {
                center.addObserver(forName: notification, object: nil, queue: .main) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    Log.line("\(verb) \(app?.bundleIdentifier ?? app?.localizedName ?? "?")")
                }
            }
        }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
