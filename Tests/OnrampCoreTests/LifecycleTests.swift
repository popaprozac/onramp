import Foundation
@testable import OnrampCore
import Testing

@Test func aRestartWhileWaitingForLoginCostsNothing() {
    var state = RunState()
    #expect(state.resume(maxAttempts: 3) == nil)
    for phase in [Phase.preflight, .setupassistant] {
        state.start(phase)
        state.complete(phase)
    }
    // The user walked away before creating their account, and the Mac restarted.
    #expect(state.resume(maxAttempts: 3) == nil)
    #expect(state.attempts == 0)
    #expect(state.remaining == [.userland])
}

@Test func aPhaseCutOffCountsAsAFailedAttemptAndRunsAgain() {
    var state = RunState()
    state.start(.preflight)
    state.complete(.preflight)
    state.start(.setupassistant)
    // Power was lost during setupassistant.
    #expect(state.resume(maxAttempts: 3) == nil)
    #expect(state == RunState(attempts: 1, lastError: "setupassistant was cut off by a crash, restart or power loss", completed: [.preflight]))
    #expect(state.remaining == [.setupassistant, .userland])
}

@Test func aCrashLoopStopsAtMaxAttempts() {
    var state = RunState()
    _ = state.resume(maxAttempts: 2)
    state.start(.preflight)
    #expect(state.resume(maxAttempts: 2) == nil)
    state.start(.preflight)
    #expect(state.resume(maxAttempts: 2) == Status(result: .failed, error: "preflight was cut off by a crash, restart or power loss"))
}

@Test func failuresRetryUntilMaxAttempts() {
    var state = RunState()
    state.start(.userland)
    #expect(state.fail("first", maxAttempts: 2) == nil)
    #expect(state == RunState(attempts: 1, lastError: "first"))
    #expect(state.resume(maxAttempts: 2) == nil)
    #expect(state.fail("second", maxAttempts: 2) == Status(result: .failed, error: "second"))
    // If uninstalling didn't finish, the next launch gives up again instead of running.
    #expect(state.resume(maxAttempts: 2) == Status(result: .failed, error: "second"))
}

@Test func aFailedReportNamesTheItem() {
    let report = Report(outcome: .failed, results: [
        ItemResult(phase: .userland, name: "ok", status: .done("installed")),
        ItemResult(phase: .userland, name: "Chrome", status: .failed("install failed: boom", stopped: true)),
    ])
    #expect(Status(report) == Status(result: .failed, error: #"userland "Chrome": install failed: boom"#))
    #expect(Status(Report(outcome: .alreadyProvisioned, results: [])) == Status(result: .alreadyProvisioned))
}

@Test func statusPreferencesCarryTheResult() {
    let date = Date(timeIntervalSince1970: 0)
    let values = Status(result: .failed, error: "boom").preferences(failedAttempts: 3, finishedAt: date)
    #expect(values["Result"] as? String == "failed")
    #expect(values["Error"] as? String == "boom")
    #expect(values["FailedAttempts"] as? Int == 3)
    #expect(values["FinishedAt"] as? Date == date)
    #expect(values["Version"] as? String == Identity.version)
    #expect(Status(result: .completed).preferences(failedAttempts: 0, finishedAt: date)["Error"] == nil)
}

@Test func stateIsSavedForRootOnlyAndSurvivesBadFiles() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("state.plist")
    let state = RunState(attempts: 1, lastError: "x", completed: [.preflight], running: .setupassistant)

    #expect(RunState.load(from: file) == RunState())
    try state.save(to: file)
    #expect(RunState.load(from: file) == state)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)

    try Data("not a plist".utf8).write(to: file)
    #expect(RunState.load(from: file) == RunState())
}

@Test func uninstallFollowsUpstreamOrder() {
    let layout = Layout.system
    #expect(layout.uninstallSteps(agentUIDs: [501, 502]) == [
        .remove("/Library/LaunchDaemons/io.github.popaprozac.onramp.daemon.plist"),
        .remove("/Library/LaunchAgents/io.github.popaprozac.onramp.agent.plist"),
        .bootout("gui/501/io.github.popaprozac.onramp.agent"),
        .bootout("gui/502/io.github.popaprozac.onramp.agent"),
        .remove("/Library/onramp"),
        .bootout("system/io.github.popaprozac.onramp.daemon"),
    ])
}
