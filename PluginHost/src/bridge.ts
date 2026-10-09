// The WKWebView bridge. JS -> Swift goes through `window.webkit.messageHandlers.paseoHost`, a
// WKScriptMessageHandlerWithReply, so every post returns a promise of Swift's reply. Swift -> JS
// calls `window.__paseoHost.receive(message)`.

export type HostTheme = {
  colors: {
    surface0: string;
    surface1: string;
    surface2: string;
    border: string;
    foreground: string;
    foregroundMuted: string;
    accent: string;
    accentForeground: string;
    statusSuccess: string;
    statusWarning: string;
    statusDanger: string;
  };
};

export type PaneTarget =
  | { kind: "screen"; pluginId: string; screenId: string; params: Record<string, string> }
  | { kind: "panel"; pluginId: string; panelId: string; workspaceId: string; agentId?: string | null };

export interface InitMessage {
  type: "init";
  mode: "registry" | "pane";
  plugins: { id: string; clientBundle: string }[];
  target?: PaneTarget;
  host: { id: string; label: string };
  layout: { compact: boolean; platform: "ios" | "android" | "web" };
  theme: HostTheme;
  colorScheme: "light" | "dark";
  connection: { clientId: string; password?: string | null; appVersion: string };
  state: { workspaces: unknown[]; agents: unknown[] };
  currentScreen?: { pluginId: string; screenId: string; params: Record<string, string> } | null;
}

export type InboundMessage =
  | InitMessage
  | { type: "theme"; theme: HostTheme; colorScheme: "light" | "dark" }
  | { type: "state"; workspaces: unknown[]; agents: unknown[] }
  | { type: "socket"; socketId: string; event: "open" | "message" | "close" | "error"; data?: string; reason?: string }
  | { type: "sidebar.press"; key: string }
  | { type: "command.select"; pluginId: string; itemId: string; workspaceId?: string | null; agentId?: string | null }
  | { type: "currentScreen"; screen: { pluginId: string; screenId: string; params: Record<string, string> } | null }
  | { type: "settingsChanged"; pluginId: string; settingsId: string };

type Handler = { postMessage(message: unknown): Promise<unknown> };

function handler(): Handler | null {
  const webkit = (globalThis as { webkit?: { messageHandlers?: Record<string, Handler> } }).webkit;
  return webkit?.messageHandlers?.paseoHost ?? null;
}

/** Posts to Swift and resolves with its reply. Swift replies with an error string to reject. */
export function post<T = unknown>(message: Record<string, unknown>): Promise<T> {
  const target = handler();
  if (!target) return Promise.reject(new Error("Paseo host bridge is unavailable"));
  return target.postMessage(message) as Promise<T>;
}

/** Fire-and-forget post; failures are logged, never thrown. */
export function notify(message: Record<string, unknown>): void {
  post(message).catch((error) => console.warn("[paseo-host]", message.type, error));
}

const listeners = new Set<(message: InboundMessage) => void>();

export function onMessage(listener: (message: InboundMessage) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

(globalThis as { __paseoHost?: unknown }).__paseoHost = {
  receive(message: InboundMessage) {
    for (const listener of [...listeners]) {
      try {
        listener(message);
      } catch (error) {
        console.error("[paseo-host] listener failed", error);
      }
    }
  },
};

// Forward console output so plugin logs are visible from Xcode / os_log.
for (const level of ["log", "info", "warn", "error"] as const) {
  const original = console[level].bind(console);
  console[level] = (...args: unknown[]) => {
    original(...args);
    const text = args
      .map((arg) => {
        if (arg instanceof Error) return `${arg.name}: ${arg.message}`;
        if (typeof arg === "string") return arg;
        try {
          return JSON.stringify(arg);
        } catch {
          return String(arg);
        }
      })
      .join(" ");
    handler()?.postMessage({ type: "log", level, message: text }).catch(() => undefined);
  };
}
window.addEventListener("error", (event) => console.error("Uncaught", event.error ?? event.message));
window.addEventListener("unhandledrejection", (event) => console.error("Unhandled rejection", event.reason));
