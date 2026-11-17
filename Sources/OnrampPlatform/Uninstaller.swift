import Foundation
import OnrampCore

public enum Uninstaller {
    /// Runs every step, even after one fails: a half-removed onramp that launchd keeps starting is the worst outcome.
    /// Returns a description of each step that failed. When the last step boots out the daemon, this process ends there.
    public static func run(_ steps: [Layout.UninstallStep], bootout: (String) async -> Bool = launchctlBootout) async -> [String] {
        var failures: [String] = []
        // Logged as they happen, since the last step ends this process before it can return.
        func failed(_ step: String) {
            failures.append(step)
            Log.line("uninstall step failed: \(step)")
        }
        for step in steps {
            switch step {
            case let .remove(path):
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do { try FileManager.default.removeItem(atPath: path) } catch { failed("remove \(path): \(error.localizedDescription)") }
            case let .bootout(target):
                if !(await bootout(target)) { failed("bootout \(target)") }
            }
        }
        return failures
    }

    public static func launchctlBootout(_ target: String) async -> Bool {
        (try? await Spawn.run("/bin/launchctl", ["bootout", target], wait: true)) == 0
    }

    /// Records how onramp finished in /Library/Preferences/<domain>.plist, where an MDM can read it. Needs root.
    /// Status keys this status doesn't set are removed, so nothing from an earlier run lingers.
    public static func writeStatus(_ status: Status, failedAttempts: Int, domain: String = Identity.domain) throws {
        let values = status.preferences(failedAttempts: failedAttempts, finishedAt: Date())
        for key in Status.keys {
            CFPreferencesSetValue(key as CFString, values[key] as CFPropertyList?, domain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            throw PlatformError("could not write the status to /Library/Preferences/\(domain).plist")
        }
    }
}
