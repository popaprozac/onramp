import ArgumentParser
import OnrampCore
import OnrampPlatform

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a bootstrap.json. Only --dry-run is supported so far."
    )

    @Flag(help: "Show what would happen without downloading, installing or running anything.")
    var dryRun = false

    @Argument(help: "Path to bootstrap.json.")
    var path: String

    func validate() throws {
        guard dryRun else { throw ValidationError("only --dry-run is supported so far") }
    }

    func run() async throws {
        let bootstrap = try loadBootstrap(path)
        let actions = DryRunActions(preflightFiles: Set(bootstrap[.preflight].map(\.file)))

        print("dry run: nothing is downloaded, installed or run. Package receipts are read from this Mac, and every preflight script is assumed to exit non-zero (not provisioned).")
        let report = await Runner(actions: actions, isAppleSilicon: Host.isAppleSilicon).run(bootstrap) { result in
            let planned = await actions.takePlanned()
            print("\(result.phase.rawValue): \(result.name)")
            switch result.status {
            case .done: planned.forEach { print("  would \($0)") }
            case let .skipped(reason): print("  skip: \(reason)")
            case let .failed(reason, stopped): print("  failed: \(reason)" + (stopped ? ", stopping the run" : ""))
            }
        }
        print("outcome: \(report.outcome)")
        if report.outcome == .failed { throw ExitCode.failure }
    }
}

/// Records what a real run would do instead of doing it. Receipt lookups are real and read-only.
actor DryRunActions: Actions {
    /// A preflight exiting 0 would end the run, so assume it doesn't and show every phase.
    let preflightFiles: Set<String>
    private var planned: [String] = []

    init(preflightFiles: Set<String>) { self.preflightFiles = preflightFiles }

    /// What the current item would do, clearing it for the next item.
    func takePlanned() -> [String] {
        defer { planned = [] }
        return planned
    }

    nonisolated func installedVersion(ofPackage id: String) -> String? { Host.installedVersion(ofPackage: id) }

    func download(_ item: Item) { planned.append("download \(item.file)") }

    func installPackage(at path: String) { planned.append("install \(path)") }

    func runScript(at path: String, as context: ScriptContext, wait: Bool) -> Int32 {
        planned.append("run \(path) as \(context.rawValue)" + (wait ? "" : " without waiting"))
        return preflightFiles.contains(path) ? 1 : 0
    }
}
