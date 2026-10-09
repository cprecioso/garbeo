import PaseoKit
import SwiftUI

struct TransportIcon: View {
    let kind: TransportKind

    var body: some View {
        Image(systemName: kind == .relay ? "lock.shield" : "network")
            .foregroundStyle(kind == .relay ? Color.green : Color.accentColor)
            .frame(width: 22)
            .accessibilityLabel(kind.label)
    }
}

/// Sidebar footer showing which transport the current connection uses.
struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let endpoint = model.endpoint {
            HStack(spacing: 6) {
                TransportIcon(kind: endpoint.transportKind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(endpoint.transportKind.label).font(.caption.weight(.medium))
                    Text(endpoint.displayAddress).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .help(endpoint.transportKind == .relay
                ? "Connected through the Paseo relay. Traffic is end-to-end encrypted with the daemon's key."
                : "Connected directly to the daemon's WebSocket.")
        }
    }
}
