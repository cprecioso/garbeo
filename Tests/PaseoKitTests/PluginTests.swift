import Foundation
import Testing
@testable import PaseoKit

private func payload<P: Decodable>(_ json: String, as type: P.Type) throws -> P {
    try JSONDecoder().decode(SessionFrame<P>.self, from: Data(json.utf8)).message.payload
}

@Suite struct PluginDecodingTests {
    @Test func decodesPluginList() throws {
        let response = try payload("""
        {"type":"session","message":{"type":"plugin.list.response","payload":{"requestId":"l","plugins":[
          {"id":"local-example","path":"/p","enabled":true,"status":"running","installation":{"identity":{"kind":"directory","path":"/p"}}},
          {"id":"broken","path":"/b","enabled":true,"status":"failed","error":"boom","futureField":1},
          {"id":"odd","path":"/o","enabled":false,"status":"sleeping"}]}}}
        """, as: PluginListResponse.self)
        #expect(response.plugins.map(\.id) == ["local-example", "broken", "odd"])
        #expect(response.plugins[0].status == .running)
        #expect(response.plugins[1].error == "boom")
        #expect(response.plugins[2].status == .other("sleeping"))
    }

    @Test func decodesCatalog() throws {
        let response = try payload("""
        {"type":"session","message":{"type":"plugin.catalog.get.response","payload":{"requestId":"c","plugins":[
          {"id":"local-example","clientBundle":"(function(require) {\\nreturn {};\\n})","requirements":{"paseo":">=0.8.0"}},
          {"id":"usage","clientBundle":""}]}}}
        """, as: PluginCatalogResponse.self)
        #expect(response.plugins[0].hasClient)
        #expect(response.plugins[0].requirements?.paseo == ">=0.8.0")
        #expect(!response.plugins[1].hasClient)
    }

    @Test func decodesRpcOutput() throws {
        let response = try payload("""
        {"type":"session","message":{"type":"plugin.rpc.invoke.response","payload":{"requestId":"r","output":{"value":42,"handledBy":"plugin subprocess"}}}}
        """, as: PluginRpcInvokeResponse.self)
        #expect(response.output?["value"] == .number(42))
        let empty = try payload("""
        {"type":"session","message":{"type":"plugin.rpc.invoke.response","payload":{"requestId":"r"}}}
        """, as: PluginRpcInvokeResponse.self)
        #expect(empty.output == nil)
    }

    @Test func decodesCatalogChangedStatus() throws {
        let status = try payload("""
        {"type":"session","message":{"type":"status","payload":{"status":"plugin_catalog_changed","pluginId":"local-example"}}}
        """, as: PluginStatusPayload.self)
        #expect(status.status == "plugin_catalog_changed")
        #expect(status.pluginId == "local-example")
    }
}

/// Read-only plugin probes against a running daemon (`PASEO_LIVE_URL`). If the daemon has the
/// `local-example` plugin from getpaseo/paseo's plugin-examples installed, also round-trips its
/// `increment` RPC, which only computes a value.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LIVE_URL"] != nil))
struct LivePluginTests {
    @Test func listsCatalogAndInvokes() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = DaemonClient(
            endpoint: DaemonEndpoint(url: env["PASEO_LIVE_URL"]!, password: env["PASEO_PASSWORD"]),
            clientId: "paseo-swift-plugin-tests")
        let info = try await client.connect()
        defer { Task { await client.disconnect() } }
        guard info.supportsPlugins else { return }
        let plugins = try await client.listPlugins()
        let catalog = try await client.pluginCatalog()
        print("live: \(plugins.count) plugins, \(catalog.filter(\.hasClient).count) with client bundles")
        if catalog.contains(where: { $0.id == "local-example" }) {
            let output = try await client.invokePluginRpc(pluginId: "local-example", method: "increment", input: ["value": 41])
            #expect(output["value"] == .number(42))
            #expect(output["handledBy"] == .string("plugin subprocess"))
        }
        await #expect(throws: PaseoError.self) {
            _ = try await client.invokePluginRpc(pluginId: "definitely-not-installed", method: "x", input: [:])
        }
    }
}
