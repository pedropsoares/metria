import Foundation

/// Errors surfaced by usage providers when a request fails or a required
/// resource (credentials, session files) is unavailable.
enum ProviderError: Error {
    case unavailable
    case http(Int)
}
