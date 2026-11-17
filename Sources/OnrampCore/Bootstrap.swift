import Foundation

public enum Phase: String, CaseIterable, Codable, Sendable {
    case preflight, setupassistant, userland
}

/// An InstallApplications `bootstrap.json`. Keys and defaults follow upstream IA; unknown keys are ignored.
public struct Bootstrap: Decodable, Sendable {
    public var preflight: [Item]
    public var setupassistant: [Item]
    public var userland: [Item]

    public subscript(phase: Phase) -> [Item] {
        switch phase {
        case .preflight: preflight
        case .setupassistant: setupassistant
        case .userland: userland
        }
    }

    enum CodingKeys: String, CodingKey { case preflight, setupassistant, userland }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preflight = try c.decodeIfPresent([Item].self, forKey: .preflight) ?? []
        setupassistant = try c.decodeIfPresent([Item].self, forKey: .setupassistant) ?? []
        userland = try c.decodeIfPresent([Item].self, forKey: .userland) ?? []
    }

    public static func decode(json data: Data) throws(BootstrapError) -> Bootstrap {
        do {
            return try JSONDecoder().decode(Bootstrap.self, from: data)
        } catch let error as DecodingError {
            throw BootstrapError(error)
        } catch {
            throw BootstrapError(description: error.localizedDescription)
        }
    }
}

public struct Item: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case package, rootscript, userscript }
    public enum SkipIf: String, Decodable, Sendable { case x86_64, intel, arm64, appleSilicon = "apple_silicon" }
    public enum FailPolicy: String, Decodable, Sendable {
        case failureIsNotAnOption = "failure_is_not_an_option"
        case failable
        case failableExecution = "failable_execution"
    }

    public var name: String
    public var file: String
    public var type: Kind
    public var url: String?
    public var hash: String?
    public var packageID: String?
    public var version: String?
    /// Packages only: install even when the receipt is already at or above `version`.
    public var required: Bool
    public var doNotWait: Bool
    public var skipIf: SkipIf?
    public var retries: Int
    public var retryWait: Int
    /// onramp extension; not part of upstream IA.
    public var failPolicy: FailPolicy

    enum CodingKeys: String, CodingKey {
        case name, file, type, url, hash, version, required, retries
        case packageID = "packageid", doNotWait = "donotwait", skipIf = "skip_if"
        case retryWait = "retrywait", failPolicy = "fail_policy"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        file = try c.decode(String.self, forKey: .file)
        type = try c.decode(Kind.self, forKey: .type)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        packageID = try c.decodeIfPresent(String.self, forKey: .packageID)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        doNotWait = try c.decodeIfPresent(Bool.self, forKey: .doNotWait) ?? false
        skipIf = try c.decodeIfPresent(SkipIf.self, forKey: .skipIf)
        // Upstream defaults.
        retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? 3
        retryWait = try c.decodeIfPresent(Int.self, forKey: .retryWait) ?? 5
        failPolicy = try c.decodeIfPresent(FailPolicy.self, forKey: .failPolicy) ?? .failableExecution
    }
}

/// A bootstrap that could not be decoded, with a readable location such as `userland[2].type`.
public struct BootstrapError: Error, CustomStringConvertible {
    public let description: String

    init(description: String) { self.description = description }

    init(_ error: DecodingError) {
        switch error {
        case let .keyNotFound(key, context):
            description = "\(Self.path(context.codingPath + [key])): missing required key"
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            let path = Self.path(context.codingPath)
            // For JSON syntax errors the underlying error carries the line and column.
            let debug = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            let detail = debug.map { " (\($0))" } ?? ""
            description = (path.isEmpty ? "" : "\(path): ") + context.debugDescription + detail
        @unknown default:
            description = String(describing: error)
        }
    }

    static func path(_ keys: [any CodingKey]) -> String {
        keys.reduce(into: "") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += (result.isEmpty ? "" : ".") + key.stringValue
            }
        }
    }
}
