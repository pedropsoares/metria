import Foundation
import MetriaCore

/// Fetches Codex usage, preferring the OpenCode-managed OpenAI credentials and falling
/// back to parsing local Codex CLI session files when those credentials are missing.
struct CodexProvider: UsageProvider {
    let kind = ProviderKind.codex
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: authURL.path) || FileManager.default.fileExists(atPath: sessionsURL.path)
    }
    let setupHint = "Sign in to Codex or OpenCode to create local usage data."

    private var authURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/auth.json") }
    private var sessionsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    func fetch() async -> ProviderFetchResult {
        if let usage = await fetchOpenCodeUsage() { return usage }
        FileHandle.standardError.write("[Codex] falling back to local session files\n".data(using: .utf8)!)
        return fetchLocalUsage()
    }
    private func fetchOpenCodeUsage() async -> ProviderFetchResult? {
        guard let data = try? Data(contentsOf: authURL) else { FileHandle.standardError.write("[Codex] cannot read auth.json at \(authURL.path)\n".data(using: .utf8)!); return nil }
        guard let auth = try? JSONDecoder().decode(OpenCodeAuth.self, from: data) else { FileHandle.standardError.write("[Codex] cannot decode auth.json\n".data(using: .utf8)!); return nil }
        guard let credentials = auth.openai else { FileHandle.standardError.write("[Codex] no openai key in auth.json\n".data(using: .utf8)!); return nil }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { FileHandle.standardError.write("[Codex] HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")\n".data(using: .utf8)!); return nil }
            let value = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
            return .loaded(ProviderUsage(kind: kind, windows: [
                UsageWindow(title: "Current session", percent: value.rateLimit.primaryWindow.usedPercent, resetDate: Date(timeIntervalSince1970: Double(value.rateLimit.primaryWindow.resetAt))),
                UsageWindow(title: "All models", percent: value.rateLimit.secondaryWindow.usedPercent, resetDate: Date(timeIntervalSince1970: Double(value.rateLimit.secondaryWindow.resetAt)))
            ], updatedAt: Date(), error: nil))
        } catch { FileHandle.standardError.write("[Codex] request/decode error: \(error)\n".data(using: .utf8)!); return nil }
    }
    private func fetchLocalUsage() -> ProviderFetchResult {
        let candidates = findCandidates()
        for candidate in candidates.sorted(by: { $0.0 > $1.0 }) {
            guard let text = try? String(contentsOf: candidate.1, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").reversed()
            for line in lines {
                guard line.contains("rate_limits"), let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = event["payload"] as? [String: Any] else { continue }
                let limits = (payload["rate_limits"] as? [String: Any]) ?? ((payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any])
                guard let limits else { continue }
                let primary = parseLimit(limits["primary"] as? [String: Any], title: "Current session")
                let secondary = parseLimit(limits["secondary"] as? [String: Any], title: "All models")
                return .loaded(ProviderUsage(kind: kind, windows: [primary, secondary].compactMap { $0 }, updatedAt: candidate.0, error: nil))
            }
        }
        return .empty(ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: nil))
    }
    private struct OpenCodeAuth: Decodable { let openai: Credentials?; struct Credentials: Decodable { let access: String; let accountId: String } }
    private struct OpenAIUsageResponse: Decodable {
        let rateLimit: RateLimit
        enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
        struct RateLimit: Decodable { let primaryWindow: Window; let secondaryWindow: Window; enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window" } }
        struct Window: Decodable { let usedPercent: Double; let resetAt: Int; enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case resetAt = "reset_at" } }
    }
    private func findCandidates() -> [(Date, URL)] {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var candidates: [(Date, URL)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil { candidates.append((date, url)) }
        }
        return candidates
    }
    private func parseLimit(_ raw: [String: Any]?, title: String) -> UsageWindow? {
        guard let raw, let percent = raw["used_percent"] as? Double else { return nil }
        let reset = (raw["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? (raw["resets_at"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
        return UsageWindow(title: title, percent: reset.map { $0 < Date() ? 0 : percent } ?? percent, resetDate: reset)
    }
}
