import OnrampCore
import Testing

let goodHash = String(repeating: "a", count: 64)
let goodPackage = #"{"name": "p", "file": "/p.pkg", "type": "package", "url": "https://x/p.pkg", "hash": "\#(goodHash)", "packageid": "com.x", "version": "1.0"}"#

func issues(_ item: String, in phase: String = "userland") throws -> [ValidationIssue] {
    try decode(#"{"\#(phase)": [\#(item)]}"#).validate()
}

@Test func upstreamExampleOnlyFlagsItsPlaceholderHashes() throws {
    let found = try decode(upstreamReadmeExample).validate()
    #expect(found.count == 5)
    #expect(found.allSatisfy { $0.severity == .error && $0.message.hasPrefix("hash must be") })
}

@Test func validBootstrapHasNoIssues() throws {
    let json = #"""
    {
      "preflight": [{"name": "check", "file": "/Library/onramp/check.sh", "type": "rootscript", "url": "https://x/check.sh", "hash": "\#(goodHash.uppercased())"}],
      "setupassistant": [\#(goodPackage)],
      "userland": [
        {"name": "local", "file": "/Library/onramp/local.sh", "type": "rootscript"},
        {"name": "user", "file": "/Library/onramp/user.sh", "type": "userscript", "donotwait": true, "fail_policy": "failable"}
      ]
    }
    """#
    #expect(try decode(json).validate().isEmpty)
}

@Test func emptyBootstrapWarns() throws {
    let found = try decode("{}").validate()
    #expect(found.map(\.severity) == [.warning])
    #expect(found.first?.location == "bootstrap")
}

@Test(arguments: [
    (#"{"name": "a", "file": "a.sh", "type": "rootscript"}"#, "userland", ValidationIssue.Severity.error, "file must be an absolute path"),
    (#"{"name": " ", "file": "/a", "type": "rootscript"}"#, "userland", .error, "name is empty"),
    (#"{"name": "a", "file": "/a", "type": "rootscript", "retries": -1}"#, "userland", .error, "retries must not be negative"),
    (#"{"name": "a", "file": "/a", "type": "rootscript", "url": "https://x/a"}"#, "userland", .error, "hash is required when url is set"),
    (#"{"name": "a", "file": "/a", "type": "rootscript", "url": "https://x/a", "hash": "sha256 hash"}"#, "userland", .error, "hash must be a 64-character SHA-256 hex digest"),
    (#"{"name": "a", "file": "/a", "type": "rootscript", "url": "ftp://x/a", "hash": "\#(goodHash)"}"#, "userland", .error, "url must be an http(s) URL"),
    (#"{"name": "a", "file": "/a", "type": "rootscript", "url": "http://x/a", "hash": "\#(goodHash)"}"#, "userland", .warning, "url uses plain http"),
    (#"{"name": "p", "file": "/p.pkg", "type": "package", "packageid": "com.x", "version": "1.0"}"#, "userland", .error, "package requires url"),
    (#"{"name": "p", "file": "/p.pkg", "type": "package", "url": "https://x/p.pkg", "hash": "\#(goodHash)", "version": "1.0"}"#, "userland", .error, "package requires packageid"),
    (#"{"name": "p", "file": "/p.pkg", "type": "package", "url": "https://x/p.pkg", "hash": "\#(goodHash)", "packageid": "com.x"}"#, "userland", .error, "package requires version"),
    (#"{"name": "p", "file": "/p.pkg", "type": "package", "url": "https://x/p.pkg", "hash": "\#(goodHash)", "packageid": "com.x", "version": "1.0", "donotwait": true}"#, "userland", .warning, "donotwait has no effect on packages"),
    (#"{"name": "a", "file": "/a", "type": "rootscript", "required": true}"#, "userland", .warning, "required only applies to packages"),
    (goodPackage, "preflight", .error, "preflight only supports rootscript"),
    (#"{"name": "a", "file": "/a", "type": "rootscript", "donotwait": true}"#, "preflight", .warning, "donotwait is ignored for preflight"),
    (#"{"name": "a", "file": "/a", "type": "userscript"}"#, "setupassistant", .warning, "userscripts cannot run during Setup Assistant and will be skipped"),
    (#"{"name": "a", "file": "/a", "type": "rootscript", "wait_for_desktop": false}"#, "setupassistant", .warning, "wait_for_desktop only applies to userland"),
])
func flagsExactlyOneIssue(item: String, phase: String, severity: ValidationIssue.Severity, message: String) throws {
    let found = try issues(item, in: phase)
    #expect(found.map(\.severity) == [severity])
    #expect(found.first?.message == message)
}

@Test func waitForDesktopOnlyWorksAtTheStartOfUserland() throws {
    let boot = try decode(#"""
    {"userland": [
      {"name": "dialog", "file": "/d", "type": "userscript", "wait_for_desktop": false},
      {"name": "dock", "file": "/k", "type": "userscript"},
      {"name": "late", "file": "/l", "type": "userscript", "wait_for_desktop": false}
    ]}
    """#)
    #expect(boot.validate().map(\.description) == [#"warning: userland[2] "late": wait_for_desktop has no effect after an item that waits for the desktop"#])
    #expect(boot.userlandAroundDesktopWait.early.map(\.name) == ["dialog"])
    #expect(boot.userlandAroundDesktopWait.rest.map(\.name) == ["dock", "late"])
    #expect(boot.userland[1].waitForDesktop)  // the default
}
