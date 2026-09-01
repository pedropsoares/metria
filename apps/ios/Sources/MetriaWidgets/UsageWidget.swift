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

    /// The Lock Screen has room for roughly three short lines, so elapsed time is shown
    /// as a compact stopwatch there and spelled out only where there is width for it.
    /// Both styles re-render on their own, without spending a timeline reload.
    private var elapsedText: some View {
        Label {
            Text(entry.cached?.snapshot.updatedAt ?? entry.date, style: isAccessory ? .timer : .relative)
                .lineLimit(1)
        } icon: {
            Image(systemName: "clock")
        }
        .font(.caption2)
        .labelStyle(.titleAndIcon)
    }

    /// Clamped because a late reload puts `nextReloadDate` in the past, and an inverted
    /// range traps at runtime — the very case this countdown exists to reveal.
    private var countdownText: some View {
        let now = Date()
        let end = max(entry.nextReloadDate, now.addingTimeInterval(1))
        return (Text("next ") + Text(timerInterval: now...end, countsDown: true))
            .font(.caption2)
            .lineLimit(1)
    }

    private func percentText(_ provider: UsageSnapshot.Provider, size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        Text("\(Int(provider.percent.rounded()))%")
            .font(.system(size: size, weight: weight))
            .monospacedDigit()
            .foregroundStyle(isAccessory ? AnyShapeStyle(.primary) : AnyShapeStyle(UsagePresentation.color(for: provider.percent)))
    }

    private func logo(for provider: UsageSnapshot.Provider, size: CGFloat) -> some View {
        Group {
            if let name = UsagePresentation.logoAssetName(for: provider.name),
               let image = UsagePresentation.image(named: name) {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "chart.bar.fill").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
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
                elapsedText.foregroundStyle(.secondary)
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
            elapsedText
        }
    }

    // MARK: - Home Screen

    private func smallView(provider: UsageSnapshot.Provider) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                logo(for: provider, size: 16)
                Text(provider.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                refreshButton
            }
            Spacer(minLength: 8)
            percentText(provider, size: 40, weight: .semibold)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            ProgressView(value: min(max(provider.percent, 0), 100), total: 100)
                .tint(UsagePresentation.color(for: provider.percent))
                .padding(.top, 6)
            if let resetDate = provider.resetDate {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            Spacer(minLength: 6)
            elapsedText.foregroundStyle(.secondary)
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Metria").font(.caption.weight(.bold))
                Spacer(minLength: 0)
                refreshButton
            }
            Spacer(minLength: 8)
            VStack(spacing: 7) {
                ForEach((entry.cached?.snapshot.providers ?? []).prefix(4), id: \.name) { provider in
                    providerRow(provider)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                elapsedText
                Spacer(minLength: 4)
                countdownText
            }
            .foregroundStyle(.secondary)
        }
    }

    /// One dense, scannable line per provider: identity on the left, magnitude on the
    /// right, and the bar between them carrying the comparison at a glance.
    private func providerRow(_ provider: UsageSnapshot.Provider) -> some View {
        HStack(spacing: 8) {
            logo(for: provider, size: 16)
            Text(provider.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            ProgressView(value: min(max(provider.percent, 0), 100), total: 100)
                .tint(UsagePresentation.color(for: provider.percent))
            percentText(provider, size: 13, weight: .semibold)
                .frame(width: 40, alignment: .trailing)
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
