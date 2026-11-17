import Foundation

public enum Log {
    /// Writes a timestamped line to stdout, unbuffered, so the log file launchd sends it to keeps up.
    public static func line(_ message: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        FileHandle.standardOutput.write(Data("\(stamp) \(message)\n".utf8))
    }
}
