import AppKit
import Combine
import Foundation
import SwiftUI
import MetriaCore

enum ProviderError: Error {
    case unavailable
    case http(Int)
}

extension ProviderKind {
    var symbol: String {
        switch self { case .claude: "sparkles"; case .codex: "hexagon"; case .openCodeGo: "globe.americas.fill" }
    }
    var logoName: String? {
        switch self { case .claude: "claude-logo"; case .codex: "codex-logo"; case .openCodeGo: "opencode-logo" }
    }
}

struct ClaudeProvider: UsageProvider {
    let kind = ProviderKind.claude
    func fetch() async -> ProviderFetchResult {
        do {
            let token = try await KeychainReader.readClaudeToken()
            let data = try await requestUsage(token: token)
            let value = try JSONDecoder().decode(ClaudeResponse.self, from: data)
            return .loaded(ProviderUsage(kind: kind, windows: [
                UsageWindow(title: "Current session", percent: value.fiveHour.utilization, resetDate: value.fiveHour.resetDate),
                UsageWindow(title: "All models", percent: value.sevenDay.utilization, resetDate: value.sevenDay.resetDate)
            ], updatedAt: Date(), error: nil))
        } catch { FileHandle.standardError.write("[Claude] error: \(error)\n".data(using: .utf8)!); return .failed(kind, error.localizedDescription) }
    }
    private func requestUsage(token: String) async throws -> Data {
        for attempt in 0..<3 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? -1
            guard status == 429 else {
                guard status == 200 else { throw ProviderError.http(status) }
                return data
            }
            guard attempt < 2 else { throw ProviderError.http(status) }
            let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt + 1))
            try? await Task.sleep(for: .seconds(min(retryAfter, 30)))
        }
        throw ProviderError.unavailable
    }
    private struct ClaudeResponse: Decodable {
        let fiveHour: Limit
        let sevenDay: Limit
        enum CodingKeys: String, CodingKey { case fiveHour = "five_hour"; case sevenDay = "seven_day" }
        struct Limit: Decodable {
            let utilization: Double
            let resetsAt: String?
            var resetDate: Date? {
                guard let resetsAt else { return nil }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: resetsAt) ?? {
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.date(from: resetsAt)
                }()
            }
            enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
        }
    }
}

struct CodexProvider: UsageProvider {
    let kind = ProviderKind.codex
    func fetch() async -> ProviderFetchResult {
        if let usage = await fetchOpenCodeUsage() { return usage }
        FileHandle.standardError.write("[Codex] falling back to local session files\n".data(using: .utf8)!)
        return fetchLocalUsage()
    }
    private func fetchOpenCodeUsage() async -> ProviderFetchResult? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/auth.json")
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

struct OpenCodeGoProvider: UsageProvider {
    let kind = ProviderKind.openCodeGo

    func fetch() async -> ProviderFetchResult {
        do {
            let key = try readAPIKey()
            var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { throw ProviderError.unavailable }
            let usage = try JSONDecoder().decode(OpenCodeGoResponse.self, from: data).usage
            return .loaded(ProviderUsage(kind: kind, windows: [
                UsageWindow(title: "Current session", percent: usage.rolling.percent, resetDate: usage.rolling.resetDate),
                UsageWindow(title: "This week", percent: usage.weekly.percent, resetDate: usage.weekly.resetDate),
                UsageWindow(title: "This month", percent: usage.monthly.percent, resetDate: usage.monthly.resetDate)
            ], updatedAt: Date(), error: nil))
        } catch {
            return .failed(kind, error.localizedDescription)
        }
    }

    private func readAPIKey() throws -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/auth.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OpenCodeAuth.self, from: data).openCodeGo.key
    }

    private struct OpenCodeAuth: Decodable {
        let openCodeGo: Credentials

        enum CodingKeys: String, CodingKey { case openCodeGo = "opencode-go" }
    }

    private struct Credentials: Decodable { let key: String }

    private struct OpenCodeGoResponse: Decodable {
        let usage: Usage

        struct Usage: Decodable {
            let rolling: Limit
            let weekly: Limit
            let monthly: Limit
        }

        struct Limit: Decodable {
            let percent: Double
            let resetsAt: String

            var resetDate: Date? {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: resetsAt)
            }
        }
    }
}

enum KeychainReader {
    static func readClaudeToken() async throws -> String {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProviderError.unavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let credentials = try JSONDecoder().decode(ClaudeCredentials.self, from: data)
        return credentials.claudeAiOauth.accessToken
    }
    private struct ClaudeCredentials: Decodable { let claudeAiOauth: OAuth; struct OAuth: Decodable { let accessToken: String } }
}

struct GaugeColor { static func color(for percent: Double) -> Color { percent >= 85 ? .red : percent >= 65 ? .orange : percent >= 40 ? .yellow : .green } }

struct ProviderLogo: View {
    let provider: ProviderKind
    let size: CGFloat

    var body: some View {
        if let image = provider.logo {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.symbol)
                .font(.system(size: size * 0.7, weight: .light))
        }
    }
}

extension ProviderKind {
    var logo: NSImage? {
        guard let logoName, let url = Bundle.module.url(forResource: logoName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var sidebarProgressGradient: LinearGradient {
        switch self {
        case .claude:
            LinearGradient(colors: [.orange, .orange], startPoint: .leading, endPoint: .trailing)
        case .codex:
            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .openCodeGo:
            LinearGradient(colors: [.white, .white], startPoint: .leading, endPoint: .trailing)
        }
    }
}

struct RingGauge: View {
    let usage: ProviderUsage
    var body: some View {
        let percent = usage.primary?.percent ?? 0
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color(white: 0.19), lineWidth: 8)
                Circle().trim(from: 0, to: percent / 100).stroke(GaugeColor.color(for: percent), style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                ProviderLogo(provider: usage.kind, size: 25).foregroundStyle(.white)
            }.frame(width: 70, height: 70)
            Text("\(Int(percent.rounded()))% ").font(.system(size: 25, weight: .medium, design: .rounded)).foregroundStyle(.white)
        }
    }
}

struct UsageCard: View {
    let usage: ProviderUsage
    var width: CGFloat = 390
    private var isCompact: Bool { width < 350 }
    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 10 : 18) {
            HStack(spacing: isCompact ? 6 : 10) { ProviderLogo(provider: usage.kind, size: isCompact ? 17 : 24); Text(usage.kind.rawValue).font(.system(size: isCompact ? 15 : 22, weight: .medium)); Spacer(); Circle().fill(usage.error == nil ? .green : .orange).frame(width: isCompact ? 5 : 7, height: isCompact ? 5 : 7) }
            ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
                    HStack { Text(window.title); Spacer(); Text(window.resetText).foregroundStyle(.secondary) }.font(.system(size: isCompact ? 10 : 15))
                    GeometryReader { proxy in ZStack(alignment: .leading) { Capsule().fill(Color(white: 0.17)); Capsule().fill(GaugeColor.color(for: window.percent)).frame(width: proxy.size.width * window.percent / 100) } }.frame(height: isCompact ? 5 : 7)
                    Text("\(Int(window.percent.rounded()))% Used").font(.system(size: isCompact ? 11 : 15))
                }
            }
            if let error = usage.error { Text(error).font(.system(size: isCompact ? 9 : 12)).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(.horizontal, isCompact ? 14 : 24).padding(.vertical, isCompact ? 16 : 28).frame(width: width).background(.black).clipShape(RoundedRectangle(cornerRadius: isCompact ? 16 : 24)).foregroundStyle(.white)
    }
}

extension UsageWindow { var resetText: String { guard let resetDate else { return "No reset data" }; let seconds = resetDate.timeIntervalSinceNow; if seconds > 0 && seconds < 86400 { return "Resets in \(Int(seconds / 60)) min" }; return "Resets \(resetDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))" } }

struct PopoverContent: View {
    @ObservedObject var store: UsageStore
    var body: some View { VStack(spacing: 0) { ScrollView { VStack(alignment: .leading, spacing: 20) { HStack(spacing: 22) { ForEach(store.providers) { RingGauge(usage: $0) } }.padding(.horizontal, 18).padding(.top, 20); ForEach(store.providers) { UsageCard(usage: $0) } }.padding(.horizontal, 12) }; HStack { Text("Updated \(Date().formatted(.dateTime.hour().minute()))").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Refresh") { store.refresh() }.buttonStyle(.plain).focusable(false).foregroundStyle(.white) }.padding(.horizontal, 18).padding(.vertical, 16) }.background(Color.black) }
}

struct SidebarContent: View {
    @ObservedObject var store: UsageStore
    let dockSide: DockSide
    let onSwitchToMenuBar: () -> Void
    let onOpenSettings: () -> Void
    let onDragMove: (CGFloat) -> Void
    let onSidebarHover: (Bool) -> Void
    @State private var hoveredProvider: ProviderKind?
    @State private var hoveredProviderIndex: Int?
    @State private var lastDragScreenLocation: CGPoint?
    @State private var isRevealed = false

    private var isRight: Bool { dockSide == .right }
    private let providerHeight: CGFloat = 56
    private let providerSpacing: CGFloat = 12
    private let dockTopPadding: CGFloat = 28
    private let dockControlsSpacing: CGFloat = 28
    private let dockControlsHeight: CGFloat = 16
    private let dockBottomPadding: CGFloat = 16
    private var visibleProviders: [ProviderUsage] {
        ProviderKind.allCases
            .filter { store.enabledProviderKinds.contains($0) }
            .map { kind in
                store.providers.first(where: { $0.kind == kind })
                    ?? ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: nil)
            }
    }
    private var dockHeight: CGFloat {
        dockTopPadding
            + CGFloat(visibleProviders.count) * providerHeight
            + CGFloat(max(visibleProviders.count - 1, 0)) * providerSpacing
            + dockControlsSpacing
            + dockControlsHeight
            + dockBottomPadding
    }
    private var pointerOffsetY: CGFloat {
        guard let hoveredProviderIndex else { return 0 }
        return -dockHeight / 2
            + dockTopPadding
            + providerHeight / 2
            + CGFloat(hoveredProviderIndex) * (providerHeight + providerSpacing)
    }

    // Real gap between the card and the dock; the pointer bridges across it below.
    private let cardGap: CGFloat = 16

    var body: some View {
        ZStack(alignment: isRight ? .trailing : .leading) {
            // Fixes the ZStack's own size to exactly 420x420 so the dock's
            // alignment is resolved against a deterministic box — without this,
            // the cardSlot's 324pt phantom width (present even at rest) makes
            // the ZStack's natural size ambiguous, causing the dock to sit
            // flush against one edge but with extra gap on the other.
            Color.clear.allowsHitTesting(false)
            dock
            cardSlot
                .frame(width: 324, alignment: isRight ? .trailing : .leading)
                .offset(x: isRight ? -96 : 96, y: pointerOffsetY)
        }
        .frame(width: 420, height: 420, alignment: isRight ? .trailing : .leading)
        .coordinateSpace(name: "sidebar")
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { isRevealed = true }
        }
        .onHover { isInside in
            if !isInside {
                withAnimation(.easeIn(duration: 0.12)) {
                    hoveredProvider = nil
                    hoveredProviderIndex = nil
                }
            }
        }
    }

    @ViewBuilder private var cardSlot: some View {
        if let hoveredProvider,
           let usage = visibleProviders.first(where: { $0.kind == hoveredProvider }) {
            UsageCard(usage: usage, width: 300)
                .onHover(perform: onSidebarHover)
                .overlay(alignment: isRight ? .trailing : .leading) {
                    // Offset by exactly the HStack gap so the tip lands right on the dock's edge.
                        SidebarPointer(pointsLeft: !isRight)
                            .fill(.black)
                            .frame(width: cardGap + 4, height: 34)
                            .offset(x: isRight ? cardGap : -cardGap)
                }
                .transition(.move(edge: isRight ? .trailing : .leading).combined(with: .opacity))
        } else {
            Color.clear
        }
    }

    private var dock: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: dockTopPadding)
            VStack(spacing: providerSpacing) {
                ForEach(Array(visibleProviders.enumerated()), id: \.element.id) { index, usage in
                    SidebarProviderItem(usage: usage)
                        .frame(width: 80, height: providerHeight)
                        .onHover { isHovering in
                            if isHovering {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    hoveredProvider = usage.kind
                                    hoveredProviderIndex = index
                                }
                            }
                        }
                }
            }
            Color.clear.frame(height: dockControlsSpacing)
            HStack(spacing: 20) {
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.58))
                }
                .buttonStyle(.plain)

                // Hides the floating sidebar and switches usage display to the menu bar.
                Button(action: onSwitchToMenuBar) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.58))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .frame(height: dockControlsHeight)
            .padding(.bottom, dockBottomPadding)
        }
        .frame(width: 80, height: dockHeight)
        .onHover(perform: onSidebarHover)
        .opacity(isRevealed ? 1 : 0)
        .scaleEffect(isRevealed ? 1 : 0.86, anchor: isRight ? .trailing : .leading)
        .background(Color.black)
        .clipShape(isRight ? AnyShape(RightDockShape()) : AnyShape(LeftDockShape()))
        // Press anywhere on the sidebar and drag vertically to reposition it on screen.
        // Horizontal movement is intentionally ignored; the Settings dialog controls the dock side.
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    let current = NSEvent.mouseLocation
                    if let last = lastDragScreenLocation {
                        onDragMove(current.y - last.y)
                    }
                    lastDragScreenLocation = current
                }
                .onEnded { _ in lastDragScreenLocation = nil }
        )
    }
}

/// The sidebar is fixed to the right edge of the screen; kept as an enum since the
/// dock's mirrored shapes (`LeftDockShape`/`RightDockShape`) still branch on it.
enum DockSide: String {
    case left
    case right
}

/// Type-erased shape so the dock's `.clipShape` can switch between the left- and
/// right-docked corner shapes at runtime.
struct AnyShape: Shape {
    private let makePath: @Sendable (CGRect) -> Path
    init<S: Shape>(_ shape: S) { makePath = { shape.path(in: $0) } }
    func path(in rect: CGRect) -> Path { makePath(rect) }
}

struct SidebarProviderItem: View {
    let usage: ProviderUsage

    var body: some View {
        let percent = usage.primary?.percent ?? 0
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color(white: 0.18), lineWidth: 5)
                Circle().trim(from: 0, to: percent / 100)
                    .stroke(usage.kind.sidebarProgressGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                ProviderLogo(provider: usage.kind, size: 14).foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
    }
}

struct SidebarPointer: Shape {
    var pointsLeft: Bool = false

    func path(in rect: CGRect) -> Path {
        Path { path in
            if pointsLeft {
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            } else {
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            path.closeSubpath()
        }
    }
}

/// Rounded corners on the left side only, flush against the screen's right edge.
struct RightDockShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + 34, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + 34, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 34), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 34))
            path.addQuadCurve(to: CGPoint(x: rect.minX + 34, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

/// Mirror of `RightDockShape`: rounded corners on the right side only, flush
/// against the screen's left edge.
struct LeftDockShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX - 34, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - 34, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - 34), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 34))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - 34, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

/// The two display modes are mutually exclusive: usage either appears in the
/// floating sidebar, or as text in the macOS menu bar.
enum DisplayMode: String {
    case sidebar
    case menuBar
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    let displayMode: DisplayMode
    let onSelectDisplayMode: (DisplayMode) -> Void
    @State private var sidebarOpacity: Double
    let onChangeSidebarOpacity: (Double) -> Void
    let onQuit: () -> Void

    init(
        store: UsageStore,
        displayMode: DisplayMode,
        onSelectDisplayMode: @escaping (DisplayMode) -> Void,
        sidebarOpacity: Double,
        onChangeSidebarOpacity: @escaping (Double) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.displayMode = displayMode
        self.onSelectDisplayMode = onSelectDisplayMode
        _sidebarOpacity = State(initialValue: sidebarOpacity)
        self.onChangeSidebarOpacity = onChangeSidebarOpacity
        self.onQuit = onQuit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings").font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text("Display").font(.system(size: 13, weight: .medium))
                Picker("", selection: Binding(get: { displayMode }, set: onSelectDisplayMode)) {
                    Text("Floating sidebar").tag(DisplayMode.sidebar)
                    Text("Menu bar").tag(DisplayMode.menuBar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Only one option is visible at a time: the floating sidebar or the menu bar text.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sidebar opacity").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(sidebarOpacity * 100))%")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $sidebarOpacity, in: 0.35...1)
                    .onChange(of: sidebarOpacity) { onChangeSidebarOpacity($0) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Providers").font(.system(size: 13, weight: .medium))
                ForEach(ProviderKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { store.enabledProviderKinds.contains(kind) },
                        set: { store.setProviderEnabled(kind, isEnabled: $0) }
                    )) {
                        HStack(spacing: 8) {
                            ProviderLogo(provider: kind, size: 18)
                            Text(kind.rawValue).font(.system(size: 12))
                        }
                    }
                    .toggleStyle(.switch)
                }
                Text("At least one provider must remain enabled.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Auto refresh").font(.system(size: 13, weight: .medium))
                Stepper(value: $store.refreshInterval, in: 60...1800, step: 60) {
                    Text("Every \(Int(store.refreshInterval / 60)) min")
                        .font(.system(size: 12))
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Exit", role: .destructive, action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
            }
        }
        .padding(24)
        .frame(width: 360, height: 500)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore(providers: [ClaudeProvider(), CodexProvider(), OpenCodeGoProvider()]); var statusItem: NSStatusItem!; var popover: NSPopover!; var sidebarWindow: NSPanel!; var settingsWindow: NSWindow?; var observation: AnyCancellable?
    private var isSidebarHovered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
        configureStatusItem()
        configurePopover()
        configureSidebar()
        observation = store.$providers.sink { [weak self] providers in self?.updateStatusItem(providers) }
        applyDisplayMode()
    }

    private func updateStatusItem(_ providers: [ProviderUsage]) {
        let title = NSMutableAttributedString()
        let usages = providers.sorted { $0.kind.rawValue < $1.kind.rawValue }.filter { $0.primary != nil }

        for (index, usage) in usages.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  ·  ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
            }
            if let logo = usage.kind.logo {
                let attachment = NSTextAttachment()
                attachment.image = logo
                attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " "))
            }
            let name = usage.kind == .openCodeGo ? "Go" : usage.kind.rawValue
            title.append(NSAttributedString(string: "\(name) \(Int(usage.primary!.percent.rounded()))%", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
        }
        statusItem.button?.image = nil
        statusItem.button?.attributedTitle = usages.isEmpty ? NSAttributedString(string: "--") : title
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = nil
        statusItem.button?.title = "--"
        statusItem.button?.font = .systemFont(ofSize: 13, weight: .semibold)
        let menu = NSMenu()
        menu.addItem(withTitle: "Open dashboard", action: #selector(togglePopover), keyEquivalent: "")
        menu.addItem(withTitle: "Floating mode", action: #selector(switchToSidebar), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func configurePopover() { popover = NSPopover(); popover.behavior = .transient; popover.contentSize = NSSize(width: 440, height: 700); popover.contentViewController = NSHostingController(rootView: PopoverContent(store: store)) }

    private static let sidebarWidth: CGFloat = 420
    private static let sidebarHeight: CGFloat = 420
    private static let sidebarHorizontalInset: CGFloat = 40

    private func configureSidebar() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
        let windowWidth = Self.sidebarWidth; let windowHeight = Self.sidebarHeight
        let x = dockSide == .right ? visibleFrame.maxX - windowWidth - Self.sidebarHorizontalInset : visibleFrame.minX + Self.sidebarHorizontalInset
        let origin = NSPoint(x: x, y: visibleFrame.maxY - windowHeight - 20)
        sidebarWindow = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        sidebarWindow.level = .floating
        sidebarWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sidebarWindow.isOpaque = false
        sidebarWindow.alphaValue = sidebarOpacity
        sidebarWindow.backgroundColor = .clear
        sidebarWindow.hasShadow = false
        sidebarWindow.contentViewController = NSHostingController(rootView: SidebarContent(
            store: store,
            dockSide: dockSide,
            onSwitchToMenuBar: switchToMenuBar,
            onOpenSettings: openSettings,
            onDragMove: moveSidebar,
            onSidebarHover: { [weak self] isHovering in self?.setSidebarHovering(isHovering) }
        ))
        sidebarWindow.setFrame(NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight)), display: true)
    }

    // Keep the full interaction window inside the visible screen while dragging so the dock
    // cannot disappear beyond an edge before the final snap.
    private func moveSidebar(byDeltaY deltaY: CGFloat) {
        guard let sidebarWindow else { return }
        var frame = sidebarWindow.frame
        let visibleFrame = NSScreen.main?.visibleFrame ?? frame
        frame.origin.y = min(max(frame.origin.y + deltaY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        sidebarWindow.setFrameOrigin(frame.origin)
    }

    // Fixed to the right edge; no longer user-configurable (removed from Settings
    // because switching sides at runtime could leave the window with an incorrect offset).
    private let dockSide: DockSide = .right

    private var sidebarOpacity: Double {
        get { UserDefaults.standard.object(forKey: "sidebarOpacity") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarOpacity") }
    }

    private func setSidebarOpacity(_ opacity: Double) {
        sidebarOpacity = opacity
        sidebarWindow?.alphaValue = isSidebarHovered ? 1 : opacity
    }

    private func setSidebarHovering(_ isHovering: Bool) {
        isSidebarHovered = isHovering
        guard let sidebarWindow else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            sidebarWindow.animator().alphaValue = isHovering ? 1 : sidebarOpacity
        }
    }

    // The two modes are mutually exclusive: only one is visible at a time.
    private var displayMode: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .sidebar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "displayMode") }
    }

    private func applyDisplayMode() {
        switch displayMode {
        case .sidebar:
            animateSidebarIn()
            statusItem.isVisible = false
        case .menuBar:
            sidebarWindow.orderOut(nil)
            statusItem.isVisible = true
        }
    }

    private func animateSidebarIn() {
        guard let sidebarWindow else { return }
        let visibleFrame = NSScreen.main?.visibleFrame ?? sidebarWindow.frame
        let targetX = dockSide == .right ? visibleFrame.maxX - sidebarWindow.frame.width - Self.sidebarHorizontalInset : visibleFrame.minX + Self.sidebarHorizontalInset
        let targetOrigin = NSPoint(x: targetX, y: sidebarWindow.frame.origin.y)
        let entranceOffset: CGFloat = dockSide == .right ? 42 : -42
        sidebarWindow.alphaValue = 0
        sidebarWindow.setFrameOrigin(NSPoint(x: targetX + entranceOffset, y: targetOrigin.y))
        sidebarWindow.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sidebarWindow.animator().alphaValue = sidebarOpacity
            sidebarWindow.animator().setFrameOrigin(targetOrigin)
        }
    }

    @objc private func switchToMenuBar() { displayMode = .menuBar; applyDisplayMode() }
    @objc private func switchToSidebar() { displayMode = .sidebar; applyDisplayMode() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        let window = settingsWindow ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            return window
        }()
        window.contentViewController = NSHostingController(rootView: SettingsView(
            store: store,
            displayMode: displayMode,
            onSelectDisplayMode: { [weak self] mode in
                guard let self else { return }
                self.displayMode = mode
                self.applyDisplayMode()
            },
            sidebarOpacity: sidebarOpacity,
            onChangeSidebarOpacity: { [weak self] opacity in self?.setSidebarOpacity(opacity) },
            onQuit: { [weak self] in self?.quit() }
        ))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // In sidebar mode the status item is invisible, so there's no valid button to anchor
    // the popover to; in that case it's anchored to the floating sidebar's own content view.
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        if statusItem.isVisible, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let contentView = sidebarWindow.contentView {
            popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minX)
        }
    }
}

@main struct MetriaApp: App { @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate; var body: some Scene { Settings { EmptyView() } } }
