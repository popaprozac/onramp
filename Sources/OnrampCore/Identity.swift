/// Identifiers that MDM profiles and launchd plists depend on. Changing any of these breaks deployed profiles.
public enum Identity {
    public static let version = "0.1.0-alpha.1"

    /// Bundle identifier and managed-preferences domain.
    public static let domain = "io.github.popaprozac.onramp"
    public static let daemonLabel = domain + ".daemon"
}
