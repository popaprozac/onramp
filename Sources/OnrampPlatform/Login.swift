import Foundation
import OnrampCore
import os
import SystemConfiguration

public enum ConsoleUsers {
    public static func current() -> ConsoleUser? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String? else { return nil }
        return ConsoleUser(name: name, uid: uid)
    }

    /// The console user now, then again each time it changes. configd pushes the changes; nothing polls.
    /// Only the newest value is kept for a slow reader, since it's a state, not a list of events.
    public static func updates() -> AsyncStream<ConsoleUser?> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let context = Unmanaged.passRetained(Subscription(continuation))
            var storeContext = SCDynamicStoreContext(version: 0, info: context.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                Unmanaged<Subscription>.fromOpaque(info).takeUnretainedValue().continuation.yield(ConsoleUsers.current())
            }
            guard let store = SCDynamicStoreCreate(nil, Identity.domain as CFString, callback, &storeContext),
                  SCDynamicStoreSetNotificationKeys(store, [SCDynamicStoreKeyCreateConsoleUser(nil)] as CFArray, nil) else {
                context.release()
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "\(Identity.domain).console-user")
            SCDynamicStoreSetDispatchQueue(store, queue)
            continuation.yield(current())

            let held = Held(store, context)
            continuation.onTermination = { _ in queue.async { held.stop() } }
        }
    }

    /// How many subscriptions are alive, so a test can check that cancelling one frees it.
    static let liveSubscriptions = OSAllocatedUnfairLock(initialState: 0)

    private final class Subscription {
        let continuation: AsyncStream<ConsoleUser?>.Continuation
        init(_ continuation: AsyncStream<ConsoleUser?>.Continuation) {
            self.continuation = continuation
            ConsoleUsers.liveSubscriptions.withLock { $0 += 1 }
        }
        deinit { ConsoleUsers.liveSubscriptions.withLock { $0 -= 1 } }
    }

    /// Only touched on the store's own queue.
    private final class Held: @unchecked Sendable {
        let store: SCDynamicStore
        let context: Unmanaged<Subscription>
        init(_ store: SCDynamicStore, _ context: Unmanaged<Subscription>) {
            self.store = store
            self.context = context
        }

        func stop() {
            SCDynamicStoreSetDispatchQueue(store, nil)
            context.release()
        }
    }
}

public enum AgentLauncher {
    public enum Outcome: Equatable, Sendable {
        /// launchd already had the agent loaded, normally because it started it at login.
        case alreadyLoaded
        case bootstrapped
        case failed
    }

    /// Makes sure the agent is loaded in `uid`'s GUI session. It's the backup for when launchd didn't start it
    /// at login, for example because onramp was installed after the user logged in.
    ///
    /// It checks first, so on a normal login it does nothing. Right after a login the session may not accept
    /// a bootstrap yet, or launchd may load the agent at the same moment, so a failure is retried after `delay`.
    public static func ensureLoaded(uid: UInt32, plist: String, tries: Int = 10, delay: Duration = .seconds(1),
                                    launchctl: ([String]) async -> Int32 = runLaunchctl) async -> Outcome {
        let service = "gui/\(uid)/\(Identity.agentLabel)"
        for attempt in 1...max(tries, 1) {
            if attempt > 1 { try? await Task.sleep(for: delay) }
            if await launchctl(["print", service]) == 0 { return .alreadyLoaded }
            if await launchctl(["bootstrap", "gui/\(uid)", plist]) == 0 { return .bootstrapped }
        }
        return .failed
    }

    public static func runLaunchctl(_ arguments: [String]) async -> Int32 {
        (try? await Spawn.run("/bin/launchctl", arguments, wait: true, quiet: true)) ?? -1
    }
}
