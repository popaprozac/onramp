import Foundation

public struct PlatformError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

public enum Installer {
    /// Installs a package on the boot volume. installer's own log is /var/log/install.log.
    public static func install(_ path: String) async throws {
        let status = try await Spawn.run("/usr/sbin/installer", ["-pkg", path, "-target", "/"], wait: true)
        guard status == 0 else { throw PlatformError("installer exited \(status), see /var/log/install.log") }
    }
}

public enum FileSafety {
    /// Resolves symlinks in `path` and checks that only root can change the file or any directory above it.
    /// Returns the resolved path, so the caller uses exactly what was checked.
    ///
    /// The daemon installs and runs these files as root. If another user could change one, they would get root.
    public static func rootControlledPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw PlatformError("\(path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        let checked = String(cString: resolved)

        var current = checked
        while true {
            var info = stat()
            guard lstat(current, &info) == 0 else {
                throw PlatformError("\(current): \(String(cString: strerror(errno)))")
            }
            guard info.st_uid == 0, info.st_mode & 0o022 == 0 else {
                throw PlatformError("\(current) must be owned by root and not writable by group or others")
            }
            if current == "/" { return checked }
            current = (current as NSString).deletingLastPathComponent
        }
    }
}
