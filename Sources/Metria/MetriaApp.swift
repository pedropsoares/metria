import AppKit
import Combine
import CoreImage
import CryptoKit
import Foundation
import ServiceManagement
import SwiftUI
import MetriaCore

private struct MetriaSnapshot: Encodable {
    struct Provider: Encodable {
        let name: String
        let percent: Double
        let resetDate: Date?
    }

    let updatedAt: Date
    let providers: [Provider]
}

/// Stores the pairing master secret in the macOS Keychain. The secret never leaves the
/// Mac in plaintext: the PWA only ever receives it via the QR code or 12-word phrase,
/// both of which the user controls when and how to share.
enum PairingKeychain {
    private static let service = "com.metria.pairing"
    private static let account = "ntfy-pairing-secret"

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func save(_ secret: Data) -> Bool {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func loadOrGenerate() -> Data {
        if let existing = load() { return existing }
        let generated = PairingSecret.generate()
        save(generated)
        return generated
    }

    static func regenerate() -> Data {
        let generated = PairingSecret.generate()
        save(generated)
        return generated
    }
}

private extension Data {
    /// URL-safe base64 without padding, so the secret can sit in a URL fragment without
    /// needing percent-encoding.
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Owns the pairing secret's presentation: the QR code and the 12-word phrase shown in
/// Settings, plus the shareable link. The secret itself lives in `PairingKeychain`.
@MainActor final class PairingManager: ObservableObject {
    static let defaultRemotePWAURL = "https://metria-pwa.yuriramos2406.workers.dev"

    @Published private(set) var words: [String] = []
    @Published private(set) var qrImage: NSImage?
    private var secret: Data = Data()
    var currentSecret: Data { secret }
    var currentSnapshotToken: String { secret.base64URLEncodedString }

    init() {
        secret = PairingKeychain.loadOrGenerate()
        words = PairingSecret.words(from: secret)
    }

    func regenerate() {
        secret = PairingKeychain.regenerate()
        words = PairingSecret.words(from: secret)
    }

    func pairingLink(pwaBaseURL: String, ntfyServer: String) -> String {
        let encodedServer = ntfyServer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ntfyServer
        return "\(pwaBaseURL)/#s=\(secret.base64URLEncodedString)&server=\(encodedServer)"
    }

    func refreshQRCode(pwaBaseURL: String, ntfyServer: String) {
        qrImage = Self.renderQRCode(for: pairingLink(pwaBaseURL: pwaBaseURL, ntfyServer: ntfyServer))
    }

    private static func renderQRCode(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

@MainActor private final class NtfyPublisher {
    private let defaults = UserDefaults.standard
    private var lastPayload: Data?
    var onSnapshot: ((Data) -> Void)?

    func publish(_ providers: [ProviderUsage], secret: Data) {
        guard let server = URL(string: defaults.string(forKey: "ntfyServer") ?? "https://ntfy.sh"),
              server.scheme == "https", server.host != nil else { return }

        let snapshot = MetriaSnapshot(
            updatedAt: Date(),
            providers: providers.compactMap { usage in
                guard let primary = usage.primary else { return nil }
                return .init(name: usage.kind.rawValue, percent: primary.percent, resetDate: primary.resetDate)
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(snapshot), payload != lastPayload else { return }
        onSnapshot?(payload)

        let topic = PairingSecret.topic(from: secret)
        let key = PairingSecret.encryptionKey(from: secret)
        guard let sealed = try? AES.GCM.seal(payload, using: key), let combined = sealed.combined else { return }
        lastPayload = payload
        let encryptedSnapshot = combined.base64EncodedData()

        var request = URLRequest(url: server.appendingPathComponent(topic))
        request.httpMethod = "POST"
        request.httpBody = encryptedSnapshot
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("low", forHTTPHeaderField: "Priority")
        Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}

struct GaugeColor {
    static func color(for percent: Double) -> Color { Color(nsColor: nsColor(for: percent)) }
    static func nsColor(for percent: Double) -> NSColor { percent >= 85 ? .systemRed : percent >= 65 ? .systemOrange : percent >= 40 ? .systemYellow : .systemGreen }
}

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

struct UsageCard: View {
    let usage: ProviderUsage
    var width: CGFloat = 390
    var scale: CGFloat = 1
    private var isCompact: Bool { width < 390 }
    var body: some View {
        VStack(alignment: .leading, spacing: (isCompact ? 10 : 18) * scale) {
            HStack(spacing: (isCompact ? 6 : 10) * scale) { ProviderLogo(provider: usage.kind, size: (isCompact ? 17 : 24) * scale); Text(usage.kind.rawValue).font(.system(size: (isCompact ? 15 : 22) * scale, weight: .medium)); Spacer(); Circle().fill(usage.error == nil ? .green : .orange).frame(width: (isCompact ? 5 : 7) * scale, height: (isCompact ? 5 : 7) * scale) }
            if usage.windows.isEmpty {
                Label(usage.error ?? "Waiting for usage data...", systemImage: usage.error == nil ? "clock" : "exclamationmark.triangle.fill")
                    .font(.system(size: (isCompact ? 10 : 13) * scale))
                    .foregroundStyle(usage.error == nil ? Color.secondary : Color.orange)
                    .lineLimit(3)
            } else {
                ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: (isCompact ? 5 : 8) * scale) {
                        HStack { Text(window.title); Spacer(); Text(window.resetText).foregroundStyle(.secondary) }.font(.system(size: (isCompact ? 10 : 15) * scale))
                        GeometryReader { proxy in ZStack(alignment: .leading) { Capsule().fill(Color(white: 0.17)); Capsule().fill(GaugeColor.color(for: window.percent)).frame(width: proxy.size.width * window.percent / 100) } }.frame(height: (isCompact ? 5 : 7) * scale)
                        Text("\(Int(window.percent.rounded()))% Used").font(.system(size: (isCompact ? 11 : 15) * scale))
                    }
                }
            }
            if let error = usage.error { Text(error).font(.system(size: (isCompact ? 9 : 12) * scale)).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(.horizontal, (isCompact ? 14 : 24) * scale).padding(.vertical, (isCompact ? 16 : 28) * scale).frame(width: width).background(.black).clipShape(RoundedRectangle(cornerRadius: (isCompact ? 16 : 24) * scale)).foregroundStyle(.white)
    }
}

extension UsageWindow {
    var resetText: String {
        guard let resetDate else { return "No reset data" }
        let seconds = resetDate.timeIntervalSinceNow

        if seconds > 0 && seconds < 86400 {
            let totalMinutes = Int(seconds / 60)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60

            if hours > 0 {
                return minutes > 0 ? "Resets in \(hours) hr \(minutes) min" : "Resets in \(hours) hr"
            }

            return "Resets in \(minutes) min"
        }

        return "Resets \(resetDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
    }
}

struct DashboardUsageCard: View {
    let usage: ProviderUsage

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if usage.windows.isEmpty {
                    Label(usage.error ?? "Waiting for usage data...", systemImage: usage.error == nil ? "clock" : "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(usage.error == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(window.title)
                                Spacer()
                                Text("\(Int(window.percent.rounded()))%")
                                    .foregroundStyle(GaugeColor.color(for: window.percent))
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                            ProgressView(value: min(max(window.percent, 0), 100), total: 100)
                                .tint(GaugeColor.color(for: window.percent))
                            Text(window.resetText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = usage.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        } label: {
            HStack(spacing: 8) {
                ProviderLogo(provider: usage.kind, size: 20)
                Text(usage.kind.rawValue)
                Spacer()
                if usage.error == nil {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PopoverContent: View {
    @ObservedObject var store: UsageStore

    private var visibleProviders: [ProviderUsage] {
        ProviderKind.allCases
            .filter { store.enabledProviderKinds.contains($0) && store.isProviderAvailable($0) }
            .map { kind in
                store.providers.first(where: { $0.kind == kind })
                    ?? ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: nil)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dashboard").font(.title2.weight(.semibold))
                    Text("AI coding assistant usage").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: store.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if visibleProviders.isEmpty {
                        Label("No providers are available yet. Sign in to a supported provider and refresh.", systemImage: "externaldrive.badge.questionmark")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(visibleProviders) { DashboardUsageCard(usage: $0) }
                    }
                }
            }

            Divider()

            Text("Updated \(Date().formatted(.dateTime.hour().minute()))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440, height: 700)
    }
}

/// Resolves where the side notch sits: flush against the right edge of the screen,
/// hanging from just below the real menu bar (using `visibleFrame` rather than the
/// physical notch's `safeAreaInsets`, since a screen edge isn't hardware — this keeps
/// it clear of the menu bar's own icons and, on notched Macs, clear of the real notch).
struct NotchGeometry {
    private let rightEdgeX: CGFloat
    private let topAnchorY: CGFloat

    static func current() -> NotchGeometry {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NotchGeometry(rightEdgeX: 0, topAnchorY: 0)
        }
        let rightEdgeX = screen.frame.maxX
        let topAnchorY = screen.visibleFrame.maxY - 12
        return NotchGeometry(rightEdgeX: rightEdgeX, topAnchorY: topAnchorY)
    }

    /// A frame of the given size, still flush against the right edge and still hanging
    /// from the same top anchor — used to compute the expanded shelf's frame so it
    /// grows leftward and downward from the idle rail instead of jumping around.
    func frame(width: CGFloat, height: CGFloat, verticalOffset: CGFloat = 0) -> CGRect {
        CGRect(x: rightEdgeX - width, y: topAnchorY - height + verticalOffset, width: width, height: height)
    }
}

enum NotchSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: 0.85
        case .medium: 1
        case .large: 1.15
        }
    }
}

struct NotchMetrics {
    let scale: CGFloat

    init(size: NotchSize) { scale = size.scale }

    var idleWidth: CGFloat { 80 * scale }
    var compactHeight: CGFloat { 236 * scale }
    var hoverHeight: CGFloat { 280 * scale }
    var hiddenWidth: CGFloat { 10 * scale }
    var hiddenHeight: CGFloat { 80 * scale }
    var cornerRadius: CGFloat { 20 * scale }
    var providerItemHeight: CGFloat { 64 * scale }
    var providerSpacing: CGFloat { 10 * scale }
    var cardSpacing: CGFloat { 12 * scale }
    var cardWidth: CGFloat { 316 * scale }
    var cardContentWidth: CGFloat { 300 * scale }
    var controlsSpacing: CGFloat { 14 * scale }
    var controlsHeight: CGFloat { 16 * scale }
    var controlsGap: CGFloat { 8 * scale }
    var controlsBottomSpace: CGFloat { 20 * scale }
}

/// Shared visibility state so the view and the window-level click routing stay in sync
/// without relying on SwiftUI `Button` actions, which are unreliable in a non-activating
/// borderless panel.
@MainActor final class NotchMode: ObservableObject {
    @Published var isHiddenMode = UserDefaults.standard.bool(forKey: "hiddenNotch")
    @Published var size = NotchSize(rawValue: UserDefaults.standard.string(forKey: "notchSize") ?? "") ?? .medium
}

/// The floating surface itself: a compact provider rail flush against the right screen
/// edge while idle, which grows leftward and downward into a shelf on hover. Both states
/// share the same flush-right, rounded-left shape so the surface reads as attached to
/// the screen rather than as a floating rectangle.
struct NotchContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var mode: NotchMode
    let onNotchHover: (Bool) -> Void
    let onProviderHover: (ProviderKind, Int, Bool) -> Void
    @State private var isHovered = false
    @State private var pendingHoverCollapse: DispatchWorkItem?

    private var isHiddenMode: Bool { mode.isHiddenMode }
    private var metrics: NotchMetrics { NotchMetrics(size: mode.size) }

    private var visibleProviders: [ProviderUsage] {
        ProviderKind.allCases
            .filter { store.enabledProviderKinds.contains($0) && store.isProviderAvailable($0) }
            .map { kind in
                store.providers.first(where: { $0.kind == kind })
                    ?? ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: nil)
            }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            UnevenRoundedRectangle(
                topLeadingRadius: metrics.cornerRadius,
                bottomLeadingRadius: metrics.cornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(.black)
            .frame(
                width: isHiddenMode && !isHovered ? metrics.hiddenWidth : metrics.idleWidth,
                height: isHiddenMode && !isHovered
                    ? metrics.hiddenHeight
                    : isHovered ? metrics.hoverHeight : metrics.compactHeight,
                alignment: .topTrailing
            )
            .onHover { isInside in
                pendingHoverCollapse?.cancel()
                if isInside {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        isHovered = true
                    }
                    onNotchHover(true)
                } else {
                    let collapse = DispatchWorkItem {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                            isHovered = false
                        }
                        onNotchHover(false)
                    }
                    pendingHoverCollapse = collapse
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: collapse)
                }
            }

            if !isHiddenMode || isHovered {
                compactProviders
                    .frame(width: metrics.idleWidth, alignment: .topTrailing)
            }

            if isHovered {
                controls
                    .frame(width: metrics.idleWidth, height: metrics.controlsHeight)
                    .offset(y: metrics.compactHeight + metrics.controlsGap)
                    .transition(.opacity)
            }
        }
        .frame(width: metrics.idleWidth, height: metrics.hoverHeight, alignment: .topTrailing)
    }

    private var compactProviders: some View {
        VStack(spacing: metrics.providerSpacing) {
            ForEach(Array(visibleProviders.enumerated()), id: \.element.id) { index, usage in
                SidebarProviderItem(usage: usage, scale: metrics.scale)
                    .frame(width: metrics.idleWidth, height: metrics.providerItemHeight)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        onProviderHover(usage.kind, index, isHovering)
                    }
            }
        }
        .padding(.vertical, 12 * metrics.scale)
    }

    private var controls: some View {
        HStack(spacing: metrics.controlsSpacing) {
            Spacer()
            Image(systemName: "gearshape")
                .font(.system(size: 13 * metrics.scale))
                .foregroundStyle(Color(white: 0.58))
            Image(systemName: isHiddenMode ? "pin.fill" : "arrow.right")
                .font(.system(size: 13 * metrics.scale))
                .foregroundStyle(Color(white: 0.58))
                .accessibilityLabel(isHiddenMode ? "Pin notch" : "Hide notch")
            Spacer()
        }
        .frame(height: metrics.controlsHeight)
    }
}

struct NotchCardContent: View {
    let usage: ProviderUsage
    let metrics: NotchMetrics
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            UsageCard(usage: usage, width: metrics.cardContentWidth, scale: metrics.scale)
            SideNotchPointer()
                .fill(.black)
                .frame(width: 16 * metrics.scale, height: 34 * metrics.scale)
        }
        .onHover(perform: onHover)
    }
}

struct SideNotchPointer: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// Captures taps on the two bottom controls directly at the window level, since SwiftUI
/// `Button` actions can be dropped in a non-activating borderless panel. Also captures
/// vertical drags before child SwiftUI views can consume them.
final class DraggableNotchPanel: NSPanel {
    var metrics = NotchMetrics(size: .medium)
    var onDragMove: ((CGFloat) -> Void)?
    var onGearTap: (() -> Void)?
    var onEyeTap: (() -> Void)?
    private var lastMouseY: CGFloat?
    private var didDrag = false
    private var didHandleControlTap = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            didDrag = false
            didHandleControlTap = routeControlTap(at: event.locationInWindow)
            lastMouseY = event.locationInWindow.y
        case .leftMouseDragged:
            didDrag = true
            if let lastMouseY {
                let currentMouseY = event.locationInWindow.y
                onDragMove?(currentMouseY - lastMouseY)
                self.lastMouseY = currentMouseY
            }
        case .leftMouseUp:
            if !didDrag && !didHandleControlTap { _ = routeControlTap(at: event.locationInWindow) }
            didHandleControlTap = false
            lastMouseY = nil
        default:
            break
        }
        super.sendEvent(event)
    }

    // The controls sit right below the provider stack. In window coordinates (origin at
    // the bottom-left) that band spans from `hoverHeight - compactHeight - gap - controlsHeight`
    // up to `hoverHeight - compactHeight - gap`.
    @discardableResult
    private func routeControlTap(at point: NSPoint) -> Bool {
        let controlsTop = metrics.hoverHeight - (metrics.compactHeight + metrics.controlsGap)
        let controlsBottom = controlsTop - metrics.controlsHeight
        guard point.y >= controlsBottom, point.y <= controlsTop else { return false }
        if point.x < metrics.idleWidth / 2 { onGearTap?() } else { onEyeTap?() }
        return true
    }
}

/// Keeps the rail's rounded corners transparent to the rest of the menu bar.
final class NotchHostingView: NSHostingView<NotchContent> {
    var isHovered = false
    var isHiddenMode = false
    var metrics = NotchMetrics(size: .medium)

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsVisibleSurface(point) else { return nil }
        return super.hitTest(point)
    }

    private func containsVisibleSurface(_ point: NSPoint) -> Bool {
        let topBasedY = isFlipped ? point.y : bounds.height - point.y
        let surfaceWidth = isHiddenMode && !isHovered ? metrics.hiddenWidth : metrics.idleWidth
        let surfaceHeight = isHiddenMode && !isHovered
            ? metrics.hiddenHeight
            : isHovered ? metrics.hoverHeight : metrics.compactHeight
        let x = bounds.width - point.x
        let radius = min(metrics.cornerRadius, surfaceWidth / 2, surfaceHeight / 2)

        guard x >= 0, x <= surfaceWidth, topBasedY >= 0, topBasedY <= surfaceHeight else { return false }
        guard x <= surfaceWidth - radius else { return true }

        let topCorner = CGPoint(x: surfaceWidth - radius, y: radius)
        let bottomCorner = CGPoint(x: surfaceWidth - radius, y: surfaceHeight - radius)
        let cornerCenter = topBasedY < surfaceHeight / 2 ? topCorner : bottomCorner
        let distanceX = x - cornerCenter.x
        let distanceY = topBasedY - cornerCenter.y
        return distanceX * distanceX + distanceY * distanceY <= radius * radius
    }
}

struct SidebarProviderItem: View {
    let usage: ProviderUsage
    let scale: CGFloat

    var body: some View {
        let percent = usage.primary?.percent ?? 0
        VStack(spacing: 3 * scale) {
            ZStack {
                Circle().stroke(Color(white: 0.18), lineWidth: 5 * scale)
                Circle().trim(from: 0, to: percent / 100)
                     .stroke(usage.kind.sidebarProgressGradient, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                ProviderLogo(provider: usage.kind, size: 14 * scale).foregroundStyle(.white)
            }
            .frame(width: 38 * scale, height: 38 * scale)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 11 * scale, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
    }
}

/// The two display modes are mutually exclusive: usage either appears in the
/// floating notch, or as text in the macOS menu bar.
enum DisplayMode: String {
    case sidebar
    case menuBar
}

enum LaunchAtLoginManager {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) -> String? {
        guard isAvailable else {
            return "Launch at login is available after installing Metria as an app in Applications."
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return "Metria could not update its launch-at-login setting: \(error.localizedDescription)"
        }

        if enabled, SMAppService.mainApp.status == .requiresApproval {
            return "Metria was added, but macOS requires approval. Open System Settings > General > Login Items and allow Metria."
        }
        return nil
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case providers
    case iPhone

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .iPhone: "iPhone"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .providers: "square.stack.3d.up"
        case .iPhone: "iphone"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var pairing: PairingManager
    let displayMode: DisplayMode
    let onSelectDisplayMode: (DisplayMode) -> Void
    let notchSize: NotchSize
    let onSelectNotchSize: (NotchSize) -> Void
    @State private var sidebarOpacity: Double
    let onChangeSidebarOpacity: (Double) -> Void
    @State private var launchAtLoginEnabled: Bool
    let onChangeLaunchAtLogin: (Bool) -> String?
    let onQuit: () -> Void
    let onReconnect: (ProviderKind) -> Void
    @State private var ntfyServer: String
    let onChangeServer: (String) -> Void
    let localPWAURL: () -> String?
    @State private var localServerPort: String
    let onChangeLocalServerPort: (UInt16) -> Void
    @State private var customPWAURL: String
    let onChangeCustomPWAURL: (String) -> Void
    let onRegeneratePairing: () -> Void
    @State private var isPhraseRevealed = false
    @State private var isRegenerateConfirmationShown = false
    @State private var isDiagnosticShown = false
    @State private var diagnosticMessage = ""
    @State private var isReconnectShown = false
    @State private var reconnectMessage = ""
    @State private var launchAtLoginMessage: String?
    @State private var selectedSection: SettingsSection = .general

    init(
        store: UsageStore,
        pairing: PairingManager,
        displayMode: DisplayMode,
        onSelectDisplayMode: @escaping (DisplayMode) -> Void,
        notchSize: NotchSize,
        onSelectNotchSize: @escaping (NotchSize) -> Void,
        sidebarOpacity: Double,
        onChangeSidebarOpacity: @escaping (Double) -> Void,
        launchAtLoginEnabled: Bool,
        onChangeLaunchAtLogin: @escaping (Bool) -> String?,
        onQuit: @escaping () -> Void,
        onReconnect: @escaping (ProviderKind) -> Void,
        ntfyServer: String,
        onChangeServer: @escaping (String) -> Void,
        localPWAURL: @escaping () -> String?,
        localServerPort: UInt16,
        onChangeLocalServerPort: @escaping (UInt16) -> Void,
        customPWAURL: String,
        onChangeCustomPWAURL: @escaping (String) -> Void,
        onRegeneratePairing: @escaping () -> Void
    ) {
        self.store = store
        self.pairing = pairing
        self.displayMode = displayMode
        self.onSelectDisplayMode = onSelectDisplayMode
        self.notchSize = notchSize
        self.onSelectNotchSize = onSelectNotchSize
        _sidebarOpacity = State(initialValue: sidebarOpacity)
        self.onChangeSidebarOpacity = onChangeSidebarOpacity
        _launchAtLoginEnabled = State(initialValue: launchAtLoginEnabled)
        self.onChangeLaunchAtLogin = onChangeLaunchAtLogin
        self.onQuit = onQuit
        self.onReconnect = onReconnect
        _ntfyServer = State(initialValue: ntfyServer)
        self.onChangeServer = onChangeServer
        self.localPWAURL = localPWAURL
        _localServerPort = State(initialValue: String(localServerPort))
        self.onChangeLocalServerPort = onChangeLocalServerPort
        _customPWAURL = State(initialValue: customPWAURL)
        self.onChangeCustomPWAURL = onChangeCustomPWAURL
        self.onRegeneratePairing = onRegeneratePairing
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Metria")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView
                .navigationTitle(selectedSection.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 500, idealHeight: 580)
    }

    @ViewBuilder private var detailView: some View {
        switch selectedSection {
        case .general: generalView
        case .providers: providersView
        case .iPhone: iPhoneView
        }
    }

    private var generalView: some View {
        Form {
            Section("Display") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Show usage in")
                        .font(.headline)
                    Picker("Show usage in", selection: Binding(get: { displayMode }, set: onSelectDisplayMode)) {
                        Text("Notch").tag(DisplayMode.sidebar)
                        Text("Menu bar").tag(DisplayMode.menuBar)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Text("Only one option is visible at a time.")
                    .foregroundStyle(.secondary)
            }

            Section("Notch") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Size")
                        .font(.headline)
                    Picker("Size", selection: Binding(get: { notchSize }, set: onSelectNotchSize)) {
                        ForEach(NotchSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Opacity")
                        .font(.headline)
                    HStack {
                        Slider(value: $sidebarOpacity, in: 0.35...1)
                            .onChange(of: sidebarOpacity) { onChangeSidebarOpacity($0) }
                        Text("\(Int(sidebarOpacity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("Applies to the usage card; the provider rail always stays fully opaque so it reads as part of the display.")
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Stepper(value: $store.refreshInterval, in: 60...1800, step: 60) {
                    Text("Refresh every \(Int(store.refreshInterval / 60)) min")
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { enabled in
                        if let message = onChangeLaunchAtLogin(enabled) {
                            launchAtLoginMessage = message
                        } else {
                            launchAtLoginEnabled = enabled
                        }
                    }
                ))
                Text("Metria will start automatically and remain available in the menu bar.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Exit", role: .destructive, action: onQuit)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Launch at login", isPresented: Binding(
            get: { launchAtLoginMessage != nil },
            set: { if !$0 { launchAtLoginMessage = nil } }
        )) {
            Button("OK", role: .cancel) { launchAtLoginMessage = nil }
        } message: {
            Text(launchAtLoginMessage ?? "")
        }
    }

    private var providersView: some View {
        Form {
            ForEach(ProviderKind.allCases) { kind in
                Section {
                    Toggle("Use this provider", isOn: Binding(
                        get: { store.enabledProviderKinds.contains(kind) },
                        set: { store.setProviderEnabled(kind, isEnabled: $0) }
                    ))
                    .disabled(!store.isProviderAvailable(kind))

                    HStack {
                        Button("Diagnose") {
                            diagnosticMessage = store.diagnosis(for: kind)
                            isDiagnosticShown = true
                        }
                        Button("Reconnect") {
                            onReconnect(kind)
                            reconnectMessage = "The login command for \(kind.rawValue) was sent to Terminal. If it did not start automatically, paste this command:\n\n\(kind.reconnectCommand)"
                            isReconnectShown = true
                        }
                        Spacer()
                    }
                    .controlSize(.small)

                    if let usage = store.providers.first(where: { $0.kind == kind }) {
                        if let error = usage.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                        if let updatedAt = usage.updatedAt {
                            Text("Last update: \(updatedAt.formatted(.dateTime.hour().minute()))")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label {
                        Text(kind.rawValue)
                    } icon: {
                        ProviderLogo(provider: kind, size: 18)
                    }
                } footer: {
                    if !store.isProviderAvailable(kind), let hint = store.setupHint(for: kind) {
                        Text(hint)
                    } else {
                        Text("Reconnect opens the provider's sign-in flow in Terminal.")
                    }
                }
            }

            Text("At least one provider must remain enabled.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Provider diagnosis", isPresented: $isDiagnosticShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticMessage)
        }
        .alert("Reconnect provider", isPresented: $isReconnectShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reconnectMessage)
        }
    }

    private var iPhoneView: some View {
        Form {
            Section("Pair your iPhone") {
                if let qrImage = pairing.qrImage {
                    HStack {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                        Spacer()
                    }
                }

                HStack {
                    Text(isPhraseRevealed ? pairing.words.joined(separator: " ") : String(repeating: "•", count: 44))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(isPhraseRevealed ? "Hide" : "Show") { isPhraseRevealed.toggle() }
                }

                HStack(spacing: 10) {
                    Button("Copy phrase") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.words.joined(separator: " "), forType: .string)
                    }
                    Button("Copy link") {
                        guard let pwaBaseURL = localPWAURL() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.pairingLink(pwaBaseURL: pwaBaseURL, ntfyServer: ntfyServer), forType: .string)
                    }
                    Spacer()
                    Button("Regenerate", role: .destructive) { isRegenerateConfirmationShown = true }
                }
                .controlSize(.small)
            }

            Section("Connection") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ntfy server")
                        .font(.headline)
                    TextField("https://ntfy.sh", text: $ntfyServer)
                        .onSubmit { onChangeServer(ntfyServer) }
                }
            }

            Section("PWA hosting") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local address")
                        .font(.headline)
                    Text(localPWAURL() ?? "Starting local server…")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local server port")
                        .font(.headline)
                    TextField("8973", text: $localServerPort)
                        .onSubmit {
                            guard let port = UInt16(localServerPort), port > 0 else { return }
                            onChangeLocalServerPort(port)
                        }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom PWA URL")
                        .font(.headline)
                    TextField("https://...", text: $customPWAURL)
                        .onSubmit { onChangeCustomPWAURL(customPWAURL) }
                }
                Text("Leave Custom PWA URL empty to pair through this Mac on the same Wi-Fi network. Use an HTTPS URL to keep remote access and PWA installation.")
                    .foregroundStyle(.secondary)
            }

            Text("Scan the QR code with your iPhone camera, or open the PWA and enter the phrase. The local address must be reachable from your iPhone.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Regenerate pairing?", isPresented: $isRegenerateConfirmationShown) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                onRegeneratePairing()
            }
        } message: {
            Text("Any iPhone using the current QR code or phrase will stop receiving updates.")
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore(providers: ProviderRegistry.makeProviders()); var statusItem: NSStatusItem!; var popover: NSPopover!; var sidebarWindow: NSPanel!; var settingsWindow: NSWindow?; var observation: AnyCancellable?; private let ntfyPublisher = NtfyPublisher(); let pairing = PairingManager(); private let updater = AppUpdater(); private let localPWAServer = LocalPWAServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
        configureStatusItem()
        configurePopover()
        configureSidebar()
        localPWAServer.setSnapshotToken(pairing.currentSnapshotToken)
        ntfyPublisher.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.localPWAServer.updateSnapshot(snapshot)
        }
        ntfyPublisher.publish(store.providers, secret: pairing.currentSecret)
        localPWAServer.onURLChange = { [weak self] in self?.refreshPairingQRCode() }
        localPWAServer.start(preferredPort: localServerPort)
        observation = store.$providers.sink { [weak self] providers in
            self?.updateStatusItem(providers)
            guard let self else { return }
            self.ntfyPublisher.publish(providers, secret: self.pairing.currentSecret)
        }
        applyDisplayMode()
    }

    private var ntfyServer: String {
        get { UserDefaults.standard.string(forKey: "ntfyServer") ?? "https://ntfy.sh" }
        set { UserDefaults.standard.set(newValue, forKey: "ntfyServer") }
    }

    private var localServerPort: UInt16 {
        get {
            let port = UserDefaults.standard.integer(forKey: "localPWAServerPort")
            return UInt16(port == 0 ? 8973 : port)
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "localPWAServerPort") }
    }

    private var customPWAURL: String {
        get { UserDefaults.standard.object(forKey: "customPWAURL") as? String ?? PairingManager.defaultRemotePWAURL }
        set { UserDefaults.standard.set(newValue, forKey: "customPWAURL") }
    }

    private var pwaBaseURL: String? {
        let customURL = customPWAURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: customURL), url.scheme == "https", url.host != nil {
            return customURL.hasSuffix("/") ? String(customURL.dropLast()) : customURL
        }
        return localPWAServer.baseURL?.absoluteString
    }

    private func refreshPairingQRCode() {
        guard let pwaBaseURL else { return }
        pairing.refreshQRCode(pwaBaseURL: pwaBaseURL, ntfyServer: ntfyServer)
    }

    private func regeneratePairing() {
        pairing.regenerate()
        localPWAServer.setSnapshotToken(pairing.currentSnapshotToken)
        refreshPairingQRCode()
        ntfyPublisher.publish(store.providers, secret: pairing.currentSecret)
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
            let percent = usage.primary!.percent
            title.append(NSAttributedString(string: "\(name) ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
            let percentageAttributes: [NSAttributedString.Key: Any] = percent >= 40
                ? [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: GaugeColor.nsColor(for: percent)]
                : [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            title.append(NSAttributedString(string: "\(Int(percent.rounded()))%", attributes: percentageAttributes))
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
        if updater.isConfigured {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
            menu.items.last?.target = updater
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func configurePopover() { popover = NSPopover(); popover.behavior = .transient; popover.contentSize = NSSize(width: 440, height: 700); popover.contentViewController = NSHostingController(rootView: PopoverContent(store: store)) }

    private var notchGeometry = NotchGeometry.current()
    private let notchMode = NotchMode()
    private var notchMetrics: NotchMetrics { NotchMetrics(size: notchMode.size) }
    private var cardWindow: NSPanel?
    private var activeCardProvider: ProviderKind?
    private var activeCardIndex = 0
    private var isRailHovered = false
    private var isCardHovered = false
    private var pendingCardDismiss: DispatchWorkItem?

    private func configureSidebar() {
        notchGeometry = NotchGeometry.current()
        let windowFrame = notchGeometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchYOffset)
        let notchPanel = DraggableNotchPanel(contentRect: windowFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        sidebarWindow = notchPanel
        notchPanel.metrics = notchMetrics
        notchPanel.onDragMove = { [weak self] deltaY in self?.moveNotch(by: deltaY) }
        notchPanel.onGearTap = { [weak self] in self?.openSettings() }
        notchPanel.onEyeTap = { [weak self] in
            guard let self else { return }
            self.setHiddenNotch(!self.notchMode.isHiddenMode)
        }
        sidebarWindow.level = .statusBar
        sidebarWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sidebarWindow.isOpaque = false
        sidebarWindow.alphaValue = sidebarOpacity
        sidebarWindow.backgroundColor = .clear
        sidebarWindow.hasShadow = false
        sidebarWindow.isMovable = false
        sidebarWindow.contentView = makeHostingView()
        sidebarWindow.setFrame(windowFrame, display: true)

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // Building a fresh hosting view resets the SwiftUI hover state so that, on hiding,
    // the rail truly collapses to the slim bar instead of staying expanded under the cursor.
    private func makeHostingView() -> NotchHostingView {
        let content = NotchContent(
            store: store,
            mode: notchMode,
            onNotchHover: { [weak self] isHovered in self?.setRailHovered(isHovered) },
            onProviderHover: { [weak self] provider, index, isHovered in
                self?.setProviderHovered(provider, index: index, isHovered: isHovered)
            }
        )
        let hostingView = NotchHostingView(rootView: content)
        hostingView.isHiddenMode = notchMode.isHiddenMode
        hostingView.metrics = notchMetrics
        return hostingView
    }

    // Displays can be connected/disconnected or change resolution at any time; recompute
    // the notch's real position and snap back to it unless the shelf is mid-interaction.
    @objc private func screenParametersDidChange() {
        notchGeometry = NotchGeometry.current()
        guard let sidebarWindow else { return }
        let windowFrame = notchGeometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchYOffset)
        sidebarWindow.setFrame(windowFrame, display: true)
        if activeCardProvider != nil {
            positionCard(index: activeCardIndex)
        }
    }

    private var notchYOffset: CGFloat {
        get { UserDefaults.standard.object(forKey: "notchPositionY") as? CGFloat ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "notchPositionY") }
    }

    // Keep the side notch inside the visible frame while dragging, and preserve the
    // offset so the user's preferred vertical position survives relaunches.
    private func moveNotch(by deltaY: CGFloat) {
        guard let sidebarWindow else { return }
        let visibleFrame = NSScreen.main?.visibleFrame ?? sidebarWindow.frame
        var frame = sidebarWindow.frame
        frame.origin.y = min(max(frame.origin.y + deltaY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        sidebarWindow.setFrameOrigin(frame.origin)

        let defaultFrame = notchGeometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight)
        notchYOffset = frame.origin.y - defaultFrame.origin.y
        if activeCardProvider != nil { positionCard(index: activeCardIndex) }
    }

    private func setRailHovered(_ isHovered: Bool) {
        isRailHovered = isHovered
        (sidebarWindow?.contentView as? NotchHostingView)?.isHovered = isHovered
        if isHovered {
            pendingCardDismiss?.cancel()
        } else {
            scheduleCardDismiss()
        }
    }

    private func setHiddenNotch(_ isHidden: Bool) {
        UserDefaults.standard.set(isHidden, forKey: "hiddenNotch")
        guard notchMode.isHiddenMode != isHidden else { return }
        notchMode.isHiddenMode = isHidden
        isCardHovered = false
        activeCardProvider = nil
        cardWindow?.orderOut(nil)
        if isHidden {
            isRailHovered = false
            // Fresh view resets the SwiftUI hover state so the rail collapses at once.
            sidebarWindow?.contentView = makeHostingView()
        }
    }

    private func setNotchSize(_ size: NotchSize) {
        guard notchMode.size != size else { return }
        notchMode.size = size
        UserDefaults.standard.set(size.rawValue, forKey: "notchSize")
        (sidebarWindow as? DraggableNotchPanel)?.metrics = notchMetrics
        if let hostingView = sidebarWindow?.contentView as? NotchHostingView {
            hostingView.metrics = notchMetrics
            hostingView.needsLayout = true
        }
        sidebarWindow?.setFrame(notchGeometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchYOffset), display: true)
        if let activeCardProvider {
            showCard(for: activeCardProvider, index: activeCardIndex)
        }
    }

    private func setProviderHovered(_ provider: ProviderKind, index: Int, isHovered: Bool) {
        if isHovered {
            isRailHovered = true
            pendingCardDismiss?.cancel()
            showCard(for: provider, index: index)
        } else {
            scheduleCardDismiss()
        }
    }

    private func setCardHovered(_ isHovered: Bool) {
        isCardHovered = isHovered
        if isHovered {
            pendingCardDismiss?.cancel()
        } else {
            scheduleCardDismiss()
        }
    }

    private func scheduleCardDismiss() {
        pendingCardDismiss?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isRailHovered, !self.isCardHovered else { return }
            self.cardWindow?.orderOut(nil)
            self.activeCardProvider = nil
        }
        pendingCardDismiss = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func showCard(for provider: ProviderKind, index: Int) {
        let usage = store.providers.first(where: { $0.kind == provider })
            ?? ProviderUsage(kind: provider, windows: [], updatedAt: nil, error: nil)

        if cardWindow == nil {
            let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovable = false
            cardWindow = window
        }

        activeCardProvider = provider
        activeCardIndex = index
        let cardContent = NotchCardContent(usage: usage, metrics: notchMetrics) { [weak self] isHovered in
            self?.setCardHovered(isHovered)
        }
        cardWindow?.contentViewController = NSHostingController(rootView: cardContent)
        cardWindow?.layoutIfNeeded()
        let cardHeight = max(cardWindow?.contentViewController?.view.fittingSize.height ?? 0, 1)
        positionCard(index: index, height: cardHeight)
        cardWindow?.alphaValue = sidebarOpacity
        cardWindow?.orderFrontRegardless()
    }

    private func positionCard(index: Int, height: CGFloat? = nil) {
        guard let cardWindow else { return }
        let cardHeight = height ?? max(cardWindow.contentViewController?.view.fittingSize.height ?? 0, 1)
        let railFrame = notchGeometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.compactHeight, verticalOffset: notchYOffset)
        let providerCenterY = railFrame.maxY - 12 * notchMetrics.scale - notchMetrics.providerItemHeight / 2
            - CGFloat(index) * (notchMetrics.providerItemHeight + notchMetrics.providerSpacing)
        let visibleFrame = NSScreen.main?.visibleFrame ?? railFrame
        let originY = min(max(providerCenterY - cardHeight / 2, visibleFrame.minY + 8), visibleFrame.maxY - cardHeight - 8)
        let originX = railFrame.minX - notchMetrics.cardWidth - notchMetrics.cardSpacing
        cardWindow.setFrame(NSRect(x: originX, y: originY, width: notchMetrics.cardWidth, height: cardHeight), display: true)
    }

    private var sidebarOpacity: Double {
        get { UserDefaults.standard.object(forKey: "sidebarOpacity") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarOpacity") }
    }

    private func setSidebarOpacity(_ opacity: Double) {
        sidebarOpacity = opacity
        sidebarWindow?.alphaValue = opacity
        cardWindow?.alphaValue = opacity
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
            cardWindow?.orderOut(nil)
            statusItem.isVisible = true
        }
    }

    private func animateSidebarIn() {
        guard let sidebarWindow else { return }
        notchGeometry = NotchGeometry.current()
        isRailHovered = false
        isCardHovered = false
        activeCardProvider = nil
        cardWindow?.orderOut(nil)
        sidebarWindow.alphaValue = 0
        sidebarWindow.setFrame(notchGeometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchYOffset), display: true)
        sidebarWindow.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sidebarWindow.animator().alphaValue = sidebarOpacity
        }
    }

    @objc private func switchToMenuBar() { displayMode = .menuBar; applyDisplayMode() }
    @objc private func switchToSidebar() { displayMode = .sidebar; applyDisplayMode() }
    @objc func quit() { NSApp.terminate(nil) }

    private func reconnectProvider(_ kind: ProviderKind) {
        let command = kind.reconnectCommand
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = "tell application \"Terminal\" to do script \"\(escapedCommand)\""
        var scriptError: NSDictionary?
        let didOpenTerminal = NSAppleScript(source: scriptSource)?.executeAndReturnError(&scriptError) != nil
        if !didOpenTerminal {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }

    @objc private func openSettings() {
        let window = settingsWindow ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 580), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 680, height: 500)
            window.center()
            settingsWindow = window
            return window
        }()
        window.contentViewController = NSHostingController(rootView: SettingsView(
            store: store,
            pairing: pairing,
            displayMode: displayMode,
            onSelectDisplayMode: { [weak self] mode in
                guard let self else { return }
                self.displayMode = mode
                self.applyDisplayMode()
            },
            notchSize: notchMode.size,
            onSelectNotchSize: { [weak self] size in self?.setNotchSize(size) },
            sidebarOpacity: sidebarOpacity,
            onChangeSidebarOpacity: { [weak self] opacity in self?.setSidebarOpacity(opacity) },
            launchAtLoginEnabled: LaunchAtLoginManager.isEnabled,
            onChangeLaunchAtLogin: { enabled in LaunchAtLoginManager.setEnabled(enabled) },
            onQuit: { [weak self] in self?.quit() },
            onReconnect: { [weak self] kind in self?.reconnectProvider(kind) },
            ntfyServer: ntfyServer,
            onChangeServer: { [weak self] server in
                guard let self else { return }
                self.ntfyServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
                self.refreshPairingQRCode()
                self.store.refresh()
            },
            localPWAURL: { [weak self] in self?.pwaBaseURL },
            localServerPort: localServerPort,
            onChangeLocalServerPort: { [weak self] port in
                guard let self else { return }
                self.localServerPort = port
                self.localPWAServer.start(preferredPort: port)
            },
            customPWAURL: customPWAURL,
            onChangeCustomPWAURL: { [weak self] url in
                guard let self else { return }
                self.customPWAURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                self.refreshPairingQRCode()
            },
            onRegeneratePairing: { [weak self] in self?.regeneratePairing() }
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
