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
        static let newProject = "sidebar.newProject"

        /// A project's section header, by the project's name.
        static func project(_ name: String) -> String { "sidebar.project.\(name)" }
    }

    enum NewProject {
        static let path = "newProject.path"
        static let name = "newProject.name"
        static let error = "newProject.error"
        static let create = "newProject.create"
    }

    enum Detail {
        static let empty = "detail.empty"
    }
}
