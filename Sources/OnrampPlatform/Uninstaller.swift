import Foundation
import OnrampCore

public enum Uninstaller {
    /// Runs every step, even after one fails: a half-removed onramp that launchd keeps starting is the worst outcome.
    /// Returns a description of each step that failed. When the last step boots out the daemon, this process ends there.
    public static func run(_ steps: [Layout.UninstallStep], bootout: (String) async -> Bool = launchctlBootout) async -> [String] {
        var failures: [String] = []
        for step in steps {
            switch step {
            case let .remove(path):
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do { try FileManager.default.removeItem(atPath: path) } catch { failures.append("remove \(path): \(error.localizedDescription)") }
            case let .bootout(target):
                if !(await bootout(target)) { failures.append("bootout \(target)") }
            }
        }
        return failures
    }

    public static func launchctlBootout(_ target: String) async -> Bool {
        (try? await Spawn.run("/bin/launchctl", ["bootout", target], wait: true)) == 0
    }

    /// Records how onramp finished in /Library/Preferences/<domain>.plist, where an MDM can read it. Needs root.
    public static func writeStatus(_ values: [String: Any], domain: String = Identity.domain) throws {
        for (key, value) in values {
            CFPreferencesSetValue(key as CFString, value as CFPropertyList, domain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            throw PlatformError("could not write the status to /Library/Preferences/\(domain).plist")
        }
    }
}
