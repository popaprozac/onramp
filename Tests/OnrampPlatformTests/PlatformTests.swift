import AppKit
import Foundation
import OnrampCore
@testable import OnrampPlatform
import Testing

/// A fresh directory for one test. The caller removes it.
func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onramp-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes an executable sh script into `dir`.
func script(_ body: String, in dir: URL) throws -> String {
    let file = dir.appendingPathComponent("script-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return file.path
}

/// Polls for a file a detached script writes.
func eventually(_ file: URL, within seconds: Double = 5) async throws -> String? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        try await Task.sleep(for: .milliseconds(50))
    }
    return nil
}

@Test(arguments: [("exit 0", 0), ("exit 3", 3), ("kill -9 $$", 137)])
func reportsExitStatusLikeAShell(body: String, expected: Int32) async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try await Spawn.run(script(body, in: dir), wait: true) == expected)
}

@Test func doNotWaitReturnsAtOnceAndTheScriptKeepsRunning() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = dir.appendingPathComponent("done")

    #expect(try await Spawn.run(script(#"sleep 1; echo ok > "$1""#, in: dir), [marker.path], wait: false) == 0)

    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try await eventually(marker) == "ok\n")
}

@Test(arguments: [true, false])
func onlyDetachedScriptsGetTheirOwnProcessGroup(detached: Bool) async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("ids")
    let body = #"echo "$$ $(ps -o pgid= -p $$)" > "$1.tmp" && mv "$1.tmp" "$1""#

    _ = try await Spawn.run(script(body, in: dir), [out.path], wait: !detached)

    let ids = try #require(try await eventually(out)).split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    try #require(ids.count == 2)
    // launchd kills the job's process group, so a detached script must lead its own.
    #expect(detached ? ids[1] == ids[0] : ids[1] == getpgrp())
}

@Test func passesOnOnlyStandardDescriptors() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fd = open(dir.path, O_RDONLY)
    try #require(fd > 2)
    defer { close(fd) }

    let status = try await Spawn.run(script(#"[ -e /dev/fd/$1 ] && exit 1; [ -e /dev/fd/2 ] || exit 2; exit 0"#, in: dir), ["\(fd)"], wait: true)
    #expect(status == 0)
}

@Test func failsToSpawnAMissingProgram() async throws {
    await #expect(throws: POSIXError.self) {
        try await Spawn.run("/nonexistent/onramp-test", wait: true)
    }
}

@Test func reportsAFailedInstall() async throws {
    await #expect(throws: PlatformError.self) {
        try await Installer.install("/nonexistent/onramp-test.pkg")
    }
}

@Test func acceptsAFileOnlyRootCanChange() throws {
    #expect(try FileSafety.rootControlledPath("/usr/bin/true") == "/usr/bin/true")
}

@Test func resolvesSymlinksBeforeChecking() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let link = dir.appendingPathComponent("true")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")

    // The caller runs the returned path, so repointing the link afterwards has no effect.
    #expect(try FileSafety.rootControlledPath(link.path) == "/usr/bin/true")
}

@Test func rejectsAFileAnotherUserOwns() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = try script("exit 0", in: dir)

    #expect(throws: PlatformError.self) { try FileSafety.rootControlledPath(path) }
}

@Test func rejectsARootFileInADirectoryAnotherUserOwns() throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // A hard link gives a root-owned file in our directory; whoever owns the directory can swap it.
    let link = dir.appendingPathComponent("hosts")
    try #require(Darwin.link("/private/etc/hosts", link.path) == 0)

    let error = #expect(throws: PlatformError.self) { try FileSafety.rootControlledPath(link.path) }
    #expect(error?.description.contains("onramp-tests-") == true)
}

@Test func rejectsAMissingFile() throws {
    #expect(throws: PlatformError.self) { try FileSafety.rootControlledPath("/nonexistent/onramp-test") }
}

@Test func rejectsWhatRootOwnsButOthersCanWrite() throws {
    // /private/tmp is root's, but anyone can write to it.
    #expect(throws: PlatformError.self) { try FileSafety.rootControlledPath("/private/tmp") }
}

/// Records each bootout, and what was already gone from disk at that moment, to check the order.
actor BootoutLog {
    var calls: [(target: String, plistGone: Bool, installGone: Bool)] = []
    func record(_ target: String, _ layout: Layout) {
        let gone = { !FileManager.default.fileExists(atPath: $0) }
        calls.append((target, gone(layout.daemonPlist), gone(layout.installDirectory)))
    }
}

/// An installed-looking layout in `dir`: the daemon plist and an install folder with a state file.
func scratchLayout(in dir: URL) throws -> Layout {
    let layout = Layout(installDirectory: dir.appendingPathComponent("onramp").path,
                        launchDaemons: dir.appendingPathComponent("LaunchDaemons").path)
    for path in [layout.installDirectory, layout.launchDaemons] {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    for path in [layout.daemonPlist, layout.stateFile] {
        FileManager.default.createFile(atPath: path, contents: Data())
    }
    return layout
}

@Test func uninstallRemovesEverythingBeforeUnloadingTheDaemon() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let layout = try scratchLayout(in: dir)
    let log = BootoutLog()

    let failures = await Uninstaller.run(layout.uninstallSteps(keepBinary: false)) { target in
        await log.record(target, layout)
        return true
    }

    #expect(failures.isEmpty)
    let calls = await log.calls
    #expect(calls.map(\.target) == ["system/\(Identity.daemonLabel)"])
    #expect(calls.first?.plistGone == true)
    #expect(calls.first?.installGone == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["LaunchDaemons"])
}

@Test func uninstallKeepsGoingAfterAStepFails() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let layout = try scratchLayout(in: dir)
    // A read-only folder makes removing the plist fail.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: layout.launchDaemons)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.launchDaemons) }
    let log = BootoutLog()

    let failures = await Uninstaller.run(layout.uninstallSteps(keepBinary: false)) { target in
        await log.record(target, layout)
        return true
    }

    #expect(failures.count == 1)
    #expect(failures.first?.hasPrefix("remove \(layout.daemonPlist)") == true)
    #expect(!FileManager.default.fileExists(atPath: layout.installDirectory))
    #expect(await log.calls.map(\.target) == ["system/\(Identity.daemonLabel)"])
}

@Test func uninstallTreatsMissingFilesAsDone() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let layout = try scratchLayout(in: dir)
    try FileManager.default.removeItem(atPath: layout.installDirectory)
    try FileManager.default.removeItem(atPath: layout.daemonPlist)

    #expect(await Uninstaller.run(layout.uninstallSteps(keepBinary: false)) { _ in true }.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func consoleUserUpdatesStartWithTheCurrentUserAndStopWhenCancelled() async {
    let reader = Task {
        var seen: [ConsoleUser?] = []
        for await user in ConsoleUsers.updates() { seen.append(user) }
        return seen
    }
    try? await Task.sleep(for: .milliseconds(200))
    reader.cancel()
    // If cancelling didn't end the stream, this would hang until the time limit.
    let seen = await reader.value
    #expect(seen.first == .some(ConsoleUsers.current()))

    // Cancelling must also tear down the configd subscription, not just end the loop.
    for _ in 0..<40 where ConsoleUsers.liveSubscriptions.withLock({ $0 }) > 0 { try? await Task.sleep(for: .milliseconds(50)) }
    #expect(ConsoleUsers.liveSubscriptions.withLock { $0 } == 0)
}

@Test func userscriptsRunInTheUsersSessionAsTheUser() {
    #expect(ConsoleUser(name: "bench", uid: 501).inSession("/a.sh", ["x"]) ==
        ["asuser", "501", "/usr/bin/sudo", "-H", "-u", "bench", "--", "/a.sh", "x"])
}

@Test func waitsForTheDesktopOnlyAsLongAsItsNotReady() async {
    // On this Mac the answer depends on what's running, so compare against the same check.
    let expected = await MainActor.run {
        DesktopState(running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))) == .ready
    }
    #expect(await Desktop.waitUntilReady(timeout: .milliseconds(100)) == expected)
}

@Test func afterAFailureOnlyTheBinaryStays() async throws {
    let dir = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let layout = try scratchLayout(in: dir)
    for path in [layout.binary, layout.cachedBootstrap] { FileManager.default.createFile(atPath: path, contents: Data()) }

    #expect(await Uninstaller.run(layout.uninstallSteps(keepBinary: true)) { _ in true }.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.installDirectory) == ["onramp"])
    #expect(!FileManager.default.fileExists(atPath: layout.daemonPlist))
}
