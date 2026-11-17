import CryptoKit
import Foundation

public struct DownloadError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Fetches the bootstrap and item files with upstream InstallApplications' rules: keep a file that
/// already matches, otherwise download and verify, retrying up to `retries` more times.
public struct Downloader: Sendable {
    let session: URLSession
    let headers: [String: String]
    /// The only origin `headers` are sent to, normally the bootstrap's, so a credential never reaches another host.
    let headerOrigin: URL?

    /// Honors the system proxy and PAC settings. With no network, a request waits until there is one, so a Mac
    /// that slept through setup doesn't burn its retries while Wi-Fi reconnects. Once connected, a request fails
    /// if no data arrives for 60 seconds.
    public init(headers: [String: String] = [:], headerOrigin: URL? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        self.init(session: URLSession(configuration: configuration), headers: headers, headerOrigin: headerOrigin)
    }

    init(session: URLSession, headers: [String: String] = [:], headerOrigin: URL? = nil) {
        self.session = session
        self.headers = headers
        self.headerOrigin = headerOrigin
    }

    /// Fetches and decodes the bootstrap, retrying with backoff until `giveUpAfter`, so the network has time
    /// to come up during Setup Assistant. A captive portal's HTML page counts as a failed attempt.
    /// The deadline doesn't count time the Mac spends asleep, so a long nap doesn't use it up.
    public func fetchBootstrap(from url: URL, giveUpAfter limit: Duration = .seconds(30 * 60), firstDelay: Duration = .seconds(1)) async throws -> Bootstrap {
        let clock = SuspendingClock()
        let deadline = clock.now + limit
        var delay = firstDelay
        var attempts = 0
        while true {
            attempts += 1
            let lastError: String
            do {
                let (data, response) = try await session.data(for: request(url), delegate: RedirectPolicy(self))
                try Self.requireSuccess(response)
                return try Bootstrap.decode(json: data)
            } catch {
                lastError = Self.describe(error)
            }
            guard clock.now + delay < deadline else {
                throw DownloadError("gave up fetching the bootstrap after \(attempts) attempt(s), last: \(lastError)")
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(60))
        }
    }

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
            } catch {
                lastError = Self.describe(error)
            }
        }
        throw DownloadError("\(attempts) attempt(s) failed, last: \(lastError)")
    }

    /// Downloads to a staging file next to `destination`, verifies it, then renames it into place,
    /// so `destination` is never left half-written.
    private func fetch(_ url: URL, to destination: URL, hash: String, mode: Int) async throws {
        let fm = FileManager.default
        let (temp, response) = try await session.download(for: request(url), delegate: RedirectPolicy(self))
        defer { try? fm.removeItem(at: temp) }
        try Self.requireSuccess(response)

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

    private func request(_ url: URL) -> URLRequest { withHeaderRule(URLRequest(url: url)) }

    /// Adds `headers` if the request goes to `headerOrigin`, and removes them otherwise.
    func withHeaderRule(_ request: URLRequest) -> URLRequest {
        var request = request
        let send = headerOrigin.flatMap { origin in
            request.url.map { origin.scheme?.lowercased() == $0.scheme?.lowercased() && origin.host?.lowercased() == $0.host?.lowercased() && origin.port == $0.port }
        } ?? false
        for (name, value) in headers { request.setValue(send ? value : nil, forHTTPHeaderField: name) }
        return request
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DownloadError("HTTP status \(status)") }
    }

    /// URLError's description embeds the URL, which may carry a token, so use its short description.
    private static func describe(_ error: any Error) -> String {
        (error as? URLError)?.localizedDescription ?? "\(error)"
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

/// Applies the header rule again on every redirect, so a credential never follows a redirect to another origin.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let downloader: Downloader
    init(_ downloader: Downloader) { self.downloader = downloader }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        downloader.withHeaderRule(request)
    }
}
