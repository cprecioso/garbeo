import PaseoKit
import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var hostStore = HostStore.shared
    @State private var address = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var inputError: String?
    @State private var showingScanner = false
    @State private var showingCredits = false
    @State private var localDaemonRunning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if localDaemonRunning && !hostStore.hosts.contains(where: LocalDaemon.matches) {
                    LocalDaemonBanner(action: connectToLocalDaemon)
                        .disabled(isConnecting)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 480)
                }

                Form {
                    if !hostStore.hosts.isEmpty {
                        Section("Saved hosts") {
                            ForEach(hostStore.sortedHosts) { host in
                                SavedHostRow(host: host) { connect(to: host) }
                                    .contextMenu {
                                        Button("Remove", systemImage: "trash", role: .destructive) { hostStore.remove(host) }
                                    }
                                    .swipeActions {
                                        Button("Remove", systemImage: "trash", role: .destructive) { hostStore.remove(host) }
                                    }
                            }
                        }
                    }

                    Section {
                        TextField("Address or pairing link", text: $address, prompt: Text(verbatim: "127.0.0.1:6767 or https://app.paseo.sh/#offer=…"))
                            .accessibilityIdentifier(AccessibilityID.Connect.address)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                        SecureField("Password (optional)", text: $password)
                    } header: {
                        Text("Add a host")
                    } footer: {
                        AddressHint(address: address)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 480)
                #if os(iOS)
                .frame(minHeight: hostStore.hosts.isEmpty ? 190 : 300)
                .scrollDisabled(true)
                #else
                .fixedSize(horizontal: false, vertical: true)
                #endif
                .onSubmit(connectToInput)

                if let message = inputError ?? failureMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .frame(maxWidth: 480)
                }

                VStack(spacing: 12) {
                    Button(action: connectToInput) {
                        Text("Connect").frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.Connect.connectButton)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)

                    HStack(spacing: 12) {
                        #if os(iOS)
                        Button {
                            showingScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        #endif
                        PasteButton(payloadType: String.self) { strings in
                            guard let link = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                            Task { @MainActor in pairWithLink(link) }
                        }
                        .labelStyle(.titleAndIcon)
                        .help("Paste a pairing link copied from \"paseo daemon pair\" or Paseo Desktop")
                    }
                    .disabled(isConnecting)
                }

                Text("To connect from anywhere, run `paseo daemon pair` on the host (or use **Pair a device** in Paseo Desktop) and scan the QR code or paste the link. Relay traffic is end-to-end encrypted. On a LAN or Tailscale you can also enter the daemon's `host:port`.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                #if os(iOS)
                // macOS has Credits in the app menu.
                Button("Credits") { showingCredits = true }
                    .font(.footnote)
                #endif
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(AccessibilityID.Connect.screen)
        .onAppear {
            if let endpoint = model.endpoint, endpoint.transportKind == .direct {
                address = endpoint.url
                password = endpoint.password ?? ""
            } else if hostStore.hosts.isEmpty {
                address = LocalDaemon.address
            }
        }
        .task {
            // Keep probing so the banner appears when the daemon starts while this screen is up.
            while !Task.isCancelled {
                localDaemonRunning = await LocalDaemon.isRunning()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingScanner) {
            QRScannerSheet { link in pairWithLink(link) }
        }
        .sheet(isPresented: $showingCredits) { CreditsView() }
        #endif
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Garbeo")
                .font(.largeTitle.weight(.semibold))
            Text("Connect to a Paseo daemon to manage your coding agents.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = model.connection { message } else { nil }
    }

    private func connectToInput() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let password = password.isEmpty ? nil : password
        if PairingLink.isPairingLink(input) {
            do {
                connect(try DaemonEndpoint.fromPairingLink(input, password: password))
            } catch {
                inputError = error.localizedDescription
            }
        } else {
            connect(DaemonEndpoint(url: input, password: password))
        }
    }

    /// Fills in the local address and connects, using the password field if the daemon needs one.
    private func connectToLocalDaemon() {
        address = LocalDaemon.address
        connectToInput()
    }

    private func pairWithLink(_ link: String) {
        guard PairingLink.isPairingLink(link) else {
            inputError = "The clipboard doesn't contain a Paseo pairing link."
            return
        }
        address = link
        connectToInput()
    }

    private func connect(to host: SavedHost) {
        guard let endpoint = hostStore.endpoint(for: host) else {
            inputError = "The pairing key for \(host.name) is missing from the Keychain. Pair again."
            return
        }
        connect(endpoint)
    }

    private func connect(_ endpoint: DaemonEndpoint) {
        guard !isConnecting else { return }
        inputError = nil
        isConnecting = true
        Task {
            await model.connect(to: endpoint)
            isConnecting = false
        }
    }
}

private struct SavedHostRow: View {
    let host: SavedHost
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                TransportIcon(kind: host.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).foregroundStyle(.primary)
                    Text(host.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A daemon listening on the default local address (this Mac, or the host Mac from the iOS Simulator).
private enum LocalDaemon {
    static let address = "127.0.0.1:6767"

    /// `GET /api/health` is the one daemon route that needs no password.
    static func isRunning() async -> Bool {
        struct Health: Decodable { var status: String }
        let request = URLRequest(
            url: URL(string: "http://\(address)/api/health")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return (try? JSONDecoder().decode(Health.self, from: data))?.status == "ok"
    }

    /// Whether a saved host already points at the local daemon (`localhost:6767`, `ws://127.0.0.1:6767/ws`, …).
    static func matches(_ host: SavedHost) -> Bool {
        let endpoint = DaemonEndpoint(url: host.address)
        guard host.kind == .direct, endpoint.isLoopback else { return false }
        return (try? endpoint.webSocketURL())?.port == 6767
    }
}

private struct LocalDaemonBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local daemon detected").font(.headline)
                Text(verbatim: LocalDaemon.address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect", action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Live feedback on what the address field will connect to.
private struct AddressHint: View {
    let address: String

    var body: some View {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if PairingLink.isPairingLink(input) {
            switch Result(catching: { try PairingLink.parse(input) }) {
            case .success(let parsed):
                Label("Relay pairing for \(parsed.connection.serverId) via \(parsed.connection.endpoint), end-to-end encrypted",
                      systemImage: "lock.shield")
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }
}
