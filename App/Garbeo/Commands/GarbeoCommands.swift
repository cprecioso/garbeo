import SwiftUI

/// The menu bar, built from `AppModel.appCommands`. On iPad these are the hardware keyboard's
/// shortcuts and its menu bar.
struct GarbeoCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let commands = model.appCommands
        // New Agent takes ⌘N: the app has a single main window.
        CommandGroup(replacing: .newItem) { buttons(commands, in: .file) }
        CommandMenu("Agent") { buttons(commands, in: .agent) }
        CommandMenu("Go") { buttons(commands, in: .go) }
        CommandMenu("Daemon") { buttons(commands, in: .daemon) }
        if commands.contains(where: { $0.menu == .plugins }) {
            CommandMenu("Plugins") { buttons(commands, in: .plugins) }
        }
    }

    private func buttons(_ commands: [AppCommand], in menu: AppCommand.Menu) -> some View {
        ForEach(commands.filter { $0.menu == menu }) { command in
            Button(command.title, systemImage: command.systemImage, action: command.action)
                .keyboardShortcut(command.shortcut)
                .disabled(!command.isEnabled)
        }
    }
}
