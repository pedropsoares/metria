import SwiftUI
import MetriaCore
import MetriaMobileKit

struct PairingView: View {
    @EnvironmentObject private var model: PairingViewModel
    @State private var isScannerShown = false
    @State private var phrase = ""
    @State private var server = "https://ntfy.sh"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let mascot = UsagePresentation.image(named: "metria-mascot") {
                    mascot.resizable().scaledToFit().frame(width: 96, height: 96)
                }
                Text("Pair with your Mac").font(.title2.bold())
                Text("Open Metria on your Mac, go to Settings → Phone, and scan the QR code — or enter the 12-word phrase below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    isScannerShown = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or enter the phrase").font(.footnote.bold())
                    TextField("twelve words separated by spaces", text: $phrase, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    TextField("ntfy server", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Pair with phrase") { pairWithPhrase() }
                        .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .sheet(isPresented: $isScannerShown) {
                ScannerSheet { text in
                    isScannerShown = false
                    handleScannedLink(text)
                }
            }
        }
    }

    private func handleScannedLink(_ text: String) {
        guard let url = URL(string: text), let configuration = PairingConfiguration.parse(link: url) else {
            errorMessage = "That QR code isn't a Metria pairing code."
            return
        }
        guard model.pair(with: configuration) else {
            errorMessage = "Couldn't save the pairing to this device's Keychain. The widget would stay unpaired, so pairing was not completed."
            return
        }
        errorMessage = nil
    }

    private func pairWithPhrase() {
        let words = phrase.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").map(String.init)
        guard let secret = PairingSecret.secret(from: words) else {
            errorMessage = "Those words don't match — check for typos and try again."
            return
        }
        let configuration = PairingConfiguration(secretBase64: Base64URL.encode(secret), ntfyServer: server, localURL: nil)
        guard model.pair(with: configuration) else {
            errorMessage = "Couldn't save the pairing to this device's Keychain. The widget would stay unpaired, so pairing was not completed."
            return
        }
        errorMessage = nil
    }
}

private struct ScannerSheet: View {
    let onDecode: (String) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerView(onDecode: onDecode)
                .ignoresSafeArea()
        }
    }
}

#if DEBUG
#Preview {
    PairingView().environmentObject(PairingViewModel())
}
#endif
