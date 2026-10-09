import type { DaemonTransport, DaemonTransportFactory } from "@getpaseo/client/internal/daemon-client-transport-types";
import { notify, onMessage, post } from "./bridge";

// The daemon rejects WebSocket upgrades from origins it does not allow, and a page served from
// the app's custom scheme has such an origin. So the in-page DaemonClient talks to the daemon
// through a socket the app opens natively, with frames relayed over the bridge.

type Listeners = {
  message: Set<(data: unknown, isBinary: boolean) => void>;
  open: Set<() => void>;
  close: Set<(event?: unknown) => void>;
  error: Set<(event?: unknown) => void>;
};

const sockets = new Map<string, Listeners>();

onMessage((message) => {
  if (message.type !== "socket") return;
  const listeners = sockets.get(message.socketId);
  if (!listeners) return;
  switch (message.event) {
    case "open":
      for (const listener of listeners.open) listener();
      break;
    case "message":
      for (const listener of listeners.message) listener(message.data ?? "", false);
      break;
    case "error":
      for (const listener of listeners.error) listener(new Error(message.reason ?? "Socket error"));
      break;
    case "close":
      sockets.delete(message.socketId);
      for (const listener of listeners.close) listener({ code: 1006, reason: message.reason ?? "" });
      break;
  }
});

function subscribe<T>(set: Set<T>, listener: T): () => void {
  set.add(listener);
  return () => set.delete(listener);
}

export const bridgedTransportFactory: DaemonTransportFactory = () => {
  const socketId = Math.random().toString(36).slice(2) + Date.now().toString(36);
  const listeners: Listeners = { message: new Set(), open: new Set(), close: new Set(), error: new Set() };
  sockets.set(socketId, listeners);
  // The app ignores the URL: it always connects to the daemon it is attached to.
  post({ type: "socket.open", socketId }).catch((error) => {
    sockets.delete(socketId);
    for (const listener of listeners.error) listener(error);
    for (const listener of listeners.close) listener({ code: 1006, reason: String(error) });
  });
  const transport: DaemonTransport = {
    send(data) {
      if (typeof data !== "string") throw new Error("Binary frames are not supported by the plugin host");
      notify({ type: "socket.send", socketId, data });
    },
    close(code, reason) {
      sockets.delete(socketId);
      notify({ type: "socket.close", socketId, code: code ?? 1000, reason: reason ?? "" });
      for (const listener of listeners.close) listener({ code: code ?? 1000, reason: reason ?? "" });
    },
    onMessage: (handler) => subscribe(listeners.message, handler),
    onOpen: (handler) => subscribe(listeners.open, handler),
    onClose: (handler) => subscribe(listeners.close, handler),
    onError: (handler) => subscribe(listeners.error, handler),
  };
  return transport;
};
