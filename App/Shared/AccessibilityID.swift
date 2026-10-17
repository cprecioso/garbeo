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
    }

    enum Detail {
        static let empty = "detail.empty"
    }

    enum Workspace {
        static let view = "workspace.view"
    }

    enum Terminal {
        static let view = "terminal.view"
    }
}
