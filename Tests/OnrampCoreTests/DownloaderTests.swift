import CryptoKit
import Foundation
@testable import OnrampCore
import os
import Testing

/// Serves canned replies per URL, in order, and counts requests. Each test gets its own URLs, so tests can run in parallel.
final class StubURLProtocol: URLProtocol {
    enum Reply: Sendable {
        case body(String, status: Int = 200)
        case failure(URLError.Code)
        case redirect(URL)
    }

    struct Route: Sendable {
        var replies: [Reply]
        /// The headers of each request, in order.
        var requests: [[String: String]] = []
    }

    static let routes = OSAllocatedUnfairLock<[URL: Route]>(initialState: [:])

    /// A fresh host per call, so tests don't share routes.
    static func serve(_ replies: [Reply], path: String = "/file") -> URL {
        serve(replies, at: URL(string: "https://\(UUID().uuidString.lowercased()).test\(path)")!)
    }

    @discardableResult
    static func serve(_ replies: [Reply], at url: URL) -> URL {
        routes.withLock { $0[url] = Route(replies: replies) }
        return url
    }

    static func hits(_ url: URL) -> Int { requests(url).count }
    static func requests(_ url: URL) -> [[String: String]] { routes.withLock { $0[url]?.requests ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let headers = request.allHTTPHeaderFields ?? [:]
        let reply = Self.routes.withLock { routes -> Reply in
            routes[url, default: Route(replies: [])].requests.append(headers)
            return routes[url]!.replies.isEmpty ? .failure(.resourceUnavailable) : routes[url]!.replies.removeFirst()
        }
        switch reply {
        case let .body(body, status):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            // Real URLSession errors carry the URL like this, and it shows when the error is interpolated.
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString]))
        case let .redirect(target):
            // Keep every header, the worst case, so the tests show that onramp's redirect policy is what strips them.
            var next = request
            next.url = target
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
    }
}

let stubbedDownloader: Downloader = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return Downloader(session: URLSession(configuration: configuration))
}()

func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func downloadItem(_ file: URL, from url: URL, hash: String? = sha256("hello"), type: String = "package", retries: Int = 0, retryWait: Int = 0) throws -> Item {
    let hashField = hash.map { #", "hash": "\#($0)""# } ?? ""
    let json = #"{"name": "x", "file": "\#(file.path)", "type": "\#(type)", "url": "\#(url.absoluteString)"\#(hashField), "retries": \#(retries), "retrywait": \#(retryWait)}"#
    return try JSONDecoder().decode(Item.self, from: Data(json.utf8))
}

/// A fresh directory for one test. The caller removes it.
func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onramp-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func contents(_ file: URL) -> String? { try? String(contentsOf: file, encoding: .utf8) }

@Test(arguments: [("package", 0o644), ("rootscript", 0o755), ("userscript", 0o755)])
func downloadsVerifiesAndPlacesTheFile(type: String, mode: Int) async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("sub/a")
    let url = StubURLProtocol.serve([.body("hello")])

    try await stubbedDownloader.download(downloadItem(file, from: url, hash: sha256("hello").uppercased(), type: type))

    #expect(contents(file) == "hello")
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == mode)
    #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["a"])
    #expect(StubURLProtocol.hits(url) == 1)
}

@Test func keepsAnExistingFileThatMatches() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a")
    try "hello".write(to: file, atomically: true, encoding: .utf8)
    let url = StubURLProtocol.serve([])

    try await stubbedDownloader.download(downloadItem(file, from: url))

    #expect(StubURLProtocol.hits(url) == 0)
}

@Test func replacesAnExistingFileThatDoesNotMatch() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a")
    try "stale".write(to: file, atomically: true, encoding: .utf8)
    let url = StubURLProtocol.serve([.body("hello")])

    try await stubbedDownloader.download(downloadItem(file, from: url))

    #expect(contents(file) == "hello")
}

@Test func retriesAfterRetryWaitUntilTheHashMatches() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a")
    let url = StubURLProtocol.serve([.body("corrupt"), .body("hello")])

    let elapsed = try await ContinuousClock().measure {
        try await stubbedDownloader.download(downloadItem(file, from: url, retries: 1, retryWait: 1))
    }

    #expect(contents(file) == "hello")
    #expect(StubURLProtocol.hits(url) == 2)
    #expect(elapsed >= .seconds(1))
}

@Test func givesUpAfterRetriesAndLeavesTheOldFileAlone() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a")
    try "stale".write(to: file, atomically: true, encoding: .utf8)
    let url = StubURLProtocol.serve([.body("corrupt"), .body("hello", status: 404), .failure(.timedOut)], path: "/file?token=secret")

    let error = await #expect(throws: DownloadError.self) {
        try await stubbedDownloader.download(downloadItem(file, from: url, retries: 2))
    }

    #expect(StubURLProtocol.hits(url) == 3)
    #expect(error?.description.hasPrefix("3 attempt(s) failed") == true)
    #expect(error?.description.contains("secret") == false)
    #expect(contents(file) == "stale")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a"])
}

@Test func refusesToDownloadWithoutAHash() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = StubURLProtocol.serve([.body("hello")])

    await #expect(throws: DownloadError.self) {
        try await stubbedDownloader.download(downloadItem(dir.appendingPathComponent("a"), from: url, hash: nil))
    }
    #expect(StubURLProtocol.hits(url) == 0)
}

func downloader(headers: [String: String], origin: URL) -> Downloader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return Downloader(session: URLSession(configuration: configuration), headers: headers, headerOrigin: origin)
}

let token = ["Authorization": "Bearer secret"]

@Test(arguments: [
    ("https://HOST.test/a.pkg", true),          // the origin itself; host case is ignored
    ("https://other-HOST.test/a.pkg", false),   // another host
    ("http://HOST.test/a.pkg", false),          // same host, plain http
    ("https://HOST.test:8443/a.pkg", false),    // same host, another port
])
func sendsHeadersOnlyToTheirOrigin(template: String, sent: Bool) async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = UUID().uuidString.lowercased()
    let origin = URL(string: "https://\(host.uppercased()).test/")!
    let url = StubURLProtocol.serve([.body("hello")], at: URL(string: template.replacingOccurrences(of: "HOST", with: host))!)

    try await downloader(headers: token, origin: origin).download(downloadItem(dir.appendingPathComponent("a"), from: url))

    #expect(StubURLProtocol.requests(url).first?["Authorization"] == (sent ? "Bearer secret" : nil))
}

@Test(arguments: [true, false])
func redirectsKeepHeadersOnlyWithinTheirOrigin(sameOrigin: Bool) async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let origin = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
    let target = StubURLProtocol.serve([.body("hello")], at: sameOrigin ? origin.appendingPathComponent("moved") : StubURLProtocol.serve([]))
    let start = StubURLProtocol.serve([.redirect(target)], at: origin.appendingPathComponent("start"))

    try await downloader(headers: token, origin: origin).download(downloadItem(dir.appendingPathComponent("a"), from: start))

    #expect(StubURLProtocol.requests(start).first?["Authorization"] == "Bearer secret")
    #expect(StubURLProtocol.requests(target).first?["Authorization"] == (sameOrigin ? "Bearer secret" : nil))
}

@Test func retriesFetchingTheBootstrapUntilItDecodes() async throws {
    let url = StubURLProtocol.serve([.failure(.notConnectedToInternet), .body("<html>captive portal</html>"), .body(#"{"userland": []}"#)])

    let bootstrap = try await downloader(headers: token, origin: url).fetchBootstrap(from: url, firstDelay: .milliseconds(10))

    #expect(bootstrap.userland.isEmpty)
    #expect(StubURLProtocol.requests(url).map { $0["Authorization"] } == ["Bearer secret", "Bearer secret", "Bearer secret"])
}

@Test func givesUpFetchingTheBootstrapAtTheDeadline() async throws {
    let url = StubURLProtocol.serve([], path: "/bootstrap.json?token=secret")

    let started = ContinuousClock.now
    let error = await #expect(throws: DownloadError.self) {
        try await stubbedDownloader.fetchBootstrap(from: url, giveUpAfter: .milliseconds(300), firstDelay: .milliseconds(20))
    }

    #expect(ContinuousClock.now - started < .seconds(1))
    // Delays of 20, 40, 80 and 160 ms fit about 4 attempts in 300 ms. Without backoff it would be about 15.
    #expect((3...6).contains(StubURLProtocol.hits(url)))
    #expect(error?.description.hasPrefix("gave up fetching the bootstrap after") == true)
    #expect(error?.description.contains("secret") == false)
}
