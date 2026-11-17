import ArgumentParser
import OnrampCore

@main
struct OnrampCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "onramp",
        abstract: "Bootstraps a Mac at enrollment from an InstallApplications-style bootstrap.json.",
        version: Identity.version,
        subcommands: [Validate.self, Run.self, Debug.self]
    )
}
