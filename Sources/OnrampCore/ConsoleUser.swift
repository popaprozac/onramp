/// Who is at the console, as macOS reports it.
public struct ConsoleUser: Equatable, Sendable {
    public let name: String
    public let uid: UInt32

    public init(name: String, uid: UInt32) {
        self.name = name
        self.uid = uid
    }

    /// A person's own session. Not the login window, not Setup Assistant's `_mbsetupuser` (uid 248),
    /// and not another system account. Upstream skips the same ones.
    public var isRealUser: Bool {
        uid >= 501 && name != "loginwindow" && name != "_mbsetupuser"
    }
}
