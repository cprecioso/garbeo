import PaseoKit
import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var url = "127.0.0.1:6767"
    @State private var password = ""
    @State private var isConnecting = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Paseo")
                    .font(.largeTitle.weight(.semibold))
                Text("Connect to a Paseo daemon to manage your coding agents.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Form {
                TextField("Daemon address", text: $url, prompt: Text("127.0.0.1:6767"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("Password (optional)", text: $password)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 440)
            #if os(iOS)
            .frame(maxHeight: 180)
            #else
            .fixedSize(horizontal: false, vertical: true)
            #endif
            .onSubmit(connect)

            if case .failed(let message) = model.connection {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: 440)
            }

            Button(action: connect) {
                Text("Connect").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)

            Text("Run `paseo daemon status` on the host to find its listen address. Remote hosts need the daemon to listen on a reachable interface (for example over Tailscale).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let endpoint = model.endpoint {
                url = endpoint.url
                password = endpoint.password ?? ""
            }
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        Task {
            await model.connect(to: DaemonEndpoint(url: url, password: password.isEmpty ? nil : password))
            isConnecting = false
        }
    }
}
