import Foundation
import OnrampCore

/// The daemon's real side effects. Anything installed or run as root must be a file only root can change.
/// Userscripts run in the logged-in user's GUI session.
public struct SystemActions: Actions {
    let downloader: Downloader
    let user: ConsoleUser?

    public init(downloader: Downloader, user: ConsoleUser?) {
        self.downloader = downloader
        self.user = user
    }

    public func installedVersion(ofPackage id: String) async -> String? {
        Host.installedVersion(ofPackage: id)
    }

    public func download(_ item: Item) async throws {
        try await downloader.download(item)
    }

    public func installPackage(at path: String) async throws {
        try await Installer.install(FileSafety.rootControlledPath(path))
    }

    public func runScript(at path: String, as context: ScriptContext, wait: Bool) async throws -> Int32 {
        switch context {
        case .root:
            return try await Spawn.run(FileSafety.rootControlledPath(path), wait: wait)
        case .user:
            guard let user else { throw PlatformError("no one is logged in to run a userscript as") }
            return try await Spawn.run("/bin/launchctl", user.inSession(path), wait: wait)
        }
    }
}

extension ConsoleUser {
    /// launchctl arguments that run `command` as this user inside their GUI session, so it can show windows.
    /// `asuser` enters the session's launchd namespace as root, then `sudo -u` drops to the user.
    public func inSession(_ command: String, _ arguments: [String] = []) -> [String] {
        ["asuser", "\(uid)", "/usr/bin/sudo", "-H", "-u", name, "--", command] + arguments
    }
}
