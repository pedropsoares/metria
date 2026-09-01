import Foundation

/// The App Group container the app and widget extension share for the cached snapshot.
/// Must match the entitlements declared in `apps/ios/project.yml`.
///
/// There is deliberately no Keychain access-group constant here: the entitled group is
/// `$(AppIdentifierPrefix)com.metria.shared`, whose prefix is the team identifier and so
/// is not known at compile time. `PairingStore` therefore omits `kSecAttrAccessGroup`
/// entirely and lets the item land in the first entitled group, which both targets
/// declare identically — that is what makes the widget able to read what the app wrote.
public enum MetriaAppGroup {
    public static let identifier = "group.com.metria.shared"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
