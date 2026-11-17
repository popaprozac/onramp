/// Identifiers that MDM profiles and launchd plists depend on. Changing any of these breaks deployed profiles.
public enum Identity {
    public static let version = "0.1.0-dev"

    /// Bundle identifier and managed-preferences domain.
    public static let domain = "io.github.popaprozac.onramp"
    public static let daemonLabel = domain + ".daemon"
    public static let agentLabel = domain + ".agent"
    public static let machServiceName = domain + ".xpc"
}
