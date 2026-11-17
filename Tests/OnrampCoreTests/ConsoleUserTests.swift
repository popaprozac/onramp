import OnrampCore
import Testing

@Test(arguments: [
    ("zach", 501, true),
    ("loginwindow", 0, false),
    ("_mbsetupuser", 248, false),  // Setup Assistant during ADE
    ("root", 0, false),
    ("hidden-admin", 499, false),  // a system-range account, not a person's session
    ("loginwindow", 501, false),
    ("_mbsetupuser", 501, false),
] as [(String, UInt32, Bool)])
func onlyAPersonsSessionCounts(name: String, uid: UInt32, real: Bool) {
    #expect(ConsoleUser(name: name, uid: uid).isRealUser == real)
}
