// Entry point of the plugin host page. One page runs in one of two modes:
// - "registry": a hidden page per daemon connection. Evaluates every plugin's client bundle,
//   reports contribution metadata to the app, renders sidebar items headlessly so the app can
//   draw native rows, and runs Command Center callbacks.
// - "pane": renders one screen or workspace panel of one plugin.
import { createPaseoApi } from "@getpaseo/client";
import { DaemonClient } from "@getpaseo/client/internal/daemon-client";
import {
  callPluginRpc,
  PaseoApiProvider,
  PluginClientStateProvider,
  PluginRpcProvider,
  type PluginClientStateSource,
} from "@getpaseo/plugin/client/host";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Component, useMemo, useSyncExternalStore, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { Text, View } from "react-native";
import { notify, onMessage, post, type HostTheme, type InitMessage, type PaneTarget } from "./bridge";
import { SidebarFrameContext, ThemeContext, ToastHost, type SidebarFrame, type SidebarRowReport } from "./context";
import { runPluginClientBundle, type EvaluatedPlugin, type PluginRuntime } from "./evaluate";
import { pluginSettingsKey } from "./settings";
import { bridgedTransportFactory } from "./transport";

type Snapshot = { id: string; [key: string]: unknown };
type ScreenLocation = { pluginId: string; screenId: string; params: Record<string, string> };

// MARK: Host state pushed by the app

function createStore<T>(initial: T) {
  let value = initial;
  const listeners = new Set<() => void>();
  return {
    get: () => value,
    set(next: T) {
      value = next;
      for (const listener of [...listeners]) listener();
    },
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

const themeStore = createStore<HostTheme | null>(null);
const currentScreenStore = createStore<ScreenLocation | null>(null);
const entities = createStore<{ workspaces: Map<string, Snapshot>; agents: Map<string, Snapshot> }>({
  workspaces: new Map(),
  agents: new Map(),
});

function freezeAll(list: unknown[], previous: Map<string, Snapshot>): Map<string, Snapshot> {
  const next = new Map<string, Snapshot>();
  for (const raw of list as Snapshot[]) {
    const old = previous.get(raw.id);
    // Keep identity when nothing changed so selectors don't re-render.
    next.set(raw.id, old && JSON.stringify(old) === JSON.stringify(raw) ? old : Object.freeze({ ...raw }));
  }
  return next;
}

function applyState(state: { workspaces: unknown[]; agents: unknown[] }) {
  const current = entities.get();
  entities.set({ workspaces: freezeAll(state.workspaces, current.workspaces), agents: freezeAll(state.agents, current.agents) });
}

const stateSource: PluginClientStateSource = {
  subscribe: entities.subscribe,
  getWorkspace: (id) => (entities.get().workspaces.get(id) ?? null) as never,
  getAgent: (id) => (entities.get().agents.get(id) ?? null) as never,
};

function applyTheme(theme: HostTheme, colorScheme: "light" | "dark") {
  themeStore.set(theme);
  const style = document.documentElement.style;
  style.colorScheme = colorScheme;
  style.background = theme.colors.surface0;
  style.color = theme.colors.foreground;
}

// MARK: Installation: one per evaluated plugin

interface Installation {
  plugin: EvaluatedPlugin;
  queryClient: QueryClient;
  invoke(method: string, input: unknown): Promise<unknown>;
}

const installations = new Map<string, Installation>();
const failures: { pluginId: string; message: string }[] = [];

function startPaseoApi(init: InitMessage) {
  const client = new DaemonClient({
    url: "ws://paseo-app-bridge/ws",
    clientId: init.connection.clientId,
    clientType: "browser",
    appVersion: init.connection.appVersion,
    ...(init.connection.password ? { password: init.connection.password } : {}),
    transportFactory: bridgedTransportFactory,
    reconnect: { enabled: true },
  });
  const connected = client.connect().then(
    () => true,
    (error: unknown) => {
      console.warn("Paseo API connection failed", error);
      return false;
    },
  );
  return { paseo: createPaseoApi(client), connected };
}

function install(init: InitMessage, paseo: unknown, source: { id: string; clientBundle: string }, paneWorkspaceId?: string) {
  const invoke = (method: string, input: unknown) => post({ type: "rpc", pluginId: source.id, method, input });
  const hosts = Object.freeze([Object.freeze({ serverId: init.host.id, label: init.host.label, status: "online" })]);
  const runtime: PluginRuntime = {
    paseo,
    rpc: (contract, input) => callPluginRpc(contract as never, invoke, input),
    openScreen: ({ screenId, params }) => notify({ type: "openScreen", pluginId: source.id, screenId, params: params ?? {} }),
    openPanel: (panelId, options) =>
      notify({
        type: "openPanel",
        pluginId: source.id,
        panelId,
        workspaceId: options?.workspaceId ?? paneWorkspaceId ?? null,
        agentId: options?.agentId ?? null,
      }),
    openSettings: (settingsId) => notify({ type: "openSettings", pluginId: source.id, settingsId }),
    async playAudio({ base64, mimeType }) {
      await new Audio(`data:${mimeType};base64,${base64}`).play();
    },
    getPaseoClient(serverId) {
      if (serverId !== init.host.id) throw new Error(`Unknown Paseo host: ${serverId}`);
      return paseo;
    },
    useHosts: () => hosts,
  };
  try {
    const plugin = runPluginClientBundle(source.id, source.clientBundle, runtime);
    const installation = { plugin, invoke, queryClient: new QueryClient() };
    installations.set(source.id, installation);
    return installation;
  } catch (error) {
    console.error(`Plugin ${source.id} failed to load`, error);
    failures.push({ pluginId: source.id, message: error instanceof Error ? error.message : String(error) });
    return null;
  }
}

// MARK: Rendering

function useTheme(): HostTheme {
  const theme = useSyncExternalStore(themeStore.subscribe, themeStore.get);
  if (!theme) throw new Error("Theme not set");
  return theme;
}

class ErrorBoundary extends Component<{ label: string; children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) {
    return { error };
  }
  componentDidCatch(error: Error) {
    console.error(`${this.props.label} crashed`, error);
  }
  render() {
    if (this.state.error) return <Message text={`${this.props.label} crashed: ${this.state.error.message}`} danger />;
    return this.props.children;
  }
}

function Message({ text, danger }: { text: string; danger?: boolean }) {
  const theme = useTheme();
  return (
    <View style={{ flex: 1, alignItems: "center", justifyContent: "center", padding: 24 }}>
      <Text style={{ color: danger ? theme.colors.statusDanger : theme.colors.foregroundMuted, textAlign: "center" }}>{text}</Text>
    </View>
  );
}

function InstallationProviders({ installation, paseo, children }: { installation: Installation; paseo: unknown; children: ReactNode }) {
  const theme = useTheme();
  return (
    <ThemeContext.Provider value={theme}>
      <QueryClientProvider client={installation.queryClient}>
        <PaseoApiProvider paseo={paseo as never}>
          <PluginRpcProvider invoke={installation.invoke}>
            <PluginClientStateProvider source={stateSource}>{children}</PluginClientStateProvider>
          </PluginRpcProvider>
        </PaseoApiProvider>
      </QueryClientProvider>
    </ThemeContext.Provider>
  );
}

function navigationFor(): { openAgent(input: { agentId: string }): void; openWorkspace(input: { workspaceId: string }): void } {
  return {
    openAgent: ({ agentId }) => notify({ type: "openAgent", agentId }),
    openWorkspace: ({ workspaceId }) => notify({ type: "openWorkspace", workspaceId }),
  };
}

function PaneRoot({ init, target, paseo }: { init: InitMessage; target: PaneTarget; paseo: unknown }) {
  const theme = useTheme();
  const installation = installations.get(target.pluginId);
  const navigation = useMemo(navigationFor, []);
  const hostProps = { theme, host: init.host, layout: init.layout };
  let body: ReactNode;
  if (!installation) {
    const failure = failures.find((entry) => entry.pluginId === target.pluginId);
    body = <Message text={failure ? `Plugin failed to load: ${failure.message}` : "This plugin is unavailable."} danger={Boolean(failure)} />;
  } else if (target.kind === "screen") {
    const screen =
      installation.plugin.screens.find((entry) => entry.id === target.screenId) ??
      installation.plugin.settingsScreens.find((entry) => entry.id === target.screenId);
    if (!screen) {
      body = <Message text="This plugin screen is unavailable." />;
    } else {
      const Screen = screen.Component;
      body = <Screen {...hostProps} navigation={navigation} params={target.params} />;
    }
  } else {
    const panel = installation.plugin.workspacePanels.find((entry) => entry.id === target.panelId);
    if (!panel) {
      body = <Message text="This plugin panel is unavailable." />;
    } else if (panel.context === "agent" && !target.agentId) {
      body = <Message text="This panel needs an agent." />;
    } else {
      const Panel = panel.Component;
      body =
        panel.context === "agent" ? (
          <Panel {...hostProps} navigation={navigation} context="agent" workspaceId={target.workspaceId} agentId={target.agentId} />
        ) : (
          <Panel {...hostProps} navigation={navigation} context="workspace" workspaceId={target.workspaceId} />
        );
    }
  }
  return (
    <ThemeContext.Provider value={theme}>
      <View style={{ flex: 1, minHeight: "100%", backgroundColor: theme.colors.surface0 }}>
        <ErrorBoundary label={target.pluginId}>
          {installation ? (
            <InstallationProviders installation={installation} paseo={paseo}>
              <ToastHost>{body}</ToastHost>
            </InstallationProviders>
          ) : (
            body
          )}
        </ErrorBoundary>
      </View>
    </ThemeContext.Provider>
  );
}

// MARK: Registry: headless sidebar items

const sidebarRows = new Map<string, SidebarRowReport & { onPress(): void; order: string }>();
let sidebarFlush: ReturnType<typeof setTimeout> | null = null;

function scheduleSidebarReport() {
  if (sidebarFlush) return;
  sidebarFlush = setTimeout(() => {
    sidebarFlush = null;
    const rows = [...sidebarRows.values()]
      .sort((a, b) => a.order.localeCompare(b.order))
      .map(({ key, label, icon, active }) => {
        const [pluginId, section, itemId] = key.split("/");
        return { key, pluginId, section, itemId, label, icon, active };
      });
    notify({ type: "sidebar", rows });
  }, 16);
}

function SidebarItems({ init, paseo }: { init: InitMessage; paseo: unknown }) {
  const theme = useTheme();
  const currentScreen = useSyncExternalStore(currentScreenStore.subscribe, currentScreenStore.get);
  const items = [...installations.values()].flatMap((installation, pluginIndex) =>
    (["header", "footer"] as const).flatMap((section) =>
      installation.plugin.sidebarItems[section].map((item, itemIndex) => ({ installation, section, item, pluginIndex, itemIndex })),
    ),
  );
  return (
    <>
      {items.map(({ installation, section, item, pluginIndex, itemIndex }) => (
        <SidebarItem
          key={`${installation.plugin.id}/${section}/${item.id}`}
          init={init}
          paseo={paseo}
          theme={theme}
          installation={installation}
          section={section}
          item={item}
          order={`${section === "header" ? 0 : 1}-${String(pluginIndex).padStart(4, "0")}-${String(itemIndex).padStart(4, "0")}`}
          currentScreen={currentScreen?.pluginId === installation.plugin.id ? { screenId: currentScreen.screenId, params: currentScreen.params } : null}
        />
      ))}
    </>
  );
}

function SidebarItem(props: {
  init: InitMessage;
  paseo: unknown;
  theme: HostTheme;
  installation: Installation;
  section: "header" | "footer";
  item: { id: string; title: string; Component: React.ComponentType<any> };
  order: string;
  currentScreen: { screenId: string; params: Record<string, string> } | null;
}) {
  const { installation, section, item, order } = props;
  const pluginId = installation.plugin.id;
  const frame = useMemo<SidebarFrame>(() => {
    let rowIndex = 0;
    const rowOrder = new Map<string, number>();
    return {
      pluginId,
      itemId: item.id,
      title: item.title,
      section,
      report(rowId, row) {
        const key = `${pluginId}/${section}/${item.id}/${rowId}`;
        if (row) {
          if (!rowOrder.has(rowId)) rowOrder.set(rowId, rowIndex++);
          sidebarRows.set(key, { ...row, order: `${order}-${String(rowOrder.get(rowId)).padStart(4, "0")}` });
        } else {
          sidebarRows.delete(key);
        }
        scheduleSidebarReport();
      },
    };
  }, [pluginId, section, item.id, item.title, order]);
  const Item = item.Component;
  return (
    <ErrorBoundary label={`${pluginId} sidebar item ${item.id}`}>
      <InstallationProviders installation={installation} paseo={props.paseo}>
        <SidebarFrameContext.Provider value={frame}>
          <Item
            theme={props.theme}
            host={props.init.host}
            layout={props.init.layout}
            currentScreen={props.currentScreen}
            openScreen={({ screenId, params }: { screenId: string; params?: Record<string, string> }) =>
              notify({ type: "openScreen", pluginId, screenId, params: params ?? {} })
            }
            openPopover={() => console.warn(`${pluginId}: sidebar popovers are not supported by this host yet`)}
          />
        </SidebarFrameContext.Provider>
      </InstallationProviders>
    </ErrorBoundary>
  );
}

function reportContributions() {
  const plugins = [...installations.values()].map(({ plugin }) => ({
    id: plugin.id,
    screens: plugin.screens.map((screen) => ({ id: screen.id, title: typeof screen.title === "string" ? screen.title : null })),
    settingsScreens: plugin.settingsScreens.map(({ id, title, icon }) => ({ id, title, icon })),
    panels: plugin.workspacePanels.map(({ id, title, icon, context, locations }) => ({ id, title, icon, context, locations })),
    commands: plugin.commandCenterItems.map(({ id, title, icon, context, keywords }) => ({ id, title, icon, context, keywords: keywords ?? [] })),
    legacySidebarItems: plugin.legacySidebarItems,
    sidebarItems: (["header", "footer"] as const).flatMap((section) =>
      plugin.sidebarItems[section].map(({ id, title }) => ({ id, title, section })),
    ),
    unsupported: plugin.unsupported,
  }));
  notify({ type: "contributions", plugins, failures });
}

function selectCommand(message: { pluginId: string; itemId: string; workspaceId?: string | null; agentId?: string | null }, paseo: unknown) {
  const installation = installations.get(message.pluginId);
  const item = installation?.plugin.commandCenterItems.find((entry) => entry.id === message.itemId);
  if (!installation || !item) return;
  const pluginId = message.pluginId;
  const workspace = message.workspaceId ? entities.get().workspaces.get(message.workspaceId) : undefined;
  const agent = message.agentId ? entities.get().agents.get(message.agentId) : undefined;
  const capabilities = {
    paseo,
    rpc: (contract: never, input: unknown) => callPluginRpc(contract, installation.invoke, input),
    openScreen: ({ screenId, params }: { screenId: string; params?: Record<string, string> }) =>
      notify({ type: "openScreen", pluginId, screenId, params: params ?? {} }),
    openSurface: (screenId: string) => notify({ type: "openScreen", pluginId, screenId, params: {} }),
    openSettings: (settingsId: string) => notify({ type: "openSettings", pluginId, settingsId }),
  };
  const openPanel = (panelId: string, options?: { workspaceId?: string; agentId?: string }) =>
    notify({
      type: "openPanel",
      pluginId,
      panelId,
      workspaceId: options?.workspaceId ?? message.workspaceId ?? null,
      agentId: options?.agentId ?? message.agentId ?? null,
    });
  const context =
    item.context === "global"
      ? { ...capabilities, context: "global" }
      : item.context === "workspace"
        ? { ...capabilities, context: "workspace", workspace, openPanel }
        : { ...capabilities, context: "agent", workspace, agent, openPanel };
  Promise.resolve()
    .then(() => item.onSelect(context))
    .catch((error) => console.error(`${pluginId} command ${item.id} failed`, error));
}

// MARK: Boot

let started = false;

async function start(init: InitMessage) {
  if (started) return;
  started = true;
  applyTheme(init.theme, init.colorScheme);
  applyState(init.state);
  currentScreenStore.set(init.currentScreen ?? null);
  const { paseo, connected } = startPaseoApi(init);
  onMessage((message) => {
    switch (message.type) {
      case "theme":
        applyTheme(message.theme, message.colorScheme);
        break;
      case "state":
        applyState(message);
        break;
      case "currentScreen":
        currentScreenStore.set(message.screen);
        break;
      case "sidebar.press":
        sidebarRows.get(message.key)?.onPress();
        break;
      case "command.select":
        selectCommand(message, paseo);
        break;
      case "settingsChanged":
        void installations.get(message.pluginId)?.queryClient.invalidateQueries({ queryKey: pluginSettingsKey(message.settingsId) });
        break;
    }
  });

  // Plugins may call the Paseo API while contributing; give the bridged socket a moment first.
  await Promise.race([connected, new Promise((resolve) => setTimeout(resolve, 3000))]);

  const paneWorkspaceId = init.target?.kind === "panel" ? init.target.workspaceId : undefined;
  const sources = init.mode === "pane" ? init.plugins.filter((plugin) => plugin.id === init.target?.pluginId) : init.plugins;
  for (const source of sources) {
    if (source.clientBundle) install(init, paseo, source, paneWorkspaceId);
  }

  const container = document.getElementById("root")!;
  const root = createRoot(container);
  if (init.mode === "registry") {
    reportContributions();
    root.render(<SidebarItems init={init} paseo={paseo} />);
    scheduleSidebarReport();
  } else if (init.target) {
    const target = init.target;
    if (target.kind === "screen") {
      const screen = installations.get(target.pluginId)?.plugin.screens.find((entry) => entry.id === target.screenId);
      if (screen && typeof screen.title === "function") {
        try {
          notify({ type: "title", title: screen.title(target.params) });
        } catch (error) {
          console.warn("Screen title failed", error);
        }
      }
    }
    root.render(<PaneRoot init={init} target={target} paseo={paseo} />);
    notify({ type: "rendered" });
  }
}

// The app injects the init payload with a WKUserScript; a host can also send it as a message.
const injected = (globalThis as { __paseoInit?: InitMessage }).__paseoInit;
if (injected) void start(injected);
else
  onMessage((message) => {
    if (message.type === "init") void start(message);
  });
notify({ type: "ready" });
