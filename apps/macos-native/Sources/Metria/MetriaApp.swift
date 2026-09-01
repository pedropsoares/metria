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
    private var publishTask: Task<Void, Never>?
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
        // Superseding an in-flight publish is safe: `lastPayload` above already reflects
        // the newest snapshot, so a cancelled older request is not losing data.
        publishTask?.cancel()
        publishTask = Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    deinit {
        publishTask?.cancel()
    }
}

struct GaugeColor {
    static func color(for percent: Double) -> Color { Color(nsColor: nsColor(for: percent)) }
    static func nsColor(for percent: Double) -> NSColor { percent >= 85 ? .systemRed : percent >= 65 ? .systemOrange : percent >= 40 ? .systemYellow : .systemGreen }
}

struct MenuBarAlertSettings {
    var cautionThreshold: Int
    var warningThreshold: Int
    var criticalThreshold: Int
    var cautionColor: NSColor
    var warningColor: NSColor
    var criticalColor: NSColor

    static let `default` = Self(
        cautionThreshold: 40,
        warningThreshold: 65,
        criticalThreshold: 85,
        cautionColor: .systemYellow,
        warningColor: .systemOrange,
        criticalColor: .systemRed
    )
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

struct NotchVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct UsageCard: View {
    let usage: ProviderUsage
    var width: CGFloat = 390
    var scale: CGFloat = 1
    private var isCompact: Bool { width < 390 }
    /// The progress bar's available width, mirroring this view's own horizontal padding
    /// so it no longer needs a `GeometryReader` (and the extra layout pass that comes
    /// with one) just to size itself.
    private var barWidth: CGFloat { width - 2 * (isCompact ? 14 : 24) * scale }
    var body: some View {
        VStack(alignment: .leading, spacing: (isCompact ? 10 : 18) * scale) {
            HStack(spacing: (isCompact ? 6 : 10) * scale) { ProviderLogo(provider: usage.kind, size: (isCompact ? 17 : 24) * scale); Text(usage.kind.rawValue).font(.system(size: (isCompact ? 15 : 22) * scale, weight: .medium)); Spacer(); Circle().fill(usage.error == nil ? .green : .orange).frame(width: (isCompact ? 5 : 7) * scale, height: (isCompact ? 5 : 7) * scale) }
            if usage.windows.isEmpty {
                Label(usage.error ?? "Waiting for usage data...", systemImage: usage.error == nil ? "clock" : "exclamationmark.triangle.fill")
                    .font(.system(size: (isCompact ? 10 : 13) * scale))
                    .foregroundStyle(usage.error == nil ? Color.secondary : Color.orange)
                    .lineLimit(3)
            } else {
                ForEach(usage.windows) { window in
                    VStack(alignment: .leading, spacing: (isCompact ? 5 : 8) * scale) {
                        HStack { Text(window.title); Spacer(); Text(window.resetText).foregroundStyle(.secondary) }.font(.system(size: (isCompact ? 10 : 15) * scale))
                        ZStack(alignment: .leading) { Capsule().fill(Color(white: 0.17)); Capsule().fill(GaugeColor.color(for: window.percent)).frame(width: max(0, barWidth * window.percent / 100)) }.frame(height: (isCompact ? 5 : 7) * scale)
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
                    ForEach(usage.windows) { window in
                        let color = window.percent >= 40 ? GaugeColor.color(for: window.percent) : Color.primary
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(window.title)
                                Spacer()
                                Text("\(Int(window.percent.rounded()))%")
                                    .foregroundStyle(color)
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                            ProgressView(value: min(max(window.percent, 0), 100), total: 100)
                                .tint(color)
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
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

struct PopoverContent: View {
    @ObservedObject var store: UsageStore

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
                    if store.visibleProviders.isEmpty {
                        Label("No providers are available yet. Sign in to a supported provider and refresh.", systemImage: "externaldrive.badge.questionmark")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(store.visibleProviders) { DashboardUsageCard(usage: $0) }
                    }
                }
            }

            Divider()

            Text("Updated \(Date().formatted(.dateTime.hour().minute()))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
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

    static func current(for screen: NSScreen? = nil) -> NotchGeometry {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
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
    var hoverHeight: CGFloat { compactHeight + (controlsHeight + controlsGap + controlsBottomSpace) * 2 }
    var hiddenWidth: CGFloat { 18 * scale }
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
    let backgroundOpacity: Double
    let menuBarAlertSettings: MenuBarAlertSettings
    let onNotchHover: (Bool) -> Void
    let onProviderHover: (ProviderKind, Int, Bool) -> Void
    @State private var isHovered = false
    @State private var hasAppeared = false
    @State private var pendingHoverCollapse: DispatchWorkItem?

    private var isHiddenMode: Bool { mode.isHiddenMode }
    private var metrics: NotchMetrics { NotchMetrics(size: mode.size) }
    private var railHoverOffset: CGFloat { metrics.controlsHeight + metrics.controlsGap + metrics.controlsBottomSpace }

    var body: some View {
        ZStack(alignment: .topTrailing) {
             NotchVisualEffect()
                 .opacity(backgroundOpacity)
                 .frame(
                     width: isHiddenMode && !isHovered ? metrics.hiddenWidth : metrics.idleWidth,
                     height: isHiddenMode && !isHovered
                         ? metrics.hiddenHeight
                         : isHovered ? metrics.hoverHeight : metrics.compactHeight,
                     alignment: .topTrailing
                 )
                 .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: metrics.cornerRadius,
                    bottomLeadingRadius: metrics.cornerRadius,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                ))
             .overlay {
             UnevenRoundedRectangle(
                        topLeadingRadius: metrics.cornerRadius,
                        bottomLeadingRadius: metrics.cornerRadius,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                     )
                     .fill(.black.opacity(0.72 * backgroundOpacity))
                 }
                 .offset(y: isHovered ? 0 : railHoverOffset)
            /*
             The native visual effect view is required here because the notch is
             hosted in an AppKit panel outside the normal SwiftUI window hierarchy.
             */
            UnevenRoundedRectangle(
                topLeadingRadius: metrics.cornerRadius,
                bottomLeadingRadius: metrics.cornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(.black.opacity(0.24 * backgroundOpacity))
             .frame(
                width: isHiddenMode && !isHovered ? metrics.hiddenWidth : metrics.idleWidth,
                height: isHiddenMode && !isHovered
                    ? metrics.hiddenHeight
                    : isHovered ? metrics.hoverHeight : metrics.compactHeight,
                alignment: .topTrailing
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: metrics.cornerRadius,
                    bottomLeadingRadius: metrics.cornerRadius,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                 .stroke(.white.opacity(0.14), lineWidth: 1)
              }
              .offset(y: isHovered ? 0 : railHoverOffset)
              if !isHiddenMode || isHovered {
                 compactProviders
                     .frame(width: metrics.idleWidth, alignment: .topTrailing)
                     .offset(y: railHoverOffset)
             }

             if isHovered {
                 topControls
                     .frame(width: metrics.idleWidth, height: metrics.controlsHeight)
                     .offset(y: metrics.controlsBottomSpace)
                     .transition(.opacity)
                 bottomControls
                     .frame(width: metrics.idleWidth, height: metrics.controlsHeight)
                     .offset(y: metrics.controlsHeight + metrics.controlsGap + metrics.controlsBottomSpace + metrics.compactHeight + metrics.controlsGap)
                     .transition(.opacity)
             }
        }
        .frame(
            width: metrics.idleWidth,
            height: isHiddenMode && !isHovered
                ? metrics.hiddenHeight
                : isHovered ? metrics.hoverHeight : metrics.compactHeight,
            alignment: .topTrailing
        )
        .contentShape(
            UnevenRoundedRectangle(
                topLeadingRadius: metrics.cornerRadius,
                bottomLeadingRadius: metrics.cornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
        .frame(width: metrics.idleWidth, height: metrics.hoverHeight, alignment: .topTrailing)
        .opacity(hasAppeared ? 1 : 0)
        .offset(x: hasAppeared ? 0 : 18 * metrics.scale)
        .onAppear {
            withAnimation(.easeOut(duration: 0.32).delay(0.15)) {
                hasAppeared = true
            }
        }
        .onHover { isInside in
            pendingHoverCollapse?.cancel()
            if isInside {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    isHovered = true
                }
                onNotchHover(true)
            } else {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    isHovered = false
                }
                onNotchHover(false)
            }
        }
    }

    private var compactProviders: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.visibleProviders.enumerated()), id: \.element.id) { index, usage in
                let rowHeight = metrics.providerItemHeight + (index < store.visibleProviders.count - 1 ? metrics.providerSpacing : 0)
                 SidebarProviderItem(usage: usage, scale: metrics.scale, alertSettings: menuBarAlertSettings)
                    .frame(width: metrics.idleWidth, height: metrics.providerItemHeight)
                    .frame(width: metrics.idleWidth, height: rowHeight)
                    .contentShape(Rectangle())
                    .help(usage.kind.rawValue)
                    .onHover { isHovering in
                        onProviderHover(usage.kind, index, isHovering)
                    }
            }
        }
        .padding(.vertical, 12 * metrics.scale)
    }

    private var topControls: some View {
        Image(systemName: isHiddenMode ? "pin.fill" : "arrow.right")
            .font(.system(size: 13 * metrics.scale))
            .foregroundStyle(Color(white: 0.58))
            .accessibilityLabel(isHiddenMode ? "Pin notch" : "Hide notch")
            .help(isHiddenMode ? "Pin notch" : "Hide notch")
            .frame(maxWidth: .infinity)
            .frame(height: metrics.controlsHeight)
    }

    private var bottomControls: some View {
        HStack(spacing: metrics.controlsSpacing) {
            Spacer()
            Image(systemName: "gearshape")
                .font(.system(size: 13 * metrics.scale))
                .foregroundStyle(Color(white: 0.58))
                .help("Settings")
            Spacer()
        }
        .frame(height: metrics.controlsHeight)
    }
}

struct NotchCardContent: View {
    let usage: ProviderUsage
    let metrics: NotchMetrics
    let backgroundOpacity: Double
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            DashboardUsageCard(usage: usage)
                .padding(8 * metrics.scale)
                .frame(width: metrics.cardContentWidth)
                .background {
                    RoundedRectangle(cornerRadius: 14 * metrics.scale, style: .continuous)
                        .fill(.black.opacity(backgroundOpacity))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14 * metrics.scale, style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                }
            SideNotchPointer()
                .fill(.black.opacity(backgroundOpacity))
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
    var onGearTap: ((NSPoint) -> Void)?
    var onEyeTap: (() -> Void)?
    private var lastMouseScreenY: CGFloat?
    private var didDrag = false
    private var didHandleControlTap = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            didDrag = false
            didHandleControlTap = routeControlTap(at: event.locationInWindow)
            lastMouseScreenY = convertPoint(toScreen: event.locationInWindow).y
        case .leftMouseDragged:
            didDrag = true
            if let lastMouseScreenY {
                let currentMouseScreenY = convertPoint(toScreen: event.locationInWindow).y
                onDragMove?(currentMouseScreenY - lastMouseScreenY)
                self.lastMouseScreenY = currentMouseScreenY
            }
            return
        case .leftMouseUp:
            if !didDrag && !didHandleControlTap { _ = routeControlTap(at: event.locationInWindow) }
            didHandleControlTap = false
            lastMouseScreenY = nil
        default:
            break
        }
        super.sendEvent(event)
    }

    // The top and bottom control bands mirror the SwiftUI layout around the provider rail.
    @discardableResult
    private func routeControlTap(at point: NSPoint) -> Bool {
        let topControlsBottom = metrics.controlsBottomSpace
        let topControlsTop = topControlsBottom + metrics.controlsHeight
        let topControlsWindowBottom = metrics.hoverHeight - topControlsTop
        let topControlsWindowTop = metrics.hoverHeight - topControlsBottom
        if point.y >= topControlsWindowBottom && point.y <= topControlsWindowTop {
            onEyeTap?()
            return true
        }

        let bottomControlsTop = metrics.controlsHeight + metrics.controlsGap + metrics.controlsBottomSpace + metrics.compactHeight + metrics.controlsGap
        let bottomControlsWindowBottom = metrics.hoverHeight - bottomControlsTop - metrics.controlsHeight
        let bottomControlsWindowTop = metrics.hoverHeight - bottomControlsTop
        if point.y >= bottomControlsWindowBottom && point.y <= bottomControlsWindowTop {
            onGearTap?(point)
            return true
        }

        return false
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

struct AnimatedPercentageText: View, Animatable {
    var percent: Double
    let scale: CGFloat

    var animatableData: Double {
        get { percent }
        set { percent = newValue }
    }

    var body: some View {
        Text("\(Int(percent.rounded()))%")
            .font(.system(size: 11 * scale, weight: .regular, design: .rounded))
            .foregroundStyle(.white)
    }
}

struct SidebarProviderItem: View {
    let usage: ProviderUsage
    let scale: CGFloat
    let alertSettings: MenuBarAlertSettings
    @State private var displayedPercent = 0.0

    private var percent: Double { usage.primary?.percent ?? 0 }
    private var progressColor: Color {
        if percent >= Double(alertSettings.criticalThreshold) {
            return Color(nsColor: alertSettings.criticalColor)
        }
        if percent >= Double(alertSettings.warningThreshold) {
            return Color(nsColor: alertSettings.warningColor)
        }
        if percent >= Double(alertSettings.cautionThreshold) {
            return Color(nsColor: alertSettings.cautionColor)
        }
        switch usage.kind {
        case .claude: return .orange
        case .codex: return .blue
        case .openCodeGo: return .white
        }
    }

    var body: some View {
        VStack(spacing: 3 * scale) {
            ZStack {
                Circle().stroke(Color(white: 0.18), lineWidth: 5 * scale)
                Circle().trim(from: 0, to: displayedPercent / 100)
                     .stroke(progressColor, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                     .rotationEffect(.degrees(-90))
                ProviderLogo(provider: usage.kind, size: 14 * scale).foregroundStyle(.white)
            }
            .frame(width: 38 * scale, height: 38 * scale)
            AnimatedPercentageText(percent: displayedPercent, scale: scale)
        }
        .contentShape(Rectangle())
        .onAppear { animatePercent(to: percent, delay: 0.15) }
        .onChange(of: percent) { newPercent in animatePercent(to: newPercent) }
    }

    private func animatePercent(to percent: Double, delay: Double = 0) {
        withAnimation(.easeOut(duration: 0.65).delay(delay)) {
            displayedPercent = percent
        }
    }
}

/// The two display modes are mutually exclusive: usage either appears in the
/// floating notch, or as text in the macOS menu bar.
enum DisplayMode: String {
    case sidebar
    case menuBar
}

struct NotchScreen: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

enum NotchBehavior: String, CaseIterable, Identifiable {
    case pinned
    case autoHide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .autoHide: "Auto-hide"
        }
    }
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
        case .iPhone: "Phone"
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
    let notchScreens: [NotchScreen]
    let notchScreenID: UInt32
    let onSelectNotchScreen: (UInt32) -> Void
    let notchBehavior: NotchBehavior
    let onSelectNotchBehavior: (NotchBehavior) -> Void
    let notchSize: NotchSize
    let onSelectNotchSize: (NotchSize) -> Void
    @State private var menuBarAlertColorsEnabled: Bool
    let onChangeMenuBarAlertColors: (Bool) -> Void
    @State private var cautionThreshold: Int
    @State private var warningThreshold: Int
    @State private var criticalThreshold: Int
    @State private var cautionColor: Color
    @State private var warningColor: Color
    @State private var criticalColor: Color
    let onChangeMenuBarAlertSettings: (MenuBarAlertSettings) -> Void
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
        notchScreens: [NotchScreen],
        notchScreenID: UInt32,
        onSelectNotchScreen: @escaping (UInt32) -> Void,
        notchBehavior: NotchBehavior,
        onSelectNotchBehavior: @escaping (NotchBehavior) -> Void,
        notchSize: NotchSize,
        onSelectNotchSize: @escaping (NotchSize) -> Void,
        menuBarAlertColorsEnabled: Bool,
        onChangeMenuBarAlertColors: @escaping (Bool) -> Void,
        menuBarAlertSettings: MenuBarAlertSettings,
        onChangeMenuBarAlertSettings: @escaping (MenuBarAlertSettings) -> Void,
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
        self.notchScreens = notchScreens
        self.notchScreenID = notchScreenID
        self.onSelectNotchScreen = onSelectNotchScreen
        self.notchBehavior = notchBehavior
        self.onSelectNotchBehavior = onSelectNotchBehavior
        self.notchSize = notchSize
        self.onSelectNotchSize = onSelectNotchSize
        _menuBarAlertColorsEnabled = State(initialValue: menuBarAlertColorsEnabled)
        self.onChangeMenuBarAlertColors = onChangeMenuBarAlertColors
        _cautionThreshold = State(initialValue: menuBarAlertSettings.cautionThreshold)
        _warningThreshold = State(initialValue: menuBarAlertSettings.warningThreshold)
        _criticalThreshold = State(initialValue: menuBarAlertSettings.criticalThreshold)
        _cautionColor = State(initialValue: Color(nsColor: menuBarAlertSettings.cautionColor))
        _warningColor = State(initialValue: Color(nsColor: menuBarAlertSettings.warningColor))
        _criticalColor = State(initialValue: Color(nsColor: menuBarAlertSettings.criticalColor))
        self.onChangeMenuBarAlertSettings = onChangeMenuBarAlertSettings
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
        navigationContent
        .frame(minWidth: 680, idealWidth: 720, minHeight: 500, idealHeight: 580)
    }

    private var navigationContent: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Metria")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)

            VStack(alignment: .leading, spacing: 0) {
                Text(selectedSection.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                Divider()
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var detailView: some View {
        switch selectedSection {
        case .general: generalView
        case .providers: providersView
        case .iPhone: phoneView
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
                    Text("Behavior")
                        .font(.headline)
                    Picker("Notch behavior", selection: Binding(get: { notchBehavior }, set: onSelectNotchBehavior)) {
                        ForEach(NotchBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Text("Keep the provider rail visible or collapse it until you hover over the notch.")
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Color usage alerts", isOn: $menuBarAlertColorsEnabled)
                    .onChange(of: menuBarAlertColorsEnabled) { onChangeMenuBarAlertColors($0) }
                menuBarAlertControls
                    .disabled(!menuBarAlertColorsEnabled)
                Text("Choose each alert color and when it starts appearing.")
                    .foregroundStyle(.secondary)
            }

            Section("Monitor") {
                Picker("Monitor", selection: Binding(get: { notchScreenID }, set: onSelectNotchScreen)) {
                    ForEach(notchScreens) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                }
                Text("Choose which monitor displays the notch.")
                    .foregroundStyle(.secondary)
            }

            Section("Notch appearance") {
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
        .padding(12)
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

    private var menuBarAlertControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            alertControl(label: "Caution", color: $cautionColor, threshold: $cautionThreshold, range: 1...(warningThreshold - 1))
            alertControl(label: "Warning", color: $warningColor, threshold: $warningThreshold, range: (cautionThreshold + 1)...(criticalThreshold - 1))
            alertControl(label: "Critical", color: $criticalColor, threshold: $criticalThreshold, range: (warningThreshold + 1)...100)
        }
    }

    private func alertControl(label: String, color: Binding<Color>, threshold: Binding<Int>, range: ClosedRange<Int>) -> some View {
        GridRow {
            Text(label)
            ColorPicker("\(label) color", selection: color)
                .labelsHidden()
                .onChange(of: color.wrappedValue) { _ in saveMenuBarAlertSettings() }
            Stepper("\(threshold.wrappedValue)%", value: threshold, in: range)
                .onChange(of: threshold.wrappedValue) { _ in saveMenuBarAlertSettings() }
                .frame(width: 92)
        }
    }

    private func saveMenuBarAlertSettings() {
        onChangeMenuBarAlertSettings(.init(
            cautionThreshold: cautionThreshold,
            warningThreshold: warningThreshold,
            criticalThreshold: criticalThreshold,
            cautionColor: NSColor(cautionColor),
            warningColor: NSColor(warningColor),
            criticalColor: NSColor(criticalColor)
        ))
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
        .padding(12)
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

    private var phoneView: some View {
        Form {
            Section("Pair your phone") {
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

            Text("Scan the QR code with your phone's camera, or open the PWA and enter the phrase. The local address must be reachable from your phone.")
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
            Text("Any phone using the current QR code or phrase will stop receiving updates.")
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

    private var menuBarAlertColorsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "menuBarAlertColorsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarAlertColorsEnabled") }
    }

    private var menuBarAlertSettings: MenuBarAlertSettings {
        .init(
            cautionThreshold: UserDefaults.standard.object(forKey: "menuBarCautionThreshold") as? Int ?? MenuBarAlertSettings.default.cautionThreshold,
            warningThreshold: UserDefaults.standard.object(forKey: "menuBarWarningThreshold") as? Int ?? MenuBarAlertSettings.default.warningThreshold,
            criticalThreshold: UserDefaults.standard.object(forKey: "menuBarCriticalThreshold") as? Int ?? MenuBarAlertSettings.default.criticalThreshold,
            cautionColor: menuBarAlertColor(forKey: "menuBarCautionColor", fallback: MenuBarAlertSettings.default.cautionColor),
            warningColor: menuBarAlertColor(forKey: "menuBarWarningColor", fallback: MenuBarAlertSettings.default.warningColor),
            criticalColor: menuBarAlertColor(forKey: "menuBarCriticalColor", fallback: MenuBarAlertSettings.default.criticalColor)
        )
    }

    private func setMenuBarAlertColorsEnabled(_ enabled: Bool) {
        menuBarAlertColorsEnabled = enabled
        updateStatusItem(store.providers)
    }

    private func setMenuBarAlertSettings(_ settings: MenuBarAlertSettings) {
        UserDefaults.standard.set(settings.cautionThreshold, forKey: "menuBarCautionThreshold")
        UserDefaults.standard.set(settings.warningThreshold, forKey: "menuBarWarningThreshold")
        UserDefaults.standard.set(settings.criticalThreshold, forKey: "menuBarCriticalThreshold")
        saveMenuBarAlertColor(settings.cautionColor, forKey: "menuBarCautionColor")
        saveMenuBarAlertColor(settings.warningColor, forKey: "menuBarWarningColor")
        saveMenuBarAlertColor(settings.criticalColor, forKey: "menuBarCriticalColor")
        updateStatusItem(store.providers)
        sidebarWindows.forEach { $0.contentView = makeHostingView() }
    }

    private func menuBarAlertColor(forKey key: String, fallback: NSColor) -> NSColor {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)) ?? fallback
    }

    private func saveMenuBarAlertColor(_ color: NSColor, forKey key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func menuBarAlertColor(for percent: Double) -> NSColor? {
        guard menuBarAlertColorsEnabled else { return nil }
        let settings = menuBarAlertSettings
        if percent >= Double(settings.criticalThreshold) { return settings.criticalColor }
        if percent >= Double(settings.warningThreshold) { return settings.warningColor }
        if percent >= Double(settings.cautionThreshold) { return settings.cautionColor }
        return nil
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
            var percentageAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            if let color = menuBarAlertColor(for: percent) {
                percentageAttributes[.foregroundColor] = color
            }
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
        statusItem.menu = buildAppMenu()
    }

    private func buildAppMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open dashboard", action: #selector(togglePopover), keyEquivalent: "")
        menu.addItem(withTitle: displayMode == .menuBar ? "Notch mode" : "Menu mode", action: displayMode == .menuBar ? #selector(switchToSidebar) : #selector(switchToMenuBar), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        if updater.isConfigured {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        if updater.isConfigured {
            menu.items.first { $0.action == #selector(AppUpdater.checkForUpdates(_:)) }?.target = updater
        }
        return menu
    }

    private func showNotchMenu(at windowPoint: NSPoint) {
        let panel = sidebarWindows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? sidebarWindow
        guard let panel, let contentView = panel.contentView else { return }
        let screenPoint = panel.convertPoint(toScreen: windowPoint)
        let anchor = contentView.convert(screenPoint, from: nil)
        buildAppMenu().popUp(positioning: nil, at: anchor, in: contentView)
    }

    private func configurePopover() { popover = NSPopover(); popover.behavior = .transient; popover.contentSize = NSSize(width: 440, height: 700); popover.contentViewController = NSHostingController(rootView: PopoverContent(store: store)) }

    private var notchGeometry = NotchGeometry.current()
    private let notchMode = NotchMode()
    private var notchMetrics: NotchMetrics { NotchMetrics(size: notchMode.size) }
    private var notchExpansion: CGFloat { notchMetrics.controlsHeight + notchMetrics.controlsGap + notchMetrics.controlsBottomSpace }
    private var notchScreens: [NotchScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return NotchScreen(id: id.uint32Value, name: screen.localizedName)
        }
    }
    private var selectedNotchScreen: NSScreen? {
        let selectedID = UserDefaults.standard.object(forKey: "notchScreenID") as? NSNumber
        return NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return id.uint32Value == selectedID?.uint32Value
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
    private var selectedNotchScreenID: UInt32 {
        guard let screen = selectedNotchScreen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 0 }
        return id.uint32Value
    }
    private var sidebarWindows: [NSPanel] = []
    private var cardWindow: NSPanel?
    private var activeCardProvider: ProviderKind?
    private var activeCardIndex = 0
    private var activeCardScreen: NSScreen?
    private var hoveredProvider: ProviderKind?
    private var isRailHovered = false
    private var isCardHovered = false
    private var pendingCardDismiss: DispatchWorkItem?

    private func configureSidebar() {
        let screen = selectedNotchScreen ?? NSScreen.main ?? NSScreen.screens.first
        sidebarWindows = screen.map { [makeSidebarWindow(for: $0)] } ?? []
        sidebarWindow = sidebarWindows.first
        notchGeometry = NotchGeometry.current(for: screen)

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func makeSidebarWindow(for screen: NSScreen) -> NSPanel {
        let geometry = NotchGeometry.current(for: screen)
        let frame = geometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchYOffset + notchExpansion)
        let panel = DraggableNotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.metrics = notchMetrics
        panel.onDragMove = { [weak self] deltaY in self?.moveNotch(by: deltaY) }
        panel.onGearTap = { [weak self] _ in self?.openSettings() }
        panel.onEyeTap = { [weak self] in
            guard let self else { return }
            self.setHiddenNotch(!self.notchMode.isHiddenMode)
        }
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.contentView = makeHostingView()
        panel.setFrame(frame, display: true)
        return panel
    }

    private func moveNotchToSelectedScreen() {
        guard displayMode == .sidebar, let sidebarWindow, let screen = selectedNotchScreen else { return }
        let geometry = NotchGeometry.current(for: screen)
        let defaultFrame = geometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchExpansion)
        var frame = geometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchYOffset + notchExpansion)
        frame.origin.y = min(max(frame.origin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
        guard !frame.equalTo(sidebarWindow.frame) else {
            notchGeometry = geometry
            return
        }
        sidebarWindow.setFrame(frame, display: true)
        notchGeometry = geometry
        notchYOffset = frame.origin.y - defaultFrame.origin.y
    }

    // Building a fresh hosting view resets the SwiftUI hover state so that, on hiding,
    // the rail truly collapses to the slim bar instead of staying expanded under the cursor.
    private func makeHostingView() -> NotchHostingView {
        let content = NotchContent(
            store: store,
            mode: notchMode,
            backgroundOpacity: sidebarOpacity,
            menuBarAlertSettings: menuBarAlertSettings,
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
        moveNotchToSelectedScreen()
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
        let screen = sidebarWindow.screen ?? NSScreen.screens.first { $0.frame.intersects(sidebarWindow.frame) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? sidebarWindow.frame
        var frame = sidebarWindow.frame
        frame.origin.y = min(max(frame.origin.y + deltaY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        sidebarWindow.setFrameOrigin(frame.origin)

        notchGeometry = NotchGeometry.current(for: screen)
        let defaultFrame = notchGeometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchExpansion)
        notchYOffset = frame.origin.y - defaultFrame.origin.y
        if activeCardProvider != nil { positionCard(index: activeCardIndex) }
    }

    private func setRailHovered(_ isHovered: Bool) {
        guard isRailHovered != isHovered else { return }
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
        hoveredProvider = nil
        activeCardProvider = nil
        cardWindow?.orderOut(nil)
        if isHidden {
            isRailHovered = false
            // Fresh view resets the SwiftUI hover state so the rail collapses at once.
            for window in sidebarWindows {
                window.contentView = makeHostingView()
            }
        }
    }

    private func setNotchSize(_ size: NotchSize) {
        guard notchMode.size != size else { return }
        notchMode.size = size
        UserDefaults.standard.set(size.rawValue, forKey: "notchSize")
        for window in sidebarWindows {
            (window as? DraggableNotchPanel)?.metrics = notchMetrics
            if let hostingView = window.contentView as? NotchHostingView {
                hostingView.metrics = notchMetrics
                hostingView.needsLayout = true
            }
            let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) }
            let geometry = NotchGeometry.current(for: screen)
            window.setFrame(geometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchYOffset + notchExpansion), display: true)
        }
        if let activeCardProvider {
            showCard(for: activeCardProvider, index: activeCardIndex)
        }
    }

    private func setNotchScreen(_ id: UInt32) {
        UserDefaults.standard.set(Int(id), forKey: "notchScreenID")
        moveNotchToSelectedScreen()
        if activeCardProvider != nil { positionCard(index: activeCardIndex) }
    }

    private var notchBehavior: NotchBehavior {
        notchMode.isHiddenMode ? .autoHide : .pinned
    }

    private func setNotchBehavior(_ behavior: NotchBehavior) {
        setHiddenNotch(behavior == .autoHide)
    }

    private func setProviderHovered(_ provider: ProviderKind, index: Int, isHovered: Bool) {
        if isHovered {
            hoveredProvider = provider
            isRailHovered = true
            pendingCardDismiss?.cancel()
            showCard(for: provider, index: index)
        } else if hoveredProvider == provider {
            hoveredProvider = nil
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
        DispatchQueue.main.async(execute: workItem)
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
        activeCardScreen = selectedNotchScreen
        notchGeometry = NotchGeometry.current(for: activeCardScreen)
        let cardContent = NotchCardContent(usage: usage, metrics: notchMetrics, backgroundOpacity: sidebarOpacity) { [weak self] isHovered in
            self?.setCardHovered(isHovered)
        }
        cardWindow?.contentViewController = NSHostingController(rootView: cardContent)
        cardWindow?.layoutIfNeeded()
        let cardHeight = max(cardWindow?.contentViewController?.view.fittingSize.height ?? 0, 1)
        positionCard(index: index, height: cardHeight)
        cardWindow?.alphaValue = 1
        cardWindow?.orderFrontRegardless()
    }

    private func positionCard(index: Int, height: CGFloat? = nil) {
        guard let cardWindow else { return }
        let cardHeight = height ?? max(cardWindow.contentViewController?.view.fittingSize.height ?? 0, 1)
        let railFrame = notchGeometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.compactHeight, verticalOffset: notchYOffset)
        let providerCenterY = railFrame.maxY - 12 * notchMetrics.scale - notchMetrics.providerItemHeight / 2
            - CGFloat(index) * (notchMetrics.providerItemHeight + notchMetrics.providerSpacing)
        let visibleFrame = activeCardScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? railFrame
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
        sidebarWindows.forEach { window in
            window.alphaValue = 1
            window.contentView = makeHostingView()
        }
        if let activeCardProvider {
            showCard(for: activeCardProvider, index: activeCardIndex)
        }
    }

    // The two modes are mutually exclusive: only one is visible at a time.
    private var displayMode: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .sidebar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "displayMode") }
    }

    private func applyDisplayMode() {
        statusItem.menu = buildAppMenu()
        switch displayMode {
        case .sidebar:
            animateSidebarIn()
            statusItem.isVisible = false
        case .menuBar:
            sidebarWindows.forEach { $0.orderOut(nil) }
            cardWindow?.orderOut(nil)
            statusItem.isVisible = true
        }
    }

    private func animateSidebarIn() {
        guard !sidebarWindows.isEmpty else { return }
        let screen = selectedNotchScreen
        notchGeometry = NotchGeometry.current(for: screen)
        isRailHovered = false
        isCardHovered = false
        activeCardProvider = nil
        cardWindow?.orderOut(nil)
        sidebarWindows.forEach { window in
            let geometry = NotchGeometry.current(for: screen)
            let frame = geometry.frame(width: notchMetrics.idleWidth, height: notchMetrics.hoverHeight, verticalOffset: notchYOffset + notchExpansion)
            window.setFrame(frame, display: true)
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
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
              notchScreens: notchScreens,
              notchScreenID: selectedNotchScreenID,
              onSelectNotchScreen: { [weak self] id in self?.setNotchScreen(id) },
              notchBehavior: notchBehavior,
              onSelectNotchBehavior: { [weak self] behavior in self?.setNotchBehavior(behavior) },
              notchSize: notchMode.size,
             onSelectNotchSize: { [weak self] size in self?.setNotchSize(size) },
             menuBarAlertColorsEnabled: menuBarAlertColorsEnabled,
             onChangeMenuBarAlertColors: { [weak self] enabled in self?.setMenuBarAlertColorsEnabled(enabled) },
             menuBarAlertSettings: menuBarAlertSettings,
             onChangeMenuBarAlertSettings: { [weak self] settings in self?.setMenuBarAlertSettings(settings) },
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
