#if SPARKLE
import Combine
import Sparkle
import SwiftUI

/// Updates Developer ID builds from the download site's appcast. App Store builds update through the App Store.
@MainActor
final class SoftwareUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

struct CheckForUpdatesMenuItem: View {
    @ObservedObject var updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
#endif
