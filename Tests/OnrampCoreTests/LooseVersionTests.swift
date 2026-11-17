import OnrampCore
import Testing

// Expected results worked out by hand from munki's MunkiLooseVersion._compare, as used by upstream IA.
@Test(arguments: [
    ("10.6", "10.6.0", 0),
    ("4.32.0", "4.32", 0),
    ("", "0", 0),
    ("007", "7", 0),
    ("3.2.1", "3.2.1", 0),
    ("1.0", "1.0.1", -1),
    ("1.10", "1.9", 1),
    ("2.0.0", "10.0", -1),
    ("0.0.0.0.0", "1.0", -1), // upstream's "not installed" receipt version
    ("123.0.6312.86", "123.0.6312.122", -1),
    ("2024.1", "2023.12.31", 1),
    ("1.0.0.0.1", "1.0", 1),
    ("12345678901234567890123", "12345678901234567890124", -1), // beyond Int64
    ("1.0b2", "1.0b10", -1),
    ("1.0a", "1.0b", -1),
    ("1.0A", "1.0a", -1), // uppercase is an "other" part; "A" < "a" by code point
    // Text sorts after numbers, including the implicit 0 padding, so pre-releases compare greater.
    ("1.0b2", "1.0", 1),
    ("1.0-RC1", "1.0", 1),
    ("1.0 beta", "1.0", 1),
    ("1.2a3", "1.2.3", 1),
    ("1.0_2", "1.0.2", 1),
    ("abc", "1", 1),
])
func comparesLikeMunki(lhs: String, rhs: String, expected: Int) {
    #expect(LooseVersion.compare(LooseVersion(lhs), LooseVersion(rhs)) == expected)
    #expect(LooseVersion.compare(LooseVersion(rhs), LooseVersion(lhs)) == -expected)
}

@Test func operatorsFollowCompare() {
    #expect(LooseVersion("10.6") == LooseVersion("10.6.0"))
    #expect(LooseVersion("1.10") > LooseVersion("1.9"))
    #expect(LooseVersion("0.0.0.0.0") < LooseVersion("1.0"))
}
