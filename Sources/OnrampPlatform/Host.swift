import Foundation

/// Read-only facts about this Mac.
public enum Host {
    /// The version from the package's receipt, or nil if it has none. Same lookup as upstream.
    public static func installedVersion(ofPackage id: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--pkg-info-plist", id]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let receipt = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return receipt["pkg-version"] as? String
    }

    /// True on Apple silicon, even when this process runs under Rosetta.
    public static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()
}

extension Host {
    /// Reads `keys` from a preferences domain. A value an MDM profile manages wins over any other.
    public static func preferences(_ keys: [String], in domain: String) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in keys {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) { values[key] = value }
        }
        return values
    }
}
