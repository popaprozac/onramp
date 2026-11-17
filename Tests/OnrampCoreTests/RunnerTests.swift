@testable import OnrampCore
import Testing

struct FakeError: Error, CustomStringConvertible {
    var description: String { "boom" }
}

/// Records every side effect the runner asks for, keyed by item file path.
actor FakeActions: Actions {
    let installed: [String: String]
    let failingDownloads: Set<String>
    let failingInstalls: Set<String>
    let exitCodes: [String: Int32]
    private(set) var calls: [String] = []

    init(installed: [String: String] = [:], failingDownloads: Set<String> = [], failingInstalls: Set<String> = [], exitCodes: [String: Int32] = [:]) {
        self.installed = installed
        self.failingDownloads = failingDownloads
        self.failingInstalls = failingInstalls
        self.exitCodes = exitCodes
    }

    func note(_ entry: String) { calls.append(entry) }

    func installedVersion(ofPackage id: String) -> String? {
        calls.append("receipt \(id)")
        return installed[id]
    }

    func download(_ item: Item) throws {
        calls.append("download \(item.file)")
        if failingDownloads.contains(item.file) { throw FakeError() }
    }

    func installPackage(at path: String) throws {
        calls.append("install \(path)")
        if failingInstalls.contains(path) { throw FakeError() }
    }

    func runScript(at path: String, as context: ScriptContext, wait: Bool) -> Int32 {
        calls.append("\(context.rawValue) \(path)" + (wait ? "" : " &"))
        return exitCodes[path] ?? 0
    }
}

/// A package `/<name>.pkg` with id `com.<name>` and version 1.0. `extra` is appended JSON, e.g. `, "required": true`.
func pkg(_ name: String, _ extra: String = "") -> String {
    #"{"name": "\#(name)", "file": "/\#(name).pkg", "type": "package", "url": "https://x/\#(name).pkg", "hash": "\#(goodHash)", "packageid": "com.\#(name)", "version": "1.0"\#(extra)}"#
}

/// A script `/<name>.sh` with no url.
func script(_ name: String, _ type: String = "rootscript", _ extra: String = "") -> String {
    #"{"name": "\#(name)", "file": "/\#(name).sh", "type": "\#(type)"\#(extra)}"#
}

func bootstrap(preflight: [String] = [], setupassistant: [String] = [], userland: [String] = []) throws -> Bootstrap {
    try decode(#"""
    {"preflight": [\#(preflight.joined(separator: ","))],
     "setupassistant": [\#(setupassistant.joined(separator: ","))],
     "userland": [\#(userland.joined(separator: ","))]}
    """#)
}

func run(_ bootstrap: Bootstrap, _ actions: FakeActions, appleSilicon: Bool = true, phases: [Phase] = Phase.allCases) async -> Report {
    await Runner(actions: actions, isAppleSilicon: appleSilicon).run(bootstrap, phases: phases)
}

@Test func preflightExitZeroMeansAlreadyProvisioned() async throws {
    let fake = FakeActions()
    let report = await run(try bootstrap(preflight: [script("check")], setupassistant: [pkg("a")], userland: [script("b")]), fake)
    #expect(report.outcome == .alreadyProvisioned)
    #expect(await fake.calls == ["root /check.sh"])
}

@Test func preflightNonZeroCarriesOn() async throws {
    let fake = FakeActions(exitCodes: ["/check.sh": 1])
    let report = await run(try bootstrap(preflight: [script("check")], userland: [script("b")]), fake)
    #expect(report.outcome == .completed)
    #expect(report.results.first?.status == .done("exited 1: not provisioned"))
    #expect(await fake.calls == ["root /check.sh", "root /b.sh"])
}

@Test func preflightAlwaysWaitsEvenWithDoNotWait() async throws {
    let fake = FakeActions()
    _ = await run(try bootstrap(preflight: [script("check", "rootscript", #", "donotwait": true"#)]), fake)
    #expect(await fake.calls == ["root /check.sh"])
}

@Test(arguments: [
    ("1.0", true),     // same version
    ("1.0.0", true),   // equal under LooseVersion
    ("2.0", true),     // newer
    ("0.9", false),    // older
])
func receiptVersionDecidesInstall(installed: String, skipped: Bool) async throws {
    let fake = FakeActions(installed: ["com.a": installed])
    let report = await run(try bootstrap(userland: [pkg("a")]), fake)
    #expect(report.outcome == .completed)
    let expected = skipped ? ["receipt com.a"] : ["receipt com.a", "download /a.pkg", "install /a.pkg"]
    #expect(await fake.calls == expected)
}

@Test func missingReceiptInstalls() async throws {
    let fake = FakeActions()
    _ = await run(try bootstrap(userland: [pkg("a")]), fake)
    #expect(await fake.calls == ["receipt com.a", "download /a.pkg", "install /a.pkg"])
}

@Test func requiredForcesInstallWithoutCheckingReceipt() async throws {
    let fake = FakeActions(installed: ["com.a": "9.0"])
    _ = await run(try bootstrap(userland: [pkg("a", #", "required": true"#)]), fake)
    #expect(await fake.calls == ["download /a.pkg", "install /a.pkg"])
}

@Test(arguments: [
    ("arm64", true, true),
    ("apple_silicon", true, true),
    ("x86_64", true, false),
    ("intel", false, true),
    ("arm64", false, false),
])
func skipIfMatchesArchitecture(skipIf: String, appleSilicon: Bool, skipped: Bool) async throws {
    let fake = FakeActions()
    let report = await run(try bootstrap(userland: [script("a", "rootscript", #", "skip_if": "\#(skipIf)""#)]), fake, appleSilicon: appleSilicon)
    #expect(report.results.first?.status == (skipped ? .skipped("skip_if \(skipIf)") : .done("exited 0")))
    #expect(await fake.calls == (skipped ? [] : ["root /a.sh"]))
}

@Test(arguments: [
    (nil as String?, "script", false),  // default failable_execution: scripts may fail
    (nil, "install", true),
    (nil, "download", true),
    ("failable", "install", false),
    ("failable", "download", false),
    ("failure_is_not_an_option", "script", true),
])
func failPolicyDecidesWhetherTheRunStops(policy: String?, failure: String, stops: Bool) async throws {
    let extra = policy.map { #", "fail_policy": "\#($0)""# } ?? ""
    let failing = failure == "script" ? script("bad", "rootscript", extra) : pkg("bad", extra)
    let fake = FakeActions(failingDownloads: failure == "download" ? ["/bad.pkg"] : [],
                           failingInstalls: failure == "install" ? ["/bad.pkg"] : [],
                           exitCodes: ["/bad.sh": 3])

    let report = await run(try bootstrap(userland: [failing, script("next")]), fake)

    #expect(report.outcome == (stops ? .failed : .completed))
    guard case let .failed(_, stopped) = report.results.first?.status else {
        Issue.record("expected the first item to fail, got \(String(describing: report.results.first?.status))")
        return
    }
    #expect(stopped == stops)
    #expect(await fake.calls.contains("root /next.sh") == !stops)
}

@Test func userscriptsRunAsUserAndAreSkippedDuringSetupAssistant() async throws {
    let fake = FakeActions()
    let report = await run(try bootstrap(setupassistant: [script("early", "userscript")], userland: [script("late", "userscript")]), fake)
    #expect(report.results.map(\.status) == [.skipped("userscripts cannot run during Setup Assistant"), .done("exited 0")])
    #expect(await fake.calls == ["user /late.sh"])
}

@Test func doNotWaitStartsScriptWithoutWaiting() async throws {
    let fake = FakeActions(exitCodes: ["/bg.sh": 1])
    let report = await run(try bootstrap(userland: [script("bg", "rootscript", #", "donotwait": true"#)]), fake)
    #expect(report.results.first?.status == .done("started"))
    #expect(await fake.calls == ["root /bg.sh &"])
}

@Test func scriptWithURLIsDownloadedFirst() async throws {
    let fake = FakeActions()
    _ = await run(try bootstrap(userland: [script("a", "rootscript", #", "url": "https://x/a.sh", "hash": "\#(goodHash)""#)]), fake)
    #expect(await fake.calls == ["download /a.sh", "root /a.sh"])
}

@Test func runsOnlyTheRequestedPhasesInOrder() async throws {
    let fake = FakeActions()
    let boot = try bootstrap(preflight: [script("check")], setupassistant: [script("sa")], userland: [script("u1"), script("u2")])
    let report = await run(boot, fake, phases: [.setupassistant, .userland])
    #expect(report.outcome == .completed)
    #expect(report.results.map(\.phase) == [.setupassistant, .userland, .userland])
    #expect(await fake.calls == ["root /sa.sh", "root /u1.sh", "root /u2.sh"])
}

@Test func reportsEachResultBeforeTheNextItemStarts() async throws {
    let fake = FakeActions(exitCodes: ["/check.sh": 1, "/bad.sh": 3])
    let boot = try bootstrap(preflight: [script("check")],
                             userland: [script("a"), script("bad", "rootscript", #", "fail_policy": "failure_is_not_an_option""#), script("never")])
    let report = await Runner(actions: fake, isAppleSilicon: true).run(boot) { await fake.note("result \($0.name)") }
    #expect(report.outcome == .failed)
    #expect(await fake.calls == ["root /check.sh", "result check", "root /a.sh", "result a", "root /bad.sh", "result bad"])
}
