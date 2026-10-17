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

    enum AgentFields {
        /// The prompt field of the New Agent and New Workspace sheets.
        static let prompt = "agentFields.prompt"
    }

    enum NewAgent {
        static let createButton = "newAgent.createButton"
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
