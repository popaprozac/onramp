import ArgumentParser
import Foundation
import OnrampCore

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a bootstrap.json for errors and likely mistakes."
    )

    @Argument(help: "Path to bootstrap.json.")
    var path: String

    func run() throws {
        let bootstrap = try loadBootstrap(path)
        let counts = Phase.allCases.map { "\(bootstrap[$0].count) \($0.rawValue)" }.joined(separator: ", ")
        print("valid: \(counts)")
    }
}

/// Reads, decodes and validates a bootstrap.json, printing every issue. Throws if it has any errors.
func loadBootstrap(_ path: String) throws -> Bootstrap {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let bootstrap: Bootstrap
    do {
        bootstrap = try Bootstrap.decode(json: data)
    } catch {
        print("error: \(error)")
        throw ExitCode.failure
    }

    let issues = bootstrap.validate()
    issues.forEach { print($0) }
    if issues.contains(where: { $0.severity == .error }) {
        throw ExitCode.failure
    }
    return bootstrap
}
