import BackgroundTasks
import SwiftUI
import WidgetKit
import MetriaMobileKit

@main
struct MetriaMobileApp: App {
    @StateObject private var model = PairingViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: PairingViewModel

    var body: some View {
        if model.configuration != nil {
            DashboardView()
        } else {
            PairingView()
        }
    }
}
