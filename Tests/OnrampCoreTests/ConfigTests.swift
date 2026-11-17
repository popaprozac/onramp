import Foundation
import OnrampCore
import Testing

@Test func readsAJSONURLConfig() throws {
    let config = try Config(["JSONURL": "https://example.test/bootstrap.json", "Headers": ["Authorization": "Bearer x"], "MaxAttempts": 5])
    guard case let .url(url) = config.source else { Issue.record("expected a URL source"); return }
    #expect(url.absoluteString == "https://example.test/bootstrap.json")
    #expect(config.headers == ["Authorization": "Bearer x"])
    #expect(config.maxAttempts == 5)
}

@Test func readsAnEmbeddedBootstrapWithPlistTypes() throws {
    // Profiles carry booleans and integers as plist types, not JSON.
    let item: [String: Any] = ["name": "a", "file": "/a.sh", "type": "userscript", "donotwait": true, "retries": 2]
    let config = try Config(["Bootstrap": ["userland": [item]]])
    guard case let .embedded(bootstrap) = config.source else { Issue.record("expected an embedded source"); return }
    #expect(bootstrap.userland.first?.doNotWait == true)
    #expect(bootstrap.userland.first?.retries == 2)
    #expect(config.headers.isEmpty)
    #expect(config.maxAttempts == 3)
}

@Test func rejectsBadConfig() {
    let cases: [([String: Any], String)] = [
        ([:], "set JSONURL or Bootstrap"),
        (["JSONURL": "https://x/b.json", "Bootstrap": [String: Any]()], "set JSONURL or Bootstrap, not both"),
        (["JSONURL": "http://x/b.json"], "JSONURL must be an https URL"),
        (["JSONURL": "not a url"], "JSONURL must be an https URL"),
        (["JSONURL": 42], "JSONURL must be an https URL"),
        (["Bootstrap": "{}"], "Bootstrap must be a dictionary with bootstrap.json's keys and values"),
        (["Bootstrap": ["userland": [["name": "a", "file": "/a", "type": "rootscript", "when": Date()]]]], "Bootstrap must be a dictionary with bootstrap.json's keys and values"),
        (["Bootstrap": ["userland": [["name": "a", "type": "rootscript"]]]], "Bootstrap: userland[0].file: missing required key"),
        (["JSONURL": "https://x/b.json", "Headers": ["Authorization": 1]], "Headers must be a dictionary of strings"),
        (["Bootstrap": [String: Any](), "Headers": ["Authorization": "x"]], "Headers needs JSONURL, because they are only sent to its host"),
        (["JSONURL": "https://x/b.json", "MaxAttempts": 0], "MaxAttempts must be a whole number, at least 1"),
        (["JSONURL": "https://x/b.json", "MaxAttempts": "3"], "MaxAttempts must be a whole number, at least 1"),
    ]
    for (values, message) in cases {
        let error = #expect(throws: ConfigError.self, "\(values)") { try Config(values) }
        #expect(error?.description == message)
    }
}
