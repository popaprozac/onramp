import Foundation

public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Settings from the managed preferences domain, which an MDM profile sets.
public struct Config: Sendable {
    public enum Source: Sendable {
        case url(URL)
        /// A bootstrap carried in the profile itself. It still needs `validate()`, like a downloaded one.
        case embedded(Bootstrap)
    }

    /// The keys `init` reads. Anything else in the domain is ignored.
    public static let keys = ["JSONURL", "Bootstrap", "Headers", "MaxAttempts"]

    public let source: Source
    /// Sent only to the `JSONURL` origin.
    public let headers: [String: String]
    public let maxAttempts: Int

    public init(_ values: [String: Any]) throws(ConfigError) {
        switch (values["JSONURL"], values["Bootstrap"]) {
        case (nil, nil):
            throw ConfigError("set JSONURL or Bootstrap")
        case (.some, .some):
            throw ConfigError("set JSONURL or Bootstrap, not both")
        case let (raw?, nil):
            // Nothing else protects the bootstrap, and it decides what runs as root.
            guard let string = raw as? String, let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil else {
                throw ConfigError("JSONURL must be an https URL")
            }
            source = .url(url)
        case let (nil, raw?):
            // JSONSerialization raises an Objective-C exception, not a Swift error, on values like dates.
            guard raw is [String: Any], JSONSerialization.isValidJSONObject(raw),
                  let json = try? JSONSerialization.data(withJSONObject: raw) else {
                throw ConfigError("Bootstrap must be a dictionary with bootstrap.json's keys and values")
            }
            do { source = .embedded(try Bootstrap.decode(json: json)) } catch { throw ConfigError("Bootstrap: \(error)") }
        }

        switch values["Headers"] {
        case nil:
            headers = [:]
        case let raw as [String: String]:
            guard case .url = source else { throw ConfigError("Headers needs JSONURL, because they are only sent to its host") }
            headers = raw
        default:
            throw ConfigError("Headers must be a dictionary of strings")
        }

        switch values["MaxAttempts"] {
        case nil: maxAttempts = 3
        case let count as Int where count >= 1: maxAttempts = count
        default: throw ConfigError("MaxAttempts must be a whole number, at least 1")
        }
    }
}
