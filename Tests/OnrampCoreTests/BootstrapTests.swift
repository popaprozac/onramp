import Foundation
import OnrampCore
import Testing

/// The example bootstrap.json from the upstream InstallApplications README
/// (github.com/macadmins/installapplications, Apache-2.0), verbatim, including its placeholder hashes.
let upstreamReadmeExample = #"""
{
  "preflight": [
    {
      "donotwait": false,
      "file": "/Library/installapplications/preflight_script.py",
      "hash": "sha256 hash",
      "name": "Example Preflight Script",
      "type": "rootscript",
      "url": "https://domain.tld/preflight_script.py",
      "retries": 5,
      "retrywait": 10
    }
  ],
  "setupassistant": [
    {
      "file": "/Library/installapplications/setupassistant.pkg",
      "url": "https://domain.tld/setupassistant.pkg",
      "packageid": "com.package.setupassistant",
      "version": "1.0",
      "hash": "sha256 hash",
      "name": "setupassistant Package Name",
      "type": "package",
      "retries": 5,
      "retrywait": 10
    }
  ],
  "userland": [
    {
      "file": "/Library/installapplications/userland.pkg",
      "url": "https://domain.tld/userland.pkg",
      "packageid": "com.package.userland",
      "version": "1.0",
      "hash": "sha256 hash",
      "name": "Stage 1 Package Name",
      "skip_if": "x86_64",
      "type": "package",
      "retries": 5,
      "retrywait": 10
    },
    {
      "file": "/Library/installapplications/userland_examplerootscript.py",
      "hash": "sha256 hash",
      "name": "Example Script",
      "type": "rootscript",
      "url": "https://domain.tld/userland_examplerootscript.py"
    },
    {
      "file": "/Library/installapplications/userscripts/userland_exampleuserscript.py",
      "hash": "sha256 hash",
      "name": "Example Script",
      "type": "userscript",
      "url": "https://domain.tld/userland_exampleuserscript.py"
    }
  ]
}
"""#

func decode(_ json: String) throws -> Bootstrap {
    try Bootstrap.decode(json: Data(json.utf8))
}

func decodeError(_ json: String) -> String? {
    do {
        _ = try decode(json)
        return nil
    } catch {
        return String(describing: error)
    }
}

@Test func decodesUpstreamReadmeExample() throws {
    let bootstrap = try decode(upstreamReadmeExample)
    #expect(bootstrap.preflight.count == 1)
    #expect(bootstrap.setupassistant.count == 1)
    #expect(bootstrap.userland.count == 3)

    let package = bootstrap.userland[0]
    #expect(package.type == .package)
    #expect(package.packageID == "com.package.userland")
    #expect(package.version == "1.0")
    #expect(package.skipIf == .x86_64)
    #expect(package.retries == 5)
    #expect(package.retryWait == 10)

    // Keys left out fall back to upstream defaults.
    let script = bootstrap.userland[1]
    #expect(script.retries == 3)
    #expect(script.retryWait == 5)
    #expect(!script.required)
    #expect(!script.doNotWait)
    #expect(script.failPolicy == .failableExecution)
}

@Test func missingPhasesDecodeAsEmpty() throws {
    let bootstrap = try decode("{}")
    #expect(bootstrap.preflight.isEmpty)
    #expect(bootstrap.setupassistant.isEmpty)
    #expect(bootstrap.userland.isEmpty)
}

@Test func ignoresUnknownKeys() throws {
    let bootstrap = try decode(#"{"extra": 1, "userland": [{"name": "a", "file": "/a", "type": "rootscript", "pkg_required": true}]}"#)
    #expect(bootstrap.userland.count == 1)
}

@Test func missingKeyNamesItsLocation() {
    #expect(decodeError(#"{"preflight": [{"name": "a", "type": "rootscript"}]}"#) == "preflight[0].file: missing required key")
}

@Test func unsupportedTypeNamesItsLocation() {
    let message = decodeError(#"{"userland": [{"name": "a", "file": "/a", "type": "rootfile"}]}"#)
    #expect(message?.hasPrefix("userland[0].type: ") == true)
}

@Test func invalidJSONIsAnError() {
    #expect(decodeError("{") != nil)
}
