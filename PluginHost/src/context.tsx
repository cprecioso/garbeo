import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from "react";
import { Text, View } from "react-native";
import type { HostTheme } from "./bridge";

export const ThemeContext = createContext<HostTheme | null>(null);

export function useHostTheme(): HostTheme {
  const theme = useContext(ThemeContext);
  if (!theme) throw new Error("Plugin UI must render inside the Paseo host");
  return theme;
}

// Sidebar items render their rows through SidebarRow; the registry collects what they render
// so the app can draw native rows, and routes presses back to the row's onPress.
export interface SidebarRowReport {
  key: string;
  label: string;
  icon: string | null;
  active: boolean;
}

export interface SidebarFrame {
  pluginId: string;
  itemId: string;
  title: string;
  section: "header" | "footer";
  report(rowId: string, row: (SidebarRowReport & { onPress(): void }) | null): void;
}

export const SidebarFrameContext = createContext<SidebarFrame | null>(null);

export function useSidebarFrame(component: string): SidebarFrame {
  const frame = useContext(SidebarFrameContext);
  if (!frame) throw new Error(`${component} must render inside a plugin sidebar item`);
  return frame;
}

// Toasts render inside the pane, over the plugin's content.
export type ToastVariant = "default" | "info" | "success" | "warning" | "error";
interface ToastEntry {
  id: number;
  message: string;
  variant: ToastVariant;
}
export interface ToastApi {
  show(message: string, options?: { variant?: ToastVariant; durationMs?: number }): void;
  error(message: string): void;
}

const ToastContext = createContext<ToastApi | null>(null);

export function useToastApi(): ToastApi {
  const api = useContext(ToastContext);
  if (!api) throw new Error("useToast must run inside a contributed plugin surface");
  return api;
}

export function ToastHost({ children }: { children: ReactNode }) {
  const theme = useHostTheme();
  const [toasts, setToasts] = useState<ToastEntry[]>([]);
  const nextId = useRef(0);
  const dismiss = useCallback((id: number) => setToasts((list) => list.filter((toast) => toast.id !== id)), []);
  const api = useMemo<ToastApi>(() => {
    const show: ToastApi["show"] = (message, options) => {
      const id = ++nextId.current;
      setToasts((list) => [...list.slice(-2), { id, message, variant: options?.variant ?? "default" }]);
      setTimeout(() => dismiss(id), options?.durationMs ?? 3000);
    };
    return { show, error: (message) => show(message, { variant: "error" }) };
  }, [dismiss]);
  const tint = (variant: ToastVariant) =>
    variant === "error"
      ? theme.colors.statusDanger
      : variant === "warning"
        ? theme.colors.statusWarning
        : variant === "success"
          ? theme.colors.statusSuccess
          : theme.colors.border;
  return (
    <ToastContext.Provider value={api}>
      {children}
      <View pointerEvents="none" style={{ position: "absolute", left: 0, right: 0, bottom: 16, alignItems: "center", gap: 8 }}>
        {toasts.map((toast) => (
          <View
            key={toast.id}
            style={{
              maxWidth: 420,
              paddingVertical: 8,
              paddingHorizontal: 14,
              borderRadius: 10,
              borderWidth: 1,
              borderColor: tint(toast.variant),
              backgroundColor: theme.colors.surface2,
            }}
          >
            <Text style={{ color: theme.colors.foreground }}>{toast.message}</Text>
          </View>
        ))}
      </View>
    </ToastContext.Provider>
  );
}
