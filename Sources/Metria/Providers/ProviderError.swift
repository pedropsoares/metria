import Foundation

/// Errors surfaced by usage providers when a request fails or a required
/// resource (credentials, session files) is unavailable.
enum ProviderError: Error, LocalizedError {
    case unavailable
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Provider data is unavailable."
        case .http(401):
            return "Authentication expired. Sign in again to refresh usage."
        case .http(403):
            return "The provider rejected the stored credentials."
        case .http(let status):
            return "The provider returned HTTP \(status)."
        case .rateLimited:
            return "The provider is rate limited."
        }
    }

    var retryAfter: TimeInterval? {
        switch self {
        case .rateLimited(let delay): return max(60, delay ?? 300)
        default: return nil
        }
    }
}
