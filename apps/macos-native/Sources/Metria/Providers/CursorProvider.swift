import Foundation
import MetriaCore

/// Fetches Cursor usage from the OAuth session the Cursor editor stores in its local
/// `state.vscdb` (a SQLite database shared with every VS Code-derived app). Cursor has no
/// public usage API, so this calls the same dashboard endpoints the web dashboard itself
/// uses, authenticated with the `WorkosCursorSessionToken` cookie the editor already holds.
struct CursorProvider: UsageProvider {
    let kind = ProviderKind.cursor
    var isAvailable: Bool { FileManager.default.fileExists(atPath: stateDBURL.path) }
    let setupHint = "Open Cursor and sign in to make usage available."
    let usageWindowTitles = ["All models", "Cursor models"]

    private var stateDBURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func fetch() async -> ProviderFetchResult {
        guard let session = readLocalSession(), let sub = decodeJWTSub(session.accessToken) else {
            return .empty(ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: "No Cursor session was found. Open Cursor and sign in to create local usage data."))
        }
        let cookie = encodeCookieValue("\(sub)::\(session.accessToken)")
        do {
            let usage = try await fetchPeriodUsage(cookie: cookie)
            let accountLabel = try? await fetchAccountEmail(cookie: cookie)
            return .loaded(ProviderUsage(
                kind: kind,
                accountLabel: accountLabel,
                planLabel: session.membershipType.map(displayPlanName),
                windows: [
                    UsageWindow(title: "All models", percent: usage.otherPercent, resetDate: usage.resetDate),
                    UsageWindow(title: "Cursor models", percent: usage.cursorPercent, resetDate: usage.resetDate)
                ], updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            return .failed(kind, error.localizedDescription, retryAfter: providerError?.retryAfter)
        }
    }

    // MARK: - Local session

    private struct LocalSession {
        let accessToken: String
        let membershipType: String?
    }

    /// Shells out to the system `sqlite3` CLI (bundled with macOS) instead of linking a
    /// SQLite driver, mirroring how `KeychainReader` shells out to `/usr/bin/security`.
    /// Reads the access token and the (undocumented) `stripeMembershipType` key the editor
    /// caches locally, so the plan badge needs no extra network round trip.
    private func readLocalSession() -> LocalSession? {
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else { return nil }
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [stateDBURL.path, "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/stripeMembershipType');"]
        process.standardOutput = output; process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var accessToken: String?
        var membershipType: String?
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "|") else { continue }
            let key = line[line.startIndex..<separator]
            let value = String(line[line.index(after: separator)...])
            if key == "cursorAuth/accessToken" { accessToken = value }
            else if key == "cursorAuth/stripeMembershipType" { membershipType = value }
        }
        guard let accessToken, !accessToken.isEmpty else { return nil }
        return LocalSession(accessToken: accessToken, membershipType: membershipType?.isEmpty == false ? membershipType : nil)
    }

    private func displayPlanName(_ raw: String) -> String {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "free": "Free"
        case "pro": "Pro"
        case "proplus": "Pro+"
        case "ultra": "Ultra"
        case "team": "Team"
        case "enterprise": "Enterprise"
        default: raw.capitalized
        }
    }

    private func decodeJWTSub(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["sub"] as? String
    }

    private static let cookieUnreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    /// Replicates JavaScript's `encodeURIComponent`, matching how the Cursor web dashboard
    /// itself encodes the `userId::accessToken` pair into the session cookie's value.
    private func encodeCookieValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.cookieUnreservedCharacters) ?? value
    }

    // MARK: - Dashboard API

    private func fetchPeriodUsage(cookie: String) async throws -> (cursorPercent: Double, otherPercent: Double, resetDate: Date?) {
        if let result = try? await fetchCurrentPeriodUsage(cookie: cookie) { return result }
        return try await fetchUsageSummary(cookie: cookie)
    }

    private func fetchCurrentPeriodUsage(cookie: String) async throws -> (Double, Double, Date?) {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [String: Any]())
        applyHeaders(to: &request, cookie: cookie, isPost: true)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw ProviderError.http(status) }
        let value = try JSONDecoder().decode(PeriodUsageResponse.self, from: data)
        guard let plan = value.planUsage, plan.autoPercentUsed != nil || plan.apiPercentUsed != nil else {
            throw ProviderError.unavailable
        }
        return (plan.autoPercentUsed ?? 0, plan.apiPercentUsed ?? 0, parseResetDate(value.billingCycleEnd))
    }

    private func fetchUsageSummary(cookie: String) async throws -> (Double, Double, Date?) {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        applyHeaders(to: &request, cookie: cookie, isPost: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw ProviderError.http(status) }
        let value = try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
        let plan = value.individualUsage?.plan
        return (plan?.autoPercentUsed ?? 0, plan?.apiPercentUsed ?? 0, parseResetDate(value.billingCycleEnd))
    }

    private func fetchAccountEmail(cookie: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/auth/me")!)
        applyHeaders(to: &request, cookie: cookie, isPost: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(AuthMeResponse.self, from: data).email
    }

    private func applyHeaders(to request: inout URLRequest, cookie: String, isPost: Bool) {
        // Cookie storage would otherwise silently override this manually-set header.
        request.httpShouldHandleCookies = false
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isPost {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("https://cursor.com/dashboard/usage", forHTTPHeaderField: "Referer")
        }
    }

    private func parseResetDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let milliseconds = Double(value) { return Date(timeIntervalSince1970: milliseconds / 1000) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }

    private struct PeriodUsageResponse: Decodable {
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let planUsage: PlanUsage?

        struct PlanUsage: Decodable {
            let autoPercentUsed: Double?
            let apiPercentUsed: Double?
        }
    }

    private struct UsageSummaryResponse: Decodable {
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let individualUsage: IndividualUsage?

        struct IndividualUsage: Decodable {
            let plan: Plan?

            struct Plan: Decodable {
                let autoPercentUsed: Double?
                let apiPercentUsed: Double?
            }
        }
    }

    private struct AuthMeResponse: Decodable {
        let email: String?
    }
}
