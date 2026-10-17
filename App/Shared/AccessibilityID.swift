/// Accessibility identifiers UI tests find elements by, shared by the app and `GarbeoUITests`.
/// Named `<area>.<element>` in lowerCamelCase; add one here, then `.accessibilityIdentifier(…)` it in the view.
enum AccessibilityID {
    enum Connect {
        static let screen = "connect.screen"
        static let address = "connect.address"
        static let connectButton = "connect.connectButton"
    }

    enum Sidebar {
        static let list = "sidebar.list"
        static let newAgent = "sidebar.newAgent"
    }

    enum Detail {
        static let empty = "detail.empty"
    }

    enum NewAgent {
        /// Shown until the first message is sent.
        static let placeholder = "newAgent.placeholder"
        static let workspace = "newAgent.workspace"
        static let provider = "newAgent.provider"
        static let model = "newAgent.model"
        static let mode = "newAgent.mode"
        static let error = "newAgent.error"
    }

    /// The message field of an agent or new agent chat.
    enum Composer {
        static let field = "composer.field"
        static let send = "composer.send"
    }
}
