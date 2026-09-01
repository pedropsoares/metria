import SwiftUI
import MetriaCore
import MetriaMobileKit

struct DashboardView: View {
    @EnvironmentObject private var model: PairingViewModel
    @State private var isSettingsShown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ConnectionChip(cached: model.cached)
                    if let providers = model.cached?.snapshot.providers, !providers.isEmpty {
                        ForEach(providers, id: \.name) { provider in
                            ProviderCard(provider: provider)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(16)
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Metria")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSettingsShown = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $isSettingsShown) { SettingsView() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No providers available yet").font(.headline)
            Text("Pull to refresh once your Mac has published a reading.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }
}

private struct ConnectionChip: View {
    let cached: CachedSnapshot?

    private var isStale: Bool {
        guard let cached else { return true }
        return Date().timeIntervalSince(cached.fetchedAt) > 20 * 60
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption.bold())
            Spacer()
            if let cached {
                Text(cached.snapshot.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var color: Color {
        guard let cached else { return .gray }
        if isStale { return .red }
        return cached.transport == .local ? .green : .orange
    }

    private var label: String {
        guard let cached else { return "Not paired" }
        if isStale { return "Offline" }
        return cached.transport == .local ? "Local" : "Relay"
    }
}

private struct ProviderCard: View {
    let provider: UsageSnapshot.Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let name = UsagePresentation.logoAssetName(for: provider.name),
                   let logo = UsagePresentation.image(named: name) {
                    logo.resizable().scaledToFit().frame(width: 24, height: 24)
                }
                Text(provider.name).font(.headline)
                Spacer()
                Text("\(Int(provider.percent.rounded()))%")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(UsagePresentation.color(for: provider.percent))
            }
            ProgressView(value: min(max(provider.percent, 0), 100), total: 100)
                .tint(UsagePresentation.color(for: provider.percent))
            if let resetDate = provider.resetDate {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

#if DEBUG
#Preview("Paired") {
    DashboardView().environmentObject(PairingViewModel.preview())
}

#Preview("Empty") {
    DashboardView().environmentObject(PairingViewModel())
}
#endif
