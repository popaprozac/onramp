@testable import OnrampCore
import Testing

/// Records every call the daemon makes, its own and its actions', in one timeline.
actor FakeEnvironment: DaemonEnvironment {
    let initial: RunState
    let bootstrap: Bootstrap?
    let exitCodes: [String: Int32]
    private(set) var events: [String] = []
    private(set) var lastSaved: RunState?

    init(state: RunState = RunState(), bootstrap: Bootstrap?, exitCodes: [String: Int32] = [:]) {
        self.initial = state
        self.bootstrap = bootstrap
        self.exitCodes = exitCodes
    }

    func record(_ event: String) { events.append(event) }
    func exitCode(_ path: String) -> Int32 { exitCodes[path] ?? 0 }

    func loadState() -> RunState { initial }
    func save(_ state: RunState) {
        lastSaved = state
        events.append("save running=\(state.running?.rawValue ?? "-")")
    }
    func loadBootstrap() throws -> Bootstrap {
        events.append("load bootstrap")
        guard let bootstrap else { throw FakeError() }
        return bootstrap
    }
    nonisolated func actions(for user: ConsoleUser?) -> any Actions { RecordingActions(environment: self, user: user?.name) }
    func waitForUser() -> ConsoleUser {
        events.append("wait for user")
        return ConsoleUser(name: "bench", uid: 501)
    }
    func waitForDesktop(of user: ConsoleUser) { events.append("wait for desktop") }
    func log(_ message: String) {}
    func finish(_ status: Status, failedAttempts: Int) { events.append("finish \(status.result.rawValue) failed=\(failedAttempts)") }
}

struct RecordingActions: Actions {
    let environment: FakeEnvironment
    let user: String?

    func installedVersion(ofPackage id: String) async -> String? { nil }
    func download(_ item: Item) async throws { await environment.record("download \(item.file)") }
    func installPackage(at path: String) async throws { await environment.record("install \(path)") }
    func runScript(at path: String, as context: ScriptContext, wait: Bool) async throws -> Int32 {
        await environment.record(context == .user ? "\(user ?? "nobody") \(path)" : "root \(path)")
        return await environment.exitCode(path)
    }
}

func enrollment() throws -> Bootstrap {
    try bootstrap(preflight: [script("check")], setupassistant: [script("sa")], userland: [pkg("app"), script("u", "userscript")])
}

func daemon(_ environment: FakeEnvironment, maxAttempts: Int = 3) async -> Daemon.Exit {
    await Daemon(environment: environment, maxAttempts: maxAttempts, isAppleSilicon: true).run()
}

@Test func runsEveryPhaseThenFinishes() async throws {
    let env = FakeEnvironment(bootstrap: try enrollment(), exitCodes: ["/check.sh": 1])

    #expect(await daemon(env) == .finished(Status(result: .completed)))
    #expect(await env.events == [
        "save running=-", "load bootstrap",
        "save running=preflight", "root /check.sh", "save running=-",
        "save running=setupassistant", "root /sa.sh", "save running=-",
        "download /app.pkg",  // userland files are fetched before anyone logs in
        "wait for user", "wait for desktop",
        "save running=userland",  // marked only after the login, so a restart while waiting costs nothing
        "download /app.pkg", "install /app.pkg", "bench /u.sh", "save running=-",
        "save running=-", "finish completed failed=0",
    ])
    #expect(await env.lastSaved?.completed == Phase.allCases)
}

@Test func aRestartAfterSetupAssistantGoesStraightToUserland() async throws {
    let env = FakeEnvironment(state: RunState(completed: [.preflight, .setupassistant]), bootstrap: try enrollment())

    #expect(await daemon(env) == .finished(Status(result: .completed)))
    let events = await env.events
    #expect(!events.contains("root /check.sh"))
    #expect(!events.contains("root /sa.sh"))
    #expect(events.contains("bench /u.sh"))
}

@Test func aPhaseCutOffRunsAgainAndCounts() async throws {
    let env = FakeEnvironment(state: RunState(completed: [.preflight], running: .setupassistant), bootstrap: try enrollment())

    #expect(await daemon(env) == .finished(Status(result: .completed)))
    #expect(await env.events.contains("root /sa.sh"))
    #expect(await env.events.last == "finish completed failed=1")
}

@Test func alreadyProvisionedFinishesWithoutWaitingForALogin() async throws {
    let env = FakeEnvironment(bootstrap: try enrollment())

    #expect(await daemon(env) == .finished(Status(result: .alreadyProvisioned)))
    let events = await env.events
    #expect(!events.contains("wait for user"))
    #expect(events.last == "finish already_provisioned failed=0")
}

@Test func aFailureBelowTheCapRetries() async throws {
    let failing = script("sa", "rootscript", #", "fail_policy": "failure_is_not_an_option""#)
    let env = FakeEnvironment(bootstrap: try bootstrap(setupassistant: [failing], userland: [script("u")]), exitCodes: ["/sa.sh": 2])

    #expect(await daemon(env) == .retry)
    #expect(await env.lastSaved == RunState(attempts: 1, lastError: #"setupassistant "sa": exited 2"#, completed: [.preflight]))
    #expect(!(await env.events.contains { $0.hasPrefix("finish") }))
}

@Test func aFailureAtTheCapFinishesAsFailed() async throws {
    let failing = script("sa", "rootscript", #", "fail_policy": "failure_is_not_an_option""#)
    let env = FakeEnvironment(state: RunState(attempts: 2), bootstrap: try bootstrap(setupassistant: [failing]), exitCodes: ["/sa.sh": 2])

    #expect(await daemon(env) == .finished(Status(result: .failed, error: #"setupassistant "sa": exited 2"#)))
    #expect(await env.events.last == "finish failed failed=3")
}

@Test func aBootstrapThatWontLoadIsAFailedAttempt() async {
    let env = FakeEnvironment(bootstrap: nil)

    #expect(await daemon(env) == .retry)
    #expect(await env.lastSaved?.attempts == 1)
    #expect(await env.events == ["save running=-", "load bootstrap", "save running=-"])
}

@Test func usedUpAttemptsFinishWithoutRunning() async throws {
    let env = FakeEnvironment(state: RunState(attempts: 3, lastError: "boom"), bootstrap: try enrollment())

    #expect(await daemon(env) == .finished(Status(result: .failed, error: "boom")))
    #expect(await env.events == ["save running=-", "finish failed failed=3"])
}

@Test(arguments: [
    (["com.apple.dock", "com.apple.finder"], DesktopState.ready),
    (["com.apple.dock", "com.apple.finder", "com.apple.SetupAssistant"], .setupAssistantOpen),
    (["com.apple.SetupAssistant"], .setupAssistantOpen),
    (["com.apple.dock"], .notUp),
    ([], .notUp),
] as [([String], DesktopState)])
func desktopIsReadyOnlyWithDockAndFinderAndNoSetupAssistant(running: [String], state: DesktopState) {
    #expect(DesktopState(running: Set(running)) == state)
}
