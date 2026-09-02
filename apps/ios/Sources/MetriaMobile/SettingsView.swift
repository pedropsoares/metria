import SwiftUI
import WidgetKit
import MetriaCore
import MetriaMobileKit

struct SettingsView: View {
    @EnvironmentObject private var model: PairingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @AppStorage(SpendFormat.defaultsKey, store: MetriaAppGroup.defaults) private var spendDisplay = SpendDisplay.both
    @State private var isForgetConfirmationShown = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Show usage as", selection: $spendDisplay) {
                        ForEach(SpendDisplay.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    // The extension renders from the same App Group value, but only on its
                    // next timeline; ask for one now so the widget matches what you just picked.
                    .onChange(of: spendDisplay) { _ in WidgetCenter.shared.reloadAllTimelines() }
                    Text("Cursor is the only provider that reports what a cycle costs; the others always show a percentage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Relay") {
                    TextField("ntfy server", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { model.updateNtfyServer(server) }
                }
                Section("Local network") {
                    LabeledContent("Last known address", value: model.configuration?.localURL ?? "Not yet resolved")
                    Text("Metria re-discovers the Mac over Bonjour automatically when it changes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Forget pairing", role: .destructive) { isForgetConfirmationShown = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { server = model.configuration?.ntfyServer ?? "https://ntfy.sh" }
            .confirmationDialog("Forget this Mac?", isPresented: $isForgetConfirmationShown, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    model.forget()
                    dismiss()
                }
            } message: {
                Text("You'll need to scan the QR code or re-enter the phrase to pair again.")
            }
        }
    }
}

#if DEBUG
#Preview {
    SettingsView().environmentObject(PairingViewModel())
}
#endif
