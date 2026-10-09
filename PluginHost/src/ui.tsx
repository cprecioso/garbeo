// `@getpaseo/plugin/client/ui`: the host's settings kit, ExternalLink and sidebar rows, rebuilt
// with react-native-web primitives and the host theme.
import { forwardRef, useEffect, useImperativeHandle, useRef, useState, type ReactNode, type Ref } from "react";
import { Pressable, Switch, Text, TextInput, View } from "react-native";
import { notify } from "./bridge";
import { useHostTheme, useSidebarFrame } from "./context";

export function openExternalUrl(url: string): Promise<void> {
  if (!/^https?:\/\//i.test(url)) return Promise.reject(new Error(`Not an HTTP(S) URL: ${url}`));
  notify({ type: "openExternal", url });
  return Promise.resolve();
}

interface SectionProps {
  title: string;
  info?: ReactNode;
  trailing?: ReactNode;
  children: ReactNode;
  testID?: string;
}

export function SettingsSection({ title, info, trailing, children, testID }: SectionProps) {
  const theme = useHostTheme();
  return (
    <View testID={testID} style={{ gap: 8, marginBottom: 20 }}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
        <Text style={{ flex: 1, color: theme.colors.foregroundMuted, fontSize: 12, fontWeight: "600", textTransform: "uppercase" }}>
          {title}
        </Text>
        {trailing}
      </View>
      {info ? <Text style={{ color: theme.colors.foregroundMuted, fontSize: 13 }}>{info}</Text> : null}
      {children}
    </View>
  );
}

export const SettingsGroup = SettingsSection;

export function SettingsCard({ children, testID }: { children: ReactNode; testID?: string }) {
  const theme = useHostTheme();
  return (
    <View
      testID={testID}
      style={{ borderRadius: 10, borderWidth: 1, borderColor: theme.colors.border, backgroundColor: theme.colors.surface1 }}
    >
      {children}
    </View>
  );
}

interface RowProps {
  label: string;
  hint?: string;
  error?: string | null;
  children?: ReactNode;
  testID?: string;
}

export function SettingsRow({ label, hint, error, children, testID }: RowProps) {
  const theme = useHostTheme();
  return (
    <View testID={testID} style={{ padding: 12, gap: 6, borderBottomWidth: 1, borderBottomColor: theme.colors.border }}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={{ color: theme.colors.foreground }}>{label}</Text>
          {hint ? <Text style={{ color: theme.colors.foregroundMuted, fontSize: 12 }}>{hint}</Text> : null}
        </View>
        {children}
      </View>
      {error ? <Text style={{ color: theme.colors.statusDanger, fontSize: 12 }}>{error}</Text> : null}
    </View>
  );
}

export function SettingsSwitch({
  value,
  onValueChange,
  disabled,
  ...row
}: RowProps & { value: boolean; onValueChange(value: boolean): void; disabled?: boolean }) {
  const theme = useHostTheme();
  return (
    <SettingsRow {...row}>
      <Switch value={value} onValueChange={onValueChange} disabled={disabled} activeThumbColor={theme.colors.accent} />
    </SettingsRow>
  );
}

export function SettingsSelect<Value extends string>({
  value,
  options,
  onValueChange,
  disabled,
  ...row
}: RowProps & {
  value: Value;
  options: readonly { label: string; value: Value }[];
  onValueChange(value: Value): void;
  disabled?: boolean;
}) {
  const theme = useHostTheme();
  return (
    <SettingsRow {...row}>
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 4 }}>
        {options.map((option) => {
          const selected = option.value === value;
          return (
            <Pressable
              key={option.value}
              disabled={disabled}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              onPress={() => onValueChange(option.value)}
              style={{
                paddingVertical: 4,
                paddingHorizontal: 10,
                borderRadius: 6,
                borderWidth: 1,
                borderColor: selected ? theme.colors.accent : theme.colors.border,
                backgroundColor: selected ? theme.colors.accent : "transparent",
              }}
            >
              <Text style={{ color: selected ? theme.colors.accentForeground : theme.colors.foreground }}>{option.label}</Text>
            </Pressable>
          );
        })}
      </View>
    </SettingsRow>
  );
}

export interface SettingsInputHandle {
  focus(): void;
  blur(): void;
  getText(): string;
  replaceText(text: string): void;
}

export const SettingsInput = forwardRef(function SettingsInput(
  {
    initialValue,
    onChangeText,
    placeholder,
    disabled,
    secureTextEntry,
    ref: _ref,
    ...row
  }: RowProps & {
    initialValue?: string;
    onChangeText(text: string): void;
    placeholder?: string;
    disabled?: boolean;
    secureTextEntry?: boolean;
    ref?: Ref<SettingsInputHandle>;
  },
  ref: Ref<SettingsInputHandle>,
) {
  const theme = useHostTheme();
  const [text, setText] = useState(initialValue ?? "");
  const input = useRef<TextInput | null>(null);
  useImperativeHandle(ref ?? _ref, () => ({
    focus: () => input.current?.focus(),
    blur: () => input.current?.blur(),
    getText: () => text,
    replaceText: (next) => setText(next),
  }));
  return (
    <SettingsRow {...row}>
      <TextInput
        ref={input}
        value={text}
        editable={!disabled}
        secureTextEntry={secureTextEntry}
        placeholder={placeholder}
        placeholderTextColor={theme.colors.foregroundMuted}
        onChangeText={(next) => {
          setText(next);
          onChangeText(next);
        }}
        style={{
          minWidth: 200,
          paddingVertical: 6,
          paddingHorizontal: 8,
          borderRadius: 6,
          borderWidth: 1,
          borderColor: theme.colors.border,
          color: theme.colors.foreground,
          backgroundColor: theme.colors.surface0,
        }}
      />
    </SettingsRow>
  );
});

export function SettingsAction({
  actionLabel,
  onPress,
  disabled,
  ...row
}: RowProps & { actionLabel: string; onPress(): void; disabled?: boolean }) {
  const theme = useHostTheme();
  return (
    <SettingsRow {...row}>
      <Pressable
        accessibilityRole="button"
        disabled={disabled}
        onPress={onPress}
        style={{ paddingVertical: 6, paddingHorizontal: 12, borderRadius: 6, backgroundColor: theme.colors.surface2, opacity: disabled ? 0.5 : 1 }}
      >
        <Text style={{ color: theme.colors.foreground }}>{actionLabel}</Text>
      </Pressable>
    </SettingsRow>
  );
}

export function ExternalLink({
  href,
  children,
  accessibilityLabel,
  testID,
  onError,
}: {
  href: string;
  children: ReactNode;
  accessibilityLabel?: string;
  testID?: string;
  onError?: (error: unknown) => void;
}) {
  const theme = useHostTheme();
  return (
    <Text
      testID={testID}
      accessibilityRole="link"
      accessibilityLabel={accessibilityLabel}
      style={{ color: theme.colors.accent, textDecorationLine: "underline" }}
      onPress={() => {
        openExternalUrl(href).catch((error) => onError?.(error));
      }}
    >
      {children}
    </Text>
  );
}

type SidebarIcon = string | unknown;

export function SidebarRow({
  id,
  icon,
  label,
  onPress,
  active,
}: {
  id?: string;
  icon?: SidebarIcon;
  label?: string;
  onPress(): void;
  active?: boolean;
  trailing?: ReactNode;
}) {
  const frame = useSidebarFrame("SidebarRow");
  const rowId = id ?? "default";
  const onPressRef = useRef(onPress);
  onPressRef.current = onPress;
  const resolvedLabel = label ?? frame.title;
  const iconName = typeof icon === "string" ? icon : null;
  useEffect(() => {
    frame.report(rowId, {
      key: `${frame.pluginId}/${frame.section}/${frame.itemId}/${rowId}`,
      label: resolvedLabel,
      icon: iconName,
      active: Boolean(active),
      onPress: () => onPressRef.current(),
    });
  }, [frame, rowId, resolvedLabel, iconName, active]);
  useEffect(() => () => frame.report(rowId, null), [frame, rowId]);
  return null;
}

export function SidebarSeparator() {
  useSidebarFrame("SidebarSeparator");
  return null;
}
