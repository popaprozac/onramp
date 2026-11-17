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

func log(_ message: String) {
    let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    FileHandle.standardOutput.write(Data("\(stamp) \(message)\n".utf8))
}

/// Run as the daemon: logs console-user changes and runs the real agent backup for each real user.
struct ConsoleUsersProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "console-users")

    func run() async throws {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        log("daemon started, booted \(Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)))")

        for await user in ConsoleUsers.updates() {
            guard let user else { log("console: none"); continue }
            log("console: \(user.name) uid=\(user.uid) real=\(user.isRealUser)")
            guard user.isRealUser else { continue }
            let outcome = await AgentLauncher.ensureLoaded(uid: user.uid, plist: Layout.system.agentPlist)
            log("backup for uid \(user.uid): \(outcome)")
        }
    }
}

/// Run as the agent: logs when it started, what was running, and every app launch and quit after that.
struct SessionProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "session")

    func run() async throws {
        let uid = getuid()
        let name = ConsoleUsers.current()?.name ?? "?"
        log("agent started uid=\(uid) console=\(name)")
        guard ConsoleUser(name: NSUserName(), uid: uid).isRealUser else {
            log("agent: not a real user's session, exiting")
            return
        }

        // This runs off the main thread, so NSWorkspace is set up on the main actor, whose
        // thread Swift keeps serving while this task sleeps.
        await MainActor.run {
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).sorted()
            log("running at start: \(running.joined(separator: " "))")
            let center = NSWorkspace.shared.notificationCenter
            for (notification, verb) in [(NSWorkspace.didLaunchApplicationNotification, "launched"), (NSWorkspace.didTerminateApplicationNotification, "quit")] {
                center.addObserver(forName: notification, object: nil, queue: .main) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    log("\(verb) \(app?.bundleIdentifier ?? app?.localizedName ?? "?")")
                }
            }
        }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
