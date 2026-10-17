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
        static let workspaceRow = "sidebar.workspaceRow"
        static let newProject = "sidebar.newProject"
        static let newAgent = "sidebar.newAgent"

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

    enum Workspace {
        static let view = "workspace.view"
        static let openTabMenu = "workspace.openTabMenu"
    }

    enum Terminal {
        static let view = "terminal.view"
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

    enum AgentFields {
        /// The prompt field of the New Workspace sheet.
        static let prompt = "agentFields.prompt"
    }

    enum Timeline {
        /// A reasoning row's disclosure button.
        static let reasoning = "timeline.reasoning"
        /// A tool call row's disclosure button.
        static let toolCall = "timeline.toolCall"
        /// The disclosure button of consecutive reasoning and tool rows collapsed into one.
        static let activityGroup = "timeline.activityGroup"
    }
}
