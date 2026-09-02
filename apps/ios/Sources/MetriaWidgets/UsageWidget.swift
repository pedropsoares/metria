import SwiftUI
import WidgetKit
import MetriaCore
import MetriaMobileKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let isPaired: Bool
    let cached: CachedSnapshot?
    let selection: ProviderSelection
    let nextReloadDate: Date

    var displayedProvider: UsageSnapshot.Provider? {
        guard let providers = cached?.snapshot.providers, !providers.isEmpty else { return nil }
        guard let kind = selection.providerKind else {
            return providers.max { $0.percent < $1.percent }
        }
        return providers.first { $0.name == kind.rawValue } ?? providers.max { $0.percent < $1.percent }
    }

    var age: TimeInterval {
        guard let cached else { return .infinity }
        return Date().timeIntervalSince(cached.fetchedAt)
    }

    var isStale: Bool { age > 20 * 60 }
}

struct UsageProvider: AppIntentTimelineProvider {
    typealias Entry = UsageEntry
    typealias Intent = SelectProviderIntent

    func placeholder(in context: Context) -> UsageEntry {
        sampleEntry
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> UsageEntry {
        context.isPreview ? sampleEntry : currentEntry(configuration: configuration)
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<UsageEntry> {
        guard let pairing = PairingStore.load() else {
            return Timeline(entries: [UsageEntry(date: Date(), isPaired: false, cached: nil, selection: configuration.provider, nextReloadDate: Date())], policy: .never)
        }
        await SnapshotFetcher().fetchAndCache(configuration: pairing)
        let nextReloadDate = Date().addingTimeInterval(15 * 60)
        let entry = UsageEntry(date: Date(), isPaired: true, cached: SharedSnapshotCache.load(), selection: configuration.provider, nextReloadDate: nextReloadDate)
        return Timeline(entries: [entry], policy: .after(nextReloadDate))
    }

    private func currentEntry(configuration: SelectProviderIntent) -> UsageEntry {
        UsageEntry(
            date: Date(),
            isPaired: PairingStore.load() != nil,
            cached: SharedSnapshotCache.load(),
            selection: configuration.provider,
            nextReloadDate: Date().addingTimeInterval(15 * 60)
        )
    }

    private var sampleEntry: UsageEntry {
        let snapshot = UsageSnapshot(updatedAt: Date(), providers: [.init(name: "Claude", percent: 42, resetDate: Date().addingTimeInterval(86_400 * 3))])
        return UsageEntry(date: Date(), isPaired: true, cached: CachedSnapshot(snapshot: snapshot, fetchedAt: Date(), transport: .local), selection: .highest, nextReloadDate: Date().addingTimeInterval(900))
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: UsageEntry

    private var isAccessory: Bool {
        family == .accessoryCircular || family == .accessoryRectangular || family == .accessoryInline
    }

    /// Read straight from the App Group the app writes to: the extension has no settings
    /// screen of its own, and a timeline reload is what brings a change over.
    private var spendDisplay: SpendDisplay { MetriaAppGroup.spendDisplay }

    var body: some View {
        Group {
            if !entry.isPaired {
                unpairedView
            } else if let provider = entry.displayedProvider, !entry.isStale {
                pairedView(provider: provider)
            } else {
                offlineView
            }
        }
        .containerBackground(isAccessory ? AnyShapeStyle(.clear) : AnyShapeStyle(.fill.tertiary), for: .widget)
    }

    // MARK: - Freshness

    /// When the reading was taken, as a clock time. The Home Screen is glanced at beside
    /// the system clock, so a timestamp answers "how current is this?" at once, where a
    /// running counter only asks the reader to do the subtraction.
    private var lastUpdatedText: some View {
        Label {
            Text(entry.cached?.snapshot.updatedAt ?? entry.date, style: .time)
                .lineLimit(1)
        } icon: {
            Image(systemName: "clock")
        }
        .font(.caption2)
        .labelStyle(.titleAndIcon)
    }

    /// The Lock Screen shows the wait instead: the clock is already right above the
    /// widget, so what it cannot tell you is when the next reading lands.
    private var countdownLabel: some View {
        Label {
            countdownText
        } icon: {
            Image(systemName: "clock")
        }
        .labelStyle(.titleAndIcon)
    }

    /// Clamped because a late reload puts `nextReloadDate` in the past, and an inverted
    /// range traps at runtime — the very case this countdown exists to reveal. It
    /// re-renders on its own, without spending a timeline reload.
    private var countdownText: some View {
        let now = Date()
        let end = max(entry.nextReloadDate, now.addingTimeInterval(1))
        return (Text("next ") + Text(timerInterval: now...end, countsDown: true))
            .font(.caption2)
            .lineLimit(1)
    }

    private func percentText(_ provider: UsageSnapshot.Provider, size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        let parts = provider.spendParts(spendDisplay)
        // Money is a longer string than "52%", so it renders a size down and scales.
        return Text(parts.showsPercent ? "\(Int(provider.percent.rounded()))%" : parts.spend ?? "")
            .font(.system(size: parts.showsPercent ? size : size * 0.7, weight: weight))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(isAccessory ? AnyShapeStyle(.primary) : AnyShapeStyle(UsagePresentation.color(for: provider.percent)))
    }

    /// The money half when the percentage already has the magnitude slot to itself.
    @ViewBuilder
    private func spendCaption(_ provider: UsageSnapshot.Provider) -> some View {
        let parts = provider.spendParts(spendDisplay)
        if parts.showsPercent, let spend = parts.spend {
            Text(spend)
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
        }
    }

    private func logo(for provider: UsageSnapshot.Provider, size: CGFloat) -> some View {
        UsagePresentation.logo(for: provider.name, size: size)
    }

    // MARK: - States

    private var unpairedView: some View {
        VStack(spacing: 6) {
            Image(systemName: "qrcode.viewfinder").font(isAccessory ? .body : .title2)
            Text(isAccessory ? "Open Metria to pair" : "Open Metria to scan the QR code on your Mac")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(isAccessory ? 2 : 3)
        }
    }

    private var offlineView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isAccessory {
                Image(systemName: "wifi.slash").font(.caption)
            }
            Text(OfflineCopy.line(for: entry.age))
                .font(isAccessory ? .caption2 : .footnote)
                .lineLimit(isAccessory ? 2 : 3)
                .minimumScaleFactor(0.85)
            if entry.cached != nil {
                lastUpdatedText.foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pairedView(provider: UsageSnapshot.Provider) -> some View {
        switch family {
        case .accessoryCircular:
            circularView(provider: provider)
        case .accessoryRectangular:
            rectangularView(provider: provider)
        case .accessoryInline:
            Text("\(provider.name) \(Int(provider.percent.rounded()))%")
        case .systemMedium:
            mediumView
        default:
            smallView(provider: provider)
        }
    }

    // MARK: - Lock Screen

    private func circularView(provider: UsageSnapshot.Provider) -> some View {
        Gauge(value: min(max(provider.percent, 0), 100), in: 0...100) {
            Text(provider.name.prefix(2).uppercased())
        } currentValueLabel: {
            Text("\(Int(provider.percent.rounded()))")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .background { AccessoryWidgetBackground() }
    }

    /// Three tight lines: identity, magnitude, freshness. The gauge carries the urgency
    /// because the Lock Screen renders everything monochrome — color says nothing here.
    private func rectangularView(provider: UsageSnapshot.Provider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.name)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                Spacer(minLength: 4)
                percentText(provider, size: 16, weight: .bold)
            }
            Gauge(value: min(max(provider.percent, 0), 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .frame(height: 6)
            countdownLabel
        }
    }

    // MARK: - Home Screen

    private func smallView(provider: UsageSnapshot.Provider) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                logo(for: provider, size: 22)
                Text(provider.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                refreshButton
            }
            Spacer(minLength: 8)
            percentText(provider, size: 40, weight: .semibold)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            usageBar(provider)
                .padding(.top, 8)
            spendCaption(provider)
                .padding(.top, 4)
            if let resetDate = provider.resetDate {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            Spacer(minLength: 6)
            lastUpdatedText.foregroundStyle(.secondary)
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Metria").font(.caption.weight(.bold))
                Spacer(minLength: 0)
                refreshButton
            }
            VStack(spacing: 0) {
                ForEach((entry.cached?.snapshot.providers ?? []).prefix(4), id: \.name) { provider in
                    providerRow(provider)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                lastUpdatedText
                Spacer(minLength: 4)
                countdownText
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Identity on the left (logo, name, reset), magnitude on the right, and a
    /// bar between them. Rows expand so two providers still fill a medium widget.
    private func providerRow(_ provider: UsageSnapshot.Provider) -> some View {
        HStack(spacing: 10) {
            logo(for: provider, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let resetDate = provider.resetDate {
                    Text("Resets \(resetDate, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 64, alignment: .leading)
            usageBar(provider)
            VStack(alignment: .trailing, spacing: 0) {
                percentText(provider, size: 15, weight: .semibold)
                spendCaption(provider)
            }
            .frame(width: provider.spendParts(spendDisplay).spend == nil ? 42 : 92, alignment: .trailing)
        }
    }

    private func usageBar(_ provider: UsageSnapshot.Provider) -> some View {
        let fraction = min(max(provider.percent, 0), 100) / 100
        return Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 10)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(UsagePresentation.color(for: provider.percent))
                        .frame(width: geo.size.width * fraction)
                }
            }
    }

    private var refreshButton: some View {
        Button(intent: RefreshUsageIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct UsageWidget: Widget {
    let kind = "com.metria.ios.usage"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectProviderIntent.self, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Metria Usage")
        .description("Shows your AI provider usage from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#if DEBUG
private func previewEntry(percent: Double, ageMinutes: Double, isPaired: Bool = true) -> UsageEntry {
    let updatedAt = Date().addingTimeInterval(-ageMinutes * 60)
    let snapshot = UsageSnapshot(updatedAt: updatedAt, providers: [
        .init(name: "Claude", percent: percent, resetDate: Date().addingTimeInterval(86_400 * 3)),
        .init(name: "Codex", percent: 64, resetDate: nil),
        .init(name: "Cursor", percent: 12, resetDate: nil)
    ])
    return UsageEntry(
        date: Date(),
        isPaired: isPaired,
        cached: isPaired ? CachedSnapshot(snapshot: snapshot, fetchedAt: updatedAt, transport: .local) : nil,
        selection: .highest,
        nextReloadDate: Date().addingTimeInterval(15 * 60)
    )
}

#Preview("Small", as: .systemSmall) {
    UsageWidget()
} timeline: {
    previewEntry(percent: 42, ageMinutes: 3)
    previewEntry(percent: 91, ageMinutes: 3)
}

#Preview("Medium", as: .systemMedium) {
    UsageWidget()
} timeline: {
    previewEntry(percent: 42, ageMinutes: 3)
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    UsageWidget()
} timeline: {
    previewEntry(percent: 42, ageMinutes: 3)
}

#Preview("Offline", as: .systemSmall) {
    UsageWidget()
} timeline: {
    previewEntry(percent: 42, ageMinutes: 180)
}

#Preview("Not paired", as: .systemSmall) {
    UsageWidget()
} timeline: {
    previewEntry(percent: 0, ageMinutes: 0, isPaired: false)
}
#endif
