import AppKit
import OnrampCore

public enum Desktop {
    /// `onramp wait-desktop`'s exit status when it gives up because Dock or Finder never appeared.
    public static let gaveUpExitStatus: Int32 = 3

    /// Waits until this session's desktop is usable: Dock and Finder are up and the per-user Setup Assistant
    /// has closed. It waits as long as Setup Assistant is open, because the user may have walked away. Without
    /// Setup Assistant, it gives up after `timeout` if Dock or Finder never appears. Returns true when ready.
    ///
    /// App launch and quit notifications drive it. A 5-second tick only checks the timeout. The timeout uses
    /// `SuspendingClock`, so time asleep doesn't count.
    @MainActor
    public static func waitUntilReady(timeout: Duration) async -> Bool {
        let center = NSWorkspace.shared.notificationCenter
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { _ in continuation.yield() }
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                continuation.yield()
            }
        }
        defer {
            observers.forEach(center.removeObserver)
            ticker.cancel()
            continuation.finish()
        }

        let clock = SuspendingClock()
        var deadline = clock.now + timeout
        var last: DesktopState?
        continuation.yield()  // check what's running right away
        for await _ in changes {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let state = DesktopState(running: running)
            if state != last { Log.line("desktop: \(state)") }
            last = state
            switch state {
            case .ready: return true
            case .setupAssistantOpen: deadline = clock.now + timeout  // the clock starts once it closes
            case .notUp: if clock.now >= deadline { return false }
            }
        }
        return false
    }
}
