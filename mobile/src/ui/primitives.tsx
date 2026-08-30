import React from "react";
import { Pressable, Text, View, type ViewStyle } from "react-native";
import { palette, useTheme } from "./theme";

export function Card({ children, style }: { children: React.ReactNode; style?: ViewStyle }) {
  const theme = useTheme();
  return (
    <View
      style={{
        backgroundColor: theme.card,
        borderColor: theme.border,
        borderWidth: 1,
        borderRadius: 20,
        borderCurve: "continuous",
        padding: 18,
        gap: 12,
        boxShadow: "0 10px 28px rgba(2, 12, 18, 0.12)",
        ...style,
      }}
    >
      {children}
    </View>
  );
}

export function SectionLabel({ children }: { children: React.ReactNode }) {
  const theme = useTheme();
  return (
    <Text selectable style={{ color: theme.secondary, fontSize: 12, fontWeight: "700", letterSpacing: 1.1, textTransform: "uppercase" }}>
      {children}
    </Text>
  );
}

export function StatusPill({ online, label }: { online: boolean; label: string }) {
  return (
    <View style={{ flexDirection: "row", alignItems: "center", alignSelf: "flex-start", gap: 7, backgroundColor: online ? "rgba(141,240,199,0.12)" : "rgba(255,125,125,0.12)", borderRadius: 99, paddingHorizontal: 11, paddingVertical: 7 }}>
      <View style={{ width: 7, height: 7, borderRadius: 99, backgroundColor: online ? palette.mint : palette.red }} />
      <Text selectable style={{ color: online ? palette.mint : palette.red, fontSize: 12, fontWeight: "700" }}>{label}</Text>
    </View>
  );
}

export function ActionButton({ title, onPress, disabled, destructive = false }: { title: string; onPress: () => void; disabled?: boolean; destructive?: boolean }) {
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => ({
        minHeight: 46,
        alignItems: "center",
        justifyContent: "center",
        borderRadius: 15,
        borderCurve: "continuous",
        paddingHorizontal: 16,
        backgroundColor: destructive ? "rgba(255,125,125,0.14)" : disabled ? "rgba(156,177,187,0.08)" : pressed ? "#46C5CC" : palette.cyan,
        opacity: disabled ? 0.55 : 1,
      })}
    >
      <Text style={{ color: destructive ? palette.red : palette.ink, fontSize: 15, fontWeight: "800" }}>{title}</Text>
    </Pressable>
  );
}

export function MetricBar({ value, color = palette.cyan }: { value: number; color?: string }) {
  const bounded = Math.max(0, Math.min(value, 100));
  return (
    <View style={{ height: 7, backgroundColor: "rgba(156,177,187,0.14)", borderRadius: 99, overflow: "hidden" }}>
      <View style={{ width: `${bounded}%`, height: "100%", backgroundColor: color, borderRadius: 99 }} />
    </View>
  );
}

export function EmptyState({ title, message }: { title: string; message: string }) {
  const theme = useTheme();
  return (
    <Card style={{ alignItems: "center", paddingVertical: 34 }}>
      <Text selectable style={{ color: theme.text, fontSize: 18, fontWeight: "800" }}>{title}</Text>
      <Text selectable style={{ color: theme.secondary, fontSize: 14, textAlign: "center", lineHeight: 20 }}>{message}</Text>
    </Card>
  );
}
