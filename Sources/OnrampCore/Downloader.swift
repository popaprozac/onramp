import CryptoKit
import Foundation

public struct DownloadError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Fetches item files with upstream InstallApplications' rules: keep a file that already matches,
/// otherwise download and verify, retrying up to `retries` more times.
public struct Downloader: Sendable {
    let session: URLSession

    /// Honors the system proxy and PAC settings. A request fails if no data arrives for 60 seconds.
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        self.init(session: URLSession(configuration: configuration))
    }

    init(session: URLSession) { self.session = session }

    public func download(_ item: Item) async throws {
        // Never place a file we can't verify.
        guard let raw = item.url, let url = URL(string: raw), let hash = item.hash?.lowercased() else {
            throw DownloadError("url and hash are required")
        }
        let destination = URL(fileURLWithPath: item.file)
        if (try? Self.sha256(of: destination)) == hash { return }

        let attempts = 1 + max(item.retries, 0)
        var lastError = ""
        for attempt in 1...attempts {
            if attempt > 1 { try await Task.sleep(for: .seconds(item.retryWait)) }
            do {
                try await fetch(url, to: destination, hash: hash, mode: item.type == .package ? 0o644 : 0o755)
                return
            } catch let error as URLError {
                // URLError's description embeds the URL, which may carry a token.
                lastError = error.localizedDescription
            } catch {
                lastError = "\(error)"
            }
        }
        throw DownloadError("\(attempts) attempt(s) failed, last: \(lastError)")
    }

    /// Downloads to a staging file next to `destination`, verifies it, then renames it into place,
    /// so `destination` is never left half-written.
    private func fetch(_ url: URL, to destination: URL, hash: String, mode: Int) async throws {
        let fm = FileManager.default
        let (temp, response) = try await session.download(from: url)
        defer { try? fm.removeItem(at: temp) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DownloadError("HTTP status \(status)") }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = URL(fileURLWithPath: destination.path + ".part")
        try? fm.removeItem(at: staging)
        try fm.moveItem(at: temp, to: staging)
        defer { try? fm.removeItem(at: staging) }

        let actual = try Self.sha256(of: staging)
        guard actual == hash else { throw DownloadError("hash mismatch, got \(actual)") }
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staging.path)
        guard rename(staging.path, destination.path) == 0 else {
            throw DownloadError("could not move into place: \(String(cString: strerror(errno)))")
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
