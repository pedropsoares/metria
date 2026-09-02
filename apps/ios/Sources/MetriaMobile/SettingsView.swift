import SwiftUI
import MetriaMobileKit

struct SettingsView: View {
    @EnvironmentObject private var model: PairingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var isForgetConfirmationShown = false

    var body: some View {
        NavigationStack {
            Form {
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
