import AppKit
import Combine
import CoreImage
import CryptoKit
import Foundation
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
    /// Change this if you deploy your own fork of MetriaPWA elsewhere.
    static let pwaBaseURL = "https://metria-pwa.vercel.app"

    @Published private(set) var words: [String] = []
    @Published private(set) var qrImage: NSImage?
    private var secret: Data = Data()

    init() {
        secret = PairingKeychain.loadOrGenerate()
        words = PairingSecret.words(from: secret)
    }

    func regenerate() {
        secret = PairingKeychain.regenerate()
        words = PairingSecret.words(from: secret)
    }

    func pairingLink(server: String) -> String {
        let encodedServer = server.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? server
        return "\(Self.pwaBaseURL)/#s=\(secret.base64URLEncodedString)&server=\(encodedServer)"
    }

    func refreshQRCode(server: String) {
        qrImage = Self.renderQRCode(for: pairingLink(server: server))
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

private final class NtfyPublisher {
    private let defaults = UserDefaults.standard
    private var lastPayload: Data?

    func publish(_ providers: [ProviderUsage]) {
        guard let server = URL(string: defaults.string(forKey: "ntfyServer") ?? "https://ntfy.sh"),
              server.scheme == "https", server.host != nil,
              let secret = PairingKeychain.load() else { return }

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

        let topic = PairingSecret.topic(from: secret)
        let key = PairingSecret.encryptionKey(from: secret)
        guard let sealed = try? AES.GCM.seal(payload, using: key), let combined = sealed.combined else { return }
        lastPayload = payload

        var request = URLRequest(url: server.appendingPathComponent(topic))
        request.httpMethod = "POST"
        request.httpBody = combined.base64EncodedData()
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
                    ForEach(store.providers) { DashboardUsageCard(usage: $0) }
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
            .filter { store.enabledProviderKinds.contains($0) && store.isProviderAvailable($0) }
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
    @ObservedObject var pairing: PairingManager
    let displayMode: DisplayMode
    let onSelectDisplayMode: (DisplayMode) -> Void
    @State private var sidebarOpacity: Double
    let onChangeSidebarOpacity: (Double) -> Void
    let onQuit: () -> Void
    @State private var ntfyServer: String
    let onChangeServer: (String) -> Void
    @State private var isPhraseRevealed = false
    @State private var isRegenerateConfirmationShown = false

    init(
        store: UsageStore,
        pairing: PairingManager,
        displayMode: DisplayMode,
        onSelectDisplayMode: @escaping (DisplayMode) -> Void,
        sidebarOpacity: Double,
        onChangeSidebarOpacity: @escaping (Double) -> Void,
        onQuit: @escaping () -> Void,
        ntfyServer: String,
        onChangeServer: @escaping (String) -> Void
    ) {
        self.store = store
        self.pairing = pairing
        self.displayMode = displayMode
        self.onSelectDisplayMode = onSelectDisplayMode
        _sidebarOpacity = State(initialValue: sidebarOpacity)
        self.onChangeSidebarOpacity = onChangeSidebarOpacity
        self.onQuit = onQuit
        _ntfyServer = State(initialValue: ntfyServer)
        self.onChangeServer = onChangeServer
    }

    var body: some View {
        TabView {
            Form {
                Section("Display") {
                    Picker("Show usage in", selection: Binding(get: { displayMode }, set: onSelectDisplayMode)) {
                        Text("Floating sidebar").tag(DisplayMode.sidebar)
                        Text("Menu bar").tag(DisplayMode.menuBar)
                    }
                    .pickerStyle(.segmented)

                    Text("Only one option is visible at a time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sidebar") {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text("\(Int(sidebarOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $sidebarOpacity, in: 0.35...1)
                        .onChange(of: sidebarOpacity) { onChangeSidebarOpacity($0) }
                }

                Section("Updates") {
                    Stepper(value: $store.refreshInterval, in: 60...1800, step: 60) {
                        Text("Refresh every \(Int(store.refreshInterval / 60)) min")
                    }
                }

                Section {
                    Button("Exit", role: .destructive, action: onQuit)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Enabled providers") {
                    ForEach(ProviderKind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { store.enabledProviderKinds.contains(kind) },
                            set: { store.setProviderEnabled(kind, isEnabled: $0) }
                        )) {
                            HStack(spacing: 8) {
                                ProviderLogo(provider: kind, size: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.rawValue)
                                    if !store.isProviderAvailable(kind), let hint = store.setupHint(for: kind) {
                                        Text(hint)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(!store.isProviderAvailable(kind))
                    }
                }

                Text("At least one provider must remain enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }

            Form {
                Section("Pair your iPhone") {
                    if let qrImage = pairing.qrImage {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                            .frame(maxWidth: .infinity)
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
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pairing.pairingLink(server: ntfyServer), forType: .string)
                        }
                        Spacer()
                        Button("Regenerate", role: .destructive) { isRegenerateConfirmationShown = true }
                    }
                    .controlSize(.small)
                }

                Section("Connection") {
                    TextField("ntfy server", text: $ntfyServer)
                        .onSubmit { onChangeServer(ntfyServer) }
                }

                Text("Scan the QR code with your iPhone camera, or open the PWA and enter the phrase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .alert("Regenerate pairing?", isPresented: $isRegenerateConfirmationShown) {
                Button("Cancel", role: .cancel) {}
                Button("Regenerate", role: .destructive) {
                    pairing.regenerate()
                    pairing.refreshQRCode(server: ntfyServer)
                }
            } message: {
                Text("Any iPhone using the current QR code or phrase will stop receiving updates.")
            }
            .tabItem { Label("iPhone", systemImage: "iphone") }
        }
        .frame(width: 420, height: 440)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore(providers: ProviderRegistry.makeProviders()); var statusItem: NSStatusItem!; var popover: NSPopover!; var sidebarWindow: NSPanel!; var settingsWindow: NSWindow?; var observation: AnyCancellable?; private let ntfyPublisher = NtfyPublisher(); let pairing = PairingManager(); private let updater = AppUpdater()
    private var isSidebarHovered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
        configureStatusItem()
        configurePopover()
        configureSidebar()
        pairing.refreshQRCode(server: ntfyServer)
        observation = store.$providers.sink { [weak self] providers in
            self?.updateStatusItem(providers)
            self?.ntfyPublisher.publish(providers)
        }
        applyDisplayMode()
    }

    private var ntfyServer: String {
        get { UserDefaults.standard.string(forKey: "ntfyServer") ?? "https://ntfy.sh" }
        set { UserDefaults.standard.set(newValue, forKey: "ntfyServer") }
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
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
            sidebarOpacity: sidebarOpacity,
            onChangeSidebarOpacity: { [weak self] opacity in self?.setSidebarOpacity(opacity) },
            onQuit: { [weak self] in self?.quit() },
            ntfyServer: ntfyServer,
            onChangeServer: { [weak self] server in
                guard let self else { return }
                self.ntfyServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
                self.pairing.refreshQRCode(server: self.ntfyServer)
                self.store.refresh()
            }
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
