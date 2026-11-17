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
