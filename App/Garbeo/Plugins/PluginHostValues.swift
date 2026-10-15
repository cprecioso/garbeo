import Foundation
import PaseoKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Values the app hands to plugin code: the theme (`PluginTheme`), host/layout props, and the
// frozen workspace/agent snapshots behind `useWorkspace` / `useAgent`.

enum PluginHostValues {
    /// `PluginTheme.colors`, resolved from the platform's semantic colors so panes match the app.
    static func theme(for scheme: ColorScheme) -> JSONValue {
        #if os(macOS)
        let palette: [(String, NSColor)] = [
            ("surface0", .windowBackgroundColor),
            ("surface1", .controlBackgroundColor),
            ("surface2", .unemphasizedSelectedContentBackgroundColor),
            ("border", .separatorColor),
            ("foreground", .labelColor),
            ("foregroundMuted", .secondaryLabelColor),
            ("accent", .controlAccentColor),
            ("accentForeground", .white),
            ("statusSuccess", .systemGreen),
            ("statusWarning", .systemOrange),
            ("statusDanger", .systemRed),
        ]
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        var colors: [String: JSONValue] = [:]
        appearance.performAsCurrentDrawingAppearance {
            for (key, color) in palette { colors[key] = .string(hex(color.usingColorSpace(.sRGB) ?? color)) }
        }
        #else
        let palette: [(String, UIColor)] = [
            ("surface0", .systemBackground),
            ("surface1", .secondarySystemBackground),
            ("surface2", .tertiarySystemBackground),
            ("border", .separator),
            ("foreground", .label),
            ("foregroundMuted", .secondaryLabel),
            ("accent", .tintColor),
            ("accentForeground", .white),
            ("statusSuccess", .systemGreen),
            ("statusWarning", .systemOrange),
            ("statusDanger", .systemRed),
        ]
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        var colors: [String: JSONValue] = [:]
        for (key, color) in palette { colors[key] = .string(hex(color.resolvedColor(with: traits))) }
        #endif
        return ["colors": .object(colors)]
    }

    #if os(macOS)
    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return hex(rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
    #else
    private static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return hex(r, g, b, a)
    }
    #endif

    private static func hex(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> String {
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
        return a >= 0.999 ? base : base + String(format: "%02x", byte(a))
    }

    static var platform: String {
        #if os(iOS)
        "ios"
        #else
        "web"
        #endif
    }

    /// `PluginWorkspaceSnapshot`. Fields the Swift model doesn't decode get conservative values.
    static func snapshot(_ workspace: Workspace) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(workspace.id),
            "projectId": .string(workspace.projectId),
            "projectDisplayName": .string(workspace.projectName),
            "projectRootPath": .string(workspace.projectRootPath ?? workspace.workspaceDirectory),
            "directory": .string(workspace.workspaceDirectory),
            "projectKind": workspace.gitRuntime != nil ? "git" : "directory",
            "kind": .string(workspace.workspaceKind ?? "directory"),
            "name": .string(workspace.name),
            "title": workspace.title.map(JSONValue.string) ?? .null,
            "status": .string(workspace.status ?? "done"),
            "statusEnteredAt": workspace.statusEnteredAt.map(JSONValue.string) ?? .null,
            "archivingAt": .null,
            "diffStat": .null,
        ]
        if let diff = workspace.diffStat {
            value["diffStat"] = ["additions": .number(Double(diff.additions)), "deletions": .number(Double(diff.deletions))]
        }
        return .object(value)
    }

    /// `PluginAgentSnapshot`, for agents placed in a workspace.
    static func snapshot(_ agent: Agent, workspaceId: String) -> JSONValue {
        let updated = agent.updatedAt ?? agent.createdAt ?? ""
        let attention = agent.attentionReason.flatMap { ["finished", "error", "permission"].contains($0) ? $0 : nil }
        return [
            "id": .string(agent.id),
            "workspaceId": .string(workspaceId),
            "provider": .string(agent.provider),
            "status": .string(agent.statusRaw),
            "createdAt": .string(agent.createdAt ?? updated),
            "updatedAt": .string(updated),
            "lastActivityAt": .string(agent.lastUserMessageAt ?? updated),
            "title": agent.title.map(JSONValue.string) ?? .null,
            "cwd": .string(agent.cwd),
            "model": agent.model.map(JSONValue.string) ?? .null,
            "currentModeId": agent.currentModeId.map(JSONValue.string) ?? .null,
            "thinkingOptionId": agent.thinkingOptionId.map(JSONValue.string) ?? .null,
            "requiresAttention": .bool(agent.requiresAttention ?? false),
            "attentionReason": attention.map(JSONValue.string) ?? .null,
            "parentAgentId": .null,
            "labels": [:],
        ]
    }
}

extension JSONValue {
    /// Foundation form for WKScriptMessage replies (NSNumber/NSString/NSArray/NSDictionary/NSNull).
    var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationObject)
        case .object(let values): values.mapValues(\.foundationObject)
        }
    }

    /// Converts a WKScriptMessage body back to JSON.
    init(foundation value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(foundation: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { JSONValue(foundation: $0) })
        default: self = .null
        }
    }

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
