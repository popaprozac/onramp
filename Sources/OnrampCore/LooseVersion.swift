/// Port of munki's `MunkiLooseVersion`, which upstream IA uses to compare package receipt versions.
/// Splits on digit runs, lowercase-letter runs and dots; dots are dropped and other characters form their own parts.
/// Missing parts count as 0, and a number sorts before text, so "10.6" == "10.6.0" and "1.0b2" > "1.0".
public struct LooseVersion: Comparable, Sendable, CustomStringConvertible {
    enum Part: Sendable {
        /// Digits with leading zeros stripped, so any length compares numerically without overflow.
        case number(String)
        case text(String)
    }

    public let description: String
    let parts: [Part]

    public init(_ string: String) {
        enum CharClass { case digit, lower, dot, other }
        func charClass(_ scalar: Unicode.Scalar) -> CharClass {
            switch scalar {
            case "0"..."9": .digit
            case "a"..."z": .lower
            case ".": .dot
            default: .other
            }
        }

        var parts: [Part] = []
        var run = String.UnicodeScalarView()
        var runClass: CharClass?
        func flush() {
            defer { run = String.UnicodeScalarView() }
            guard let runClass, !run.isEmpty else { return }
            let text = String(run)
            switch runClass {
            case .digit: parts.append(.number(String(text.drop { $0 == "0" })))
            case .lower, .other: parts.append(.text(text))
            case .dot: break
            }
        }
        for scalar in string.unicodeScalars {
            let cls = charClass(scalar)
            if cls != runClass || cls == .dot {
                flush()
                runClass = cls
            }
            run.append(scalar)
        }
        flush()

        self.description = string
        self.parts = parts
    }

    /// Returns -1, 0 or 1, matching munki's `_compare`.
    public static func compare(_ lhs: LooseVersion, _ rhs: LooseVersion) -> Int {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : .number("")
            let right = index < rhs.parts.count ? rhs.parts[index] : .number("")
            switch (left, right) {
            case let (.number(l), .number(r)):
                if l.count != r.count { return l.count < r.count ? -1 : 1 }
                if l != r { return l < r ? -1 : 1 }
            case let (.text(l), .text(r)):
                if !l.unicodeScalars.elementsEqual(r.unicodeScalars) {
                    return l.unicodeScalars.lexicographicallyPrecedes(r.unicodeScalars) ? -1 : 1
                }
            case (.number, .text): return -1
            case (.text, .number): return 1
            }
        }
        return 0
    }

    public static func < (lhs: LooseVersion, rhs: LooseVersion) -> Bool { compare(lhs, rhs) < 0 }
    public static func == (lhs: LooseVersion, rhs: LooseVersion) -> Bool { compare(lhs, rhs) == 0 }
}
