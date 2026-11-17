import OnrampCore
import Testing

// Contract test: these strings are referenced by deployed MDM profiles and launchd plists.
@Test func identifiersAreStable() {
    #expect(Identity.domain == "io.github.popaprozac.onramp")
    #expect(Identity.daemonLabel == "io.github.popaprozac.onramp.daemon")
}
