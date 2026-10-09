import * as Lucide from "lucide-react";
import { createElement, type ComponentType, type ReactElement } from "react";

type IconComponent = ComponentType<{ size?: number; color?: string }>;

// Plugins name icons by their Lucide export name ("Blocks", "MessageCircle"), as upstream does
// with lucide-react-native. lucide-react exports the same names for the web.
export function findPluginIcon(name: string): IconComponent | null {
  const candidate: unknown = Reflect.get(Lucide, name);
  if (candidate === Lucide.Icon || candidate === Lucide.createLucideIcon) return null;
  const isComponent =
    typeof candidate === "function" ||
    (typeof candidate === "object" && candidate !== null && "$$typeof" in candidate);
  return isComponent ? (candidate as IconComponent) : null;
}

export function resolvePluginIcon(name: string): IconComponent {
  const icon = findPluginIcon(name);
  if (!icon) throw new Error(`Unknown Lucide icon: ${name}`);
  return icon;
}

export function Icon({ name, size, color }: { name: string; size?: number; color?: string }): ReactElement | null {
  const icon = findPluginIcon(name);
  return icon ? createElement(icon, { size, color }) : null;
}
