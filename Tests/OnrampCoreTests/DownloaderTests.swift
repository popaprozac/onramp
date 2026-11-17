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
    }

    struct Route: Sendable {
        var replies: [Reply]
        var hits = 0
    }

    static let routes = OSAllocatedUnfairLock<[URL: Route]>(initialState: [:])

    static func serve(_ replies: [Reply], path: String = "/file") -> URL {
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).test\(path)")!
        routes.withLock { $0[url] = Route(replies: replies) }
        return url
    }

    static func hits(_ url: URL) -> Int { routes.withLock { $0[url]?.hits ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let reply = Self.routes.withLock { routes -> Reply in
            routes[url, default: Route(replies: [])].hits += 1
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
