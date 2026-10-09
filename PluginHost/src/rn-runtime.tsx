// `@getpaseo/plugin/client/react-native`: host-owned presentation pieces.
import { createContext, useContext, useMemo, type ReactNode } from "react";
import { FlatList, Pressable, ScrollView, Text, TextInput, View, type StyleProp, type ViewStyle } from "react-native";
import { post } from "./bridge";
import { useHostTheme, useToastApi, type ToastApi } from "./context";
import { Icon } from "./icons";

interface ModalProps {
  title: string;
  icon?: ReactNode;
  open: boolean;
  onOpenChange(open: boolean): void;
  children: ReactNode;
}

const ModalContext = createContext<{ open: boolean; dismiss(): void; title: string; icon?: ReactNode } | null>(null);

function ModalRoot({ title, icon, open, onOpenChange, children }: ModalProps) {
  const value = useMemo(() => ({ open, dismiss: () => onOpenChange(false), title, icon }), [open, onOpenChange, title, icon]);
  return <ModalContext.Provider value={value}>{children}</ModalContext.Provider>;
}

// The pane is already its own surface, so a modal is an overlay sheet inside it.
function ModalContent({
  children,
  style,
  contentContainerStyle,
  scrollable = true,
}: {
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  contentContainerStyle?: StyleProp<ViewStyle>;
  scrollable?: boolean;
}) {
  const modal = useContext(ModalContext);
  if (!modal) throw new Error("Modal.Content must be rendered inside Modal");
  const theme = useHostTheme();
  if (!modal.open) return null;
  const padding: StyleProp<ViewStyle> = [{ padding: 24, gap: 16 }, contentContainerStyle];
  return (
    <View
      style={{
        position: "fixed" as "absolute",
        inset: 0,
        zIndex: 1000,
        backgroundColor: "rgba(0,0,0,0.35)",
        alignItems: "center",
        justifyContent: "center",
        padding: 24,
      }}
    >
      <Pressable accessibilityLabel="Dismiss" onPress={modal.dismiss} style={{ position: "absolute", inset: 0 } as ViewStyle} />
      <View
        style={[
          {
            width: "100%",
            maxWidth: 640,
            maxHeight: "85%",
            borderRadius: 14,
            borderWidth: 1,
            borderColor: theme.colors.border,
            backgroundColor: theme.colors.surface0,
            overflow: "hidden",
          },
          style,
        ]}
      >
        <View
          style={{
            flexDirection: "row",
            alignItems: "center",
            gap: 8,
            paddingHorizontal: 16,
            paddingVertical: 12,
            borderBottomWidth: 1,
            borderBottomColor: theme.colors.border,
          }}
        >
          {modal.icon}
          <Text style={{ flex: 1, color: theme.colors.foreground, fontWeight: "600", fontSize: 15 }}>{modal.title}</Text>
          <Pressable accessibilityRole="button" accessibilityLabel="Close" onPress={modal.dismiss}>
            <Icon name="X" size={18} color={theme.colors.foregroundMuted} />
          </Pressable>
        </View>
        {scrollable ? (
          <ScrollView contentContainerStyle={padding}>{children}</ScrollView>
        ) : (
          <View style={[{ flex: 1 }, padding]}>{children}</View>
        )}
      </View>
    </View>
  );
}

const Modal = Object.assign(ModalRoot, { Content: ModalContent });

function useToast(): ToastApi {
  const toast = useToastApi();
  return useMemo(() => ({ show: toast.show, error: toast.error }), [toast]);
}

/** Streaming text reveal is cosmetic; panes show the text as it arrives. */
function useRevealedText(text: string): string {
  return text;
}

/** The page's clipboard API needs a secure origin and user activation, so the app copies. */
async function copyText(text: string): Promise<void> {
  await post({ type: "copy", text });
}

export const reactNativeRuntime = {
  Icon,
  Modal,
  ScrollView,
  FlatList,
  TextInput,
  copyText,
  useRevealedText,
  useToast,
};
