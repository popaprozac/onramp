public enum ScriptContext: String, Sendable { case root, user }

/// Side effects the runner needs. The daemon, dry runs and tests each supply their own.
public protocol Actions: Sendable {
    /// The installed receipt version, or nil if the package isn't installed.
    func installedVersion(ofPackage id: String) async -> String?
    /// Makes sure `item.file` exists and matches `item.hash`, downloading it if needed.
    func download(_ item: Item) async throws
    func installPackage(at path: String) async throws
    /// Returns the script's exit status. When `wait` is false it returns once the script has started.
    func runScript(at path: String, as context: ScriptContext, wait: Bool) async throws -> Int32
}

public struct ItemResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case done(String)
        case skipped(String)
        /// `stopped` is true when the item's fail_policy ended the run.
        case failed(String, stopped: Bool)
    }

    public let phase: Phase
    public let name: String
    public let status: Status
}

public struct Report: Sendable {
    public enum Outcome: Sendable, Equatable {
        case completed
        /// A preflight script exited 0, so the Mac is already set up and nothing else ran.
        case alreadyProvisioned
        /// An item failed under a policy that stops the run. It is the last result.
        case failed
    }

    public var outcome: Outcome
    public var results: [ItemResult]
}

/// Runs bootstrap phases with upstream InstallApplications semantics, plus `fail_policy`.
public struct Runner: Sendable {
    let actions: any Actions
    let isAppleSilicon: Bool

    public init(actions: any Actions, isAppleSilicon: Bool) {
        self.actions = actions
        self.isAppleSilicon = isAppleSilicon
    }

    /// Runs `phases` in order, calling `onResult` as each item finishes.
    /// The daemon runs preflight and setupassistant first, then userland after login.
    public func run(_ bootstrap: Bootstrap, phases: [Phase] = Phase.allCases, onResult: (ItemResult) async -> Void = { _ in }) async -> Report {
        var results: [ItemResult] = []
        for phase in phases {
            for item in bootstrap[phase] {
                let (status, provisioned) = phase == .preflight
                    ? await preflight(item)
                    : (await process(item, in: phase), false)
                let result = ItemResult(phase: phase, name: item.name, status: status)
                results.append(result)
                await onResult(result)
                if provisioned { return Report(outcome: .alreadyProvisioned, results: results) }
                if case .failed(_, stopped: true) = status { return Report(outcome: .failed, results: results) }
            }
        }
        return Report(outcome: .completed, results: results)
    }

    /// A preflight script exiting 0 means "already provisioned". Any other result means "carry on", as upstream does.
    private func preflight(_ item: Item) async -> (ItemResult.Status, provisioned: Bool) {
        if let skip = skipReason(item) { return (.skipped(skip), false) }
        if let failure = await download(item) { return (failure, false) }
        do {
            let code = try await actions.runScript(at: item.file, as: .root, wait: true)
            return code == 0 ? (.done("exited 0: already provisioned"), true) : (.done("exited \(code): not provisioned"), false)
        } catch {
            return (.done("could not run (\(error)): treating as not provisioned"), false)
        }
    }

    private func process(_ item: Item, in phase: Phase) async -> ItemResult.Status {
        if item.type == .userscript, phase == .setupassistant {
            return .skipped("userscripts cannot run during Setup Assistant")
        }
        if let skip = skipReason(item) { return .skipped(skip) }

        switch item.type {
        case .package:
            if !item.required, let id = item.packageID, let version = item.version,
               let installed = await actions.installedVersion(ofPackage: id),
               LooseVersion(installed) >= LooseVersion(version) {
                return .skipped("installed version \(installed) is at or above \(version)")
            }
            if let failure = await download(item) { return failure }
            do {
                try await actions.installPackage(at: item.file)
                return .done("installed")
            } catch {
                return failed(item, .install, "install failed: \(error)")
            }

        case .rootscript, .userscript:
            if let failure = await download(item) { return failure }
            do {
                let context: ScriptContext = item.type == .rootscript ? .root : .user
                let code = try await actions.runScript(at: item.file, as: context, wait: !item.doNotWait)
                if item.doNotWait { return .done("started") }
                return code == 0 ? .done("exited 0") : failed(item, .execution, "exited \(code)")
            } catch {
                return failed(item, .execution, "could not run: \(error)")
            }
        }
    }

    /// onramp applies `skip_if` to every item type; upstream only checks it on packages.
    private func skipReason(_ item: Item) -> String? {
        guard let skipIf = item.skipIf else { return nil }
        let matches = switch skipIf {
        case .arm64, .appleSilicon: isAppleSilicon
        case .x86_64, .intel: !isAppleSilicon
        }
        return matches ? "skip_if \(skipIf.rawValue)" : nil
    }

    /// Returns a failure status if the download failed, nil if it succeeded or there was nothing to download.
    private func download(_ item: Item) async -> ItemResult.Status? {
        guard item.url != nil else { return nil }
        do {
            try await actions.download(item)
            return nil
        } catch {
            return failed(item, .download, "download failed: \(error)")
        }
    }

    private func failed(_ item: Item, _ kind: FailureKind, _ reason: String) -> ItemResult.Status {
        .failed(reason, stopped: item.failPolicy.stopsRun(on: kind))
    }
}

enum FailureKind { case download, install, execution }

extension Item.FailPolicy {
    func stopsRun(on kind: FailureKind) -> Bool {
        switch self {
        case .failureIsNotAnOption: true
        case .failable: false
        case .failableExecution: kind != .execution
        }
    }
}
