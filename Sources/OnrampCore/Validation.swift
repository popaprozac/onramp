import Foundation

public struct ValidationIssue: Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    public let severity: Severity
    public let location: String
    public let message: String

    public var description: String { "\(severity): \(location): \(message)" }
}

extension Bootstrap {
    /// Errors are things upstream IA would crash on or that onramp cannot run safely.
    /// Warnings are things upstream tolerates but that are probably mistakes.
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for phase in Phase.allCases {
            for (index, item) in self[phase].enumerated() {
                let location = "\(phase.rawValue)[\(index)] \"\(item.name)\""
                func error(_ message: String) { issues.append(ValidationIssue(severity: .error, location: location, message: message)) }
                func warning(_ message: String) { issues.append(ValidationIssue(severity: .warning, location: location, message: message)) }

                if item.name.trimmingCharacters(in: .whitespaces).isEmpty { error("name is empty") }
                if !item.file.hasPrefix("/") { error("file must be an absolute path") }
                if item.retries < 0 { error("retries must not be negative") }
                if item.retryWait < 0 { error("retrywait must not be negative") }

                if let url = item.url {
                    switch URLComponents(string: url)?.scheme?.lowercased() {
                    case "https": break
                    case "http": warning("url uses plain http")
                    default: error("url must be an http(s) URL")
                    }
                    if item.hash == nil { error("hash is required when url is set") }
                }
                if let hash = item.hash, !Self.isSHA256Hex(hash) {
                    error("hash must be a 64-character SHA-256 hex digest")
                }

                switch item.type {
                case .package:
                    if item.url == nil { error("package requires url") }
                    if item.packageID?.isEmpty ?? true { error("package requires packageid") }
                    if item.version?.isEmpty ?? true { error("package requires version") }
                    if item.doNotWait { warning("donotwait has no effect on packages") }
                case .rootscript, .userscript:
                    if item.required { warning("required only applies to packages") }
                }

                if phase == .preflight, item.type != .rootscript {
                    error("preflight only supports rootscript")
                }
                if phase == .preflight, item.doNotWait {
                    // Upstream would treat a backgrounded preflight as passed and skip everything.
                    warning("donotwait is ignored for preflight")
                }
                if phase == .setupassistant, item.type == .userscript {
                    warning("userscripts cannot run during Setup Assistant and will be skipped")
                }
            }
        }
        if Phase.allCases.allSatisfy({ self[$0].isEmpty }) {
            issues.append(ValidationIssue(severity: .warning, location: "bootstrap", message: "no items in any phase"))
        }
        return issues
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
