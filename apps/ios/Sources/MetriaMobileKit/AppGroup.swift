import Foundation
import MetriaCore

/// The App Group container the app and widget extension share for the cached snapshot.
/// Must match the entitlements declared in `apps/ios/project.yml`.
///
/// There is deliberately no Keychain access-group constant here: the entitled group is
/// `$(AppIdentifierPrefix)com.metria.shared`, whose prefix is the team identifier and so
/// is not known at compile time. `PairingStore.resolvedAccessGroup()` asks the Keychain
/// for the real, team-prefixed group at runtime instead and caches it in this App Group's
/// UserDefaults, so both targets pass the same explicit `kSecAttrAccessGroup` rather than
/// relying on implicit default-group resolution (which Apple's TN2415 warns against).
public enum MetriaAppGroup {
    public static let identifier = "group.com.metria.shared"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Settings both targets read. The widget extension has no UI of its own for them, so
    /// the app writes here and the extension picks the value up on its next render.
    public static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }

    public static var spendDisplay: SpendDisplay { SpendFormat.display(in: defaults) }
}
