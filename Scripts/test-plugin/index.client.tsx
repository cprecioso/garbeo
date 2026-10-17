// The plugin with-test-daemon.sh installs for UI tests (PASEO_LIVE_PLUGINS=1). Shaped like
// paseo-gh-stack: a workspace panel, a command that only opens it, and another workspace command.
export default function contribute(client: any) {
  client.addWorkspacePanel({
    id: "fixture",
    title: "Fixture Panel",
    icon: "Layers",
    context: "workspace",
    locations: ["workspace", "explorer"],
    Component: () => null,
  });
  client.addCommandCenterItem({
    id: "open-fixture",
    title: "Open Fixture Panel",
    icon: "Layers",
    context: "workspace",
    onSelect({ openPanel }: { openPanel(id: string): void }) {
      openPanel("fixture");
    },
  });
  client.addCommandCenterItem({
    id: "fixture-action",
    title: "Fixture: run action",
    icon: "Play",
    context: "workspace",
    onSelect() {},
  });
  return () => {};
}
