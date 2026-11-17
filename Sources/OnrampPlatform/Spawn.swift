import Darwin
import Foundation

public enum Spawn {
    /// Runs `path` with `arguments`, passing on only stdin, stdout and stderr.
    ///
    /// With `wait`, returns the exit status, or 128 + n for death by signal n, as shells report it.
    /// Without `wait`, starts it in a new session and returns 0. launchd kills a job's process group when
    /// the job exits, so a script like DEPNotify needs its own session to outlive the daemon.
    public static func run(_ path: String, _ arguments: [String] = [], wait: Bool) async throws -> Int32 {
        let pid = try spawn(path, arguments, newSession: !wait)
        guard wait else {
            reap(pid) { _ in }
            return 0
        }
        return await withCheckedContinuation { continuation in
            reap(pid) { continuation.resume(returning: $0) }
        }
    }

    private static func spawn(_ path: String, _ arguments: [String], newSession: Bool) throws -> pid_t {
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | (newSession ? POSIX_SPAWN_SETSID : 0)))

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addinherit_np(&fileActions, fd) }

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, path, &fileActions, &attributes, argv, envp)
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        return pid
    }

    /// Waits for `pid` on a GCD thread, so Swift's cooperative threads never block, and so no zombie is left.
    private static func reap(_ pid: pid_t, then done: @escaping @Sendable (Int32) -> Void) {
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            let signal = status & 0x7f
            done(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        }
    }
}
