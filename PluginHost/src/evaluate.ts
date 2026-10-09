// Runs a plugin's `clientBundle` the way the official app does (packages/app/src/plugins/evaluate.ts):
// the daemon compiles `index.client.tsx` to `(function(require){ ... return module.exports; })`,
// the host evaluates it with a `require` that hands out the host's own modules, and calls the
// default export with a PluginClientContext that collects contributions.
import * as pluginShared from "@getpaseo/plugin";
import * as pluginClient from "@getpaseo/plugin/client";
import * as ReactQuery from "@tanstack/react-query";
import * as React from "react";
import * as ReactJsxRuntime from "react/jsx-runtime";
import * as ReactNative from "react-native";
import * as Zod from "zod";
import { resolvePluginIcon } from "./icons";
import { reactNativeRuntime } from "./rn-runtime";
import { useSettings } from "./settings";
import * as ui from "./ui";

type Cleanup = () => void | Promise<void>;
type AnyComponent = React.ComponentType<any>;

export interface ScreenContribution {
  id: string;
  title: string | ((params: Record<string, string>) => string);
  Component: AnyComponent;
}
export interface PanelContribution {
  id: string;
  title: string;
  icon: string;
  context: "workspace" | "agent";
  locations: readonly ("workspace" | "explorer")[];
  Component: AnyComponent;
}
export interface SidebarItemContribution {
  id: string;
  title: string;
  Component: AnyComponent;
}
export interface LegacySidebarItem {
  id: string;
  title: string;
  icon: string;
  surface: string;
}
export interface CommandContribution {
  id: string;
  title: string;
  icon: string;
  keywords?: readonly string[];
  context: "global" | "workspace" | "agent";
  onSelect(context: unknown): void | Promise<void>;
}
export interface SettingsScreenContribution {
  id: string;
  title: string;
  icon: string;
  Component: AnyComponent;
}

export interface EvaluatedPlugin {
  id: string;
  cleanup(): Promise<void>;
  screens: ScreenContribution[];
  settingsScreens: SettingsScreenContribution[];
  sidebarItems: { header: SidebarItemContribution[]; footer: SidebarItemContribution[] };
  legacySidebarItems: LegacySidebarItem[];
  workspacePanels: PanelContribution[];
  commandCenterItems: CommandContribution[];
  /** Contributions this host accepts but cannot show yet, by kind. */
  unsupported: string[];
}

/** The parts of PluginClientContext the host supplies (navigation, RPC, the Paseo API, hosts). */
export interface PluginRuntime {
  paseo: unknown;
  rpc(contract: unknown, input: unknown): Promise<unknown>;
  openScreen(input: { screenId: string; params?: Record<string, string> }): void;
  openPanel(id: string, options?: { workspaceId?: string; agentId?: string; location?: string }): void;
  openSettings(id: string): void;
  playAudio(input: { base64: string; mimeType: string }): Promise<void>;
  getPaseoClient(serverId: string): unknown;
  useHosts(): readonly { serverId: string; label: string; status: string }[];
}

const CONTRIBUTION_ID = /^[a-z][a-z0-9-]*$/;

function requireId(value: string, label: string): string {
  const id = String(value ?? "").trim();
  if (!CONTRIBUTION_ID.test(id)) throw new Error(`Invalid ${label}: ${value}`);
  return id;
}

function isComponentType(value: unknown): boolean {
  return typeof value === "function" || (typeof value === "object" && value !== null && "$$typeof" in value);
}

export function runPluginClientBundle(id: string, bundle: string, runtime: PluginRuntime): EvaluatedPlugin {
  const plugin: Omit<EvaluatedPlugin, "cleanup"> = {
    id,
    screens: [],
    settingsScreens: [],
    sidebarItems: { header: [], footer: [] },
    legacySidebarItems: [],
    workspacePanels: [],
    commandCenterItems: [],
    unsupported: [],
  };
  const removals = new Set<() => void>();
  function register<T>(items: T[], item: T): Cleanup {
    items.push(item);
    const remove = () => {
      const index = items.indexOf(item);
      if (index !== -1) items.splice(index, 1);
      removals.delete(remove);
    };
    removals.add(remove);
    return remove;
  }
  function unsupported(kind: string): Cleanup {
    if (!plugin.unsupported.includes(kind)) plugin.unsupported.push(kind);
    return () => undefined;
  }
  const inertButton = () => ({ update() {}, remove() {} });

  function addSidebarItem(section: "header" | "footer", contribution: SidebarItemContribution): Cleanup {
    const itemId = requireId(contribution.id, `sidebar ${section} item id`);
    const title = contribution.title.trim();
    if (!title) throw new Error(`Sidebar item ${itemId} has no title`);
    if (!isComponentType(contribution.Component)) throw new Error(`Sidebar item ${itemId} is not a component`);
    return register(plugin.sidebarItems[section], { id: itemId, title, Component: contribution.Component });
  }

  const context = {
    paseo: runtime.paseo,
    rpc: runtime.rpc,
    openScreen: runtime.openScreen,
    openSurface: (screenId: string) => runtime.openScreen({ screenId }),
    openPanel: runtime.openPanel,
    openSettings: runtime.openSettings,
    playAudio: runtime.playAudio,
    addScreen(contribution: ScreenContribution) {
      const screenId = requireId(contribution.id, "screen id");
      const title = typeof contribution.title === "function" ? contribution.title : String(contribution.title ?? "").trim();
      if (!title) throw new Error(`Screen ${screenId} needs a title`);
      if (!isComponentType(contribution.Component)) throw new Error(`Screen ${screenId} is not a component`);
      return register(plugin.screens, { id: screenId, title, Component: contribution.Component });
    },
    addSettingsScreen(contribution: SettingsScreenContribution) {
      const screenId = requireId(contribution.id, "settings screen id");
      resolvePluginIcon(contribution.icon);
      return register(plugin.settingsScreens, { ...contribution, id: screenId, title: contribution.title.trim() });
    },
    addSidebarHeaderItem: (contribution: SidebarItemContribution) => addSidebarItem("header", contribution),
    addSidebarFooterItem: (contribution: SidebarItemContribution) => addSidebarItem("footer", contribution),
    // COMPAT(pluginSidebarAliases) upstream: addSurface(id, Component) and addSidebarItem({ surface }).
    addSurface(surfaceId: string, Component: AnyComponent) {
      return context.addScreen({ id: surfaceId, title: surfaceId, Component });
    },
    addSidebarItem(contribution: LegacySidebarItem) {
      const itemId = requireId(contribution.id, "sidebar item id");
      resolvePluginIcon(contribution.icon.trim());
      return register(plugin.legacySidebarItems, {
        id: itemId,
        title: contribution.title.trim(),
        icon: contribution.icon.trim(),
        surface: requireId(contribution.surface, "sidebar surface id"),
      });
    },
    addWorkspacePanel(contribution: PanelContribution) {
      const panelId = requireId(contribution.id, "workspace panel id");
      const title = contribution.title.trim();
      const icon = contribution.icon.trim();
      if (!title) throw new Error(`Workspace panel ${panelId} has no title`);
      if (contribution.context !== "workspace" && contribution.context !== "agent") {
        throw new Error(`Workspace panel ${panelId} has invalid context`);
      }
      if (typeof contribution.Component !== "function") throw new Error(`Workspace panel ${panelId} is not a component`);
      resolvePluginIcon(icon);
      return register(plugin.workspacePanels, {
        ...contribution,
        id: panelId,
        title,
        icon,
        locations: contribution.locations ?? ["workspace"],
      });
    },
    addCommandCenterItem(contribution: CommandContribution) {
      const itemId = requireId(contribution.id, "Command Center item id");
      if (typeof contribution.onSelect !== "function") throw new Error(`Command Center item ${itemId} has no callback`);
      resolvePluginIcon(contribution.icon.trim());
      return register(plugin.commandCenterItems, { ...contribution, id: itemId, title: contribution.title.trim(), icon: contribution.icon.trim() });
    },
    addSlashCommand: () => unsupported("slashCommand"),
    addAttachmentSource: () => unsupported("attachmentSource"),
    addTheme: () => unsupported("theme"),
    addTimelineTransformer: () => unsupported("timelineTransformer"),
    addTimelineRenderer: () => unsupported("timelineRenderer"),
    addComposerPill: () => (unsupported("composerPill"), inertButton()),
    addHeaderButton: () => (unsupported("headerButton"), inertButton()),
  };

  const runtimeRequire = (name: string): unknown => {
    if (name === "@getpaseo/plugin/client/ui") return ui;
    if (name === "react") return React;
    if (name === "react/jsx-runtime") return ReactJsxRuntime;
    if (name === "react-native") return ReactNative;
    if (name === "@getpaseo/plugin") return pluginShared;
    if (name === "@getpaseo/plugin/client") {
      return {
        ...pluginClient,
        useSettings,
        openExternalUrl: ui.openExternalUrl,
        getPaseoClient: runtime.getPaseoClient,
        useHosts: runtime.useHosts,
      };
    }
    if (name === "@getpaseo/plugin/client/react-native") return reactNativeRuntime;
    if (name === "@tanstack/react-query") return ReactQuery;
    if (name === "zod") return Zod;
    throw new Error(`Module "${name}" is not available in plugin client code`);
  };

  const evaluate: (source: string) => unknown = globalThis.eval;
  const factory = evaluate(bundle);
  if (typeof factory !== "function") throw new Error(`Plugin ${id} client bundle is not executable`);
  const exports = (factory as (require: (name: string) => unknown) => unknown)(runtimeRequire);
  const setup = exports !== null && typeof exports === "object" ? Reflect.get(exports, "default") : undefined;
  if (typeof setup !== "function") throw new Error(`Plugin ${id} must default export a function`);
  const entryCleanup: unknown = setup(context);
  if (typeof entryCleanup !== "function") throw new Error(`Plugin ${id} contribution must return a cleanup function`);
  let stopped = false;
  return {
    ...plugin,
    async cleanup() {
      if (stopped) return;
      stopped = true;
      try {
        await (entryCleanup as Cleanup)();
      } finally {
        for (const remove of [...removals]) remove();
      }
    },
  };
}
