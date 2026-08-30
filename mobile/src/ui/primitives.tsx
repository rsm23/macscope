import React from "react";
import { Pressable, StyleSheet, Text, TextInput, View, type TextInputProps, type ViewStyle } from "react-native";
import { palette, useTheme } from "./theme";

export function Card({ children, style }: { children: React.ReactNode; style?: ViewStyle }) {
  const theme = useTheme();
  return <View style={[styles.card, { backgroundColor: theme.card, borderColor: theme.border, shadowColor: theme.shadow }, style]}>{children}</View>;
}

export function SectionLabel({ children, detail }: { children: React.ReactNode; detail?: string }) {
  const theme = useTheme();
  return (
    <View style={styles.sectionHeading}>
      <Text selectable style={[styles.sectionLabel, { color: theme.text }]}>{children}</Text>
      {detail ? <Text selectable style={[styles.sectionDetail, { color: theme.secondary }]}>{detail}</Text> : null}
    </View>
  );
}

export function ScreenHeader({ eyebrow, title, detail, trailing }: { eyebrow?: string; title: string; detail?: string; trailing?: React.ReactNode }) {
  const theme = useTheme();
  return (
    <View style={styles.screenHeader}>
      <View style={styles.headerCopy}>
        {eyebrow ? <Text style={[styles.eyebrow, { color: theme.accent }]}>{eyebrow}</Text> : null}
        <Text selectable style={[styles.screenTitle, { color: theme.text }]}>{title}</Text>
        {detail ? <Text selectable style={[styles.screenDetail, { color: theme.secondary }]}>{detail}</Text> : null}
      </View>
      {trailing}
    </View>
  );
}

export function StatusPill({ online, label }: { online: boolean; label: string }) {
  const theme = useTheme();
  const color = online ? palette.mint : palette.red;
  return (
    <View style={[styles.status, { backgroundColor: theme.subtle }]}>
      <View style={[styles.statusDot, { backgroundColor: color }]} />
      <Text style={[styles.statusText, { color }]}>{label}</Text>
    </View>
  );
}

export function ActionButton({ title, onPress, disabled, destructive = false, secondary = false }: { title: string; onPress: () => void; disabled?: boolean; destructive?: boolean; secondary?: boolean }) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={title}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.action,
        {
          backgroundColor: destructive ? "rgba(217,102,102,0.12)" : secondary ? theme.subtle : theme.accent,
          borderColor: destructive ? "rgba(217,102,102,0.24)" : secondary ? theme.border : theme.accent,
          opacity: disabled ? 0.42 : pressed ? 0.78 : 1,
          transform: [{ scale: pressed ? 0.985 : 1 }],
        },
      ]}
    >
      <Text style={[styles.actionText, { color: destructive ? palette.red : secondary ? theme.text : theme.onAccent }]}>{title}</Text>
    </Pressable>
  );
}

export function SearchField(props: TextInputProps) {
  const theme = useTheme();
  return (
    <View style={[styles.searchShell, { backgroundColor: theme.subtle, borderColor: theme.border }]}>
      <Text style={[styles.searchGlyph, { color: theme.secondary }]}>⌕</Text>
      <TextInput placeholderTextColor={theme.secondary} {...props} style={[styles.searchInput, { color: theme.text }, props.style]} />
    </View>
  );
}

export function Tag({ children, tone = "neutral" }: { children: React.ReactNode; tone?: "neutral" | "accent" | "warning" | "danger" }) {
  const theme = useTheme();
  const color = tone === "accent" ? theme.accent : tone === "warning" ? palette.amber : tone === "danger" ? palette.red : theme.secondary;
  return <View style={[styles.tag, { backgroundColor: `${color}16` }]}><Text style={[styles.tagText, { color }]}>{children}</Text></View>;
}

export function InlineNotice({ title, message, tone = "neutral" }: { title: string; message: string; tone?: "neutral" | "warning" | "danger" }) {
  const theme = useTheme();
  const color = tone === "danger" ? palette.red : tone === "warning" ? palette.amber : theme.accent;
  return (
    <View style={[styles.notice, { backgroundColor: `${color}10`, borderColor: `${color}28` }]}>
      <View style={[styles.noticeBar, { backgroundColor: color }]} />
      <View style={styles.noticeCopy}>
        <Text selectable style={[styles.noticeTitle, { color: theme.text }]}>{title}</Text>
        <Text selectable style={[styles.noticeMessage, { color: theme.secondary }]}>{message}</Text>
      </View>
    </View>
  );
}

export function MetricBar({ value, color = palette.accent }: { value: number; color?: string }) {
  const theme = useTheme();
  const bounded = Math.max(0, Math.min(value, 100));
  return <View style={[styles.bar, { backgroundColor: theme.subtle }]}><View style={[styles.barFill, { width: `${bounded}%`, backgroundColor: color }]} /></View>;
}

export function EmptyState({ title, message }: { title: string; message: string }) {
  const theme = useTheme();
  return (
    <View style={styles.empty}>
      <View style={[styles.emptyMark, { backgroundColor: theme.subtle }]}><Text style={[styles.emptyGlyph, { color: theme.accent }]}>◌</Text></View>
      <Text selectable style={[styles.emptyTitle, { color: theme.text }]}>{title}</Text>
      <Text selectable style={[styles.emptyMessage, { color: theme.secondary }]}>{message}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 17, borderCurve: "continuous", padding: 16, gap: 11, shadowOpacity: 0.07, shadowRadius: 20, shadowOffset: { width: 0, height: 8 } },
  sectionHeading: { gap: 3 }, sectionLabel: { fontSize: 17, fontWeight: "700", letterSpacing: -0.2 }, sectionDetail: { fontSize: 12, lineHeight: 17 },
  screenHeader: { flexDirection: "row", alignItems: "flex-start", gap: 14 }, headerCopy: { flex: 1, gap: 5 }, eyebrow: { fontSize: 11, fontWeight: "800", letterSpacing: 1.2, textTransform: "uppercase" }, screenTitle: { fontSize: 31, lineHeight: 34, fontWeight: "900", letterSpacing: -1.1 }, screenDetail: { fontSize: 14, lineHeight: 20, maxWidth: 430 },
  status: { flexDirection: "row", alignItems: "center", gap: 7, borderRadius: 10, paddingHorizontal: 10, paddingVertical: 7 }, statusDot: { width: 7, height: 7, borderRadius: 4 }, statusText: { fontSize: 11, fontWeight: "700", textTransform: "capitalize" },
  action: { minHeight: 50, alignItems: "center", justifyContent: "center", borderRadius: 14, borderCurve: "continuous", borderWidth: 1, paddingHorizontal: 18 }, actionText: { fontSize: 15, fontWeight: "800", letterSpacing: -0.1 },
  searchShell: { minHeight: 48, borderRadius: 14, borderCurve: "continuous", borderWidth: StyleSheet.hairlineWidth, flexDirection: "row", alignItems: "center", paddingHorizontal: 14, gap: 9 }, searchGlyph: { fontSize: 22, marginTop: -2 }, searchInput: { flex: 1, minHeight: 46, fontSize: 15, paddingVertical: 0 },
  tag: { alignSelf: "flex-start", borderRadius: 7, paddingHorizontal: 8, paddingVertical: 5 }, tagText: { fontSize: 10, lineHeight: 12, fontWeight: "800", letterSpacing: 0.45, textTransform: "uppercase" },
  notice: { minHeight: 72, flexDirection: "row", borderRadius: 15, borderCurve: "continuous", borderWidth: StyleSheet.hairlineWidth, overflow: "hidden" }, noticeBar: { width: 3 }, noticeCopy: { flex: 1, padding: 14, gap: 4 }, noticeTitle: { fontSize: 14, fontWeight: "700" }, noticeMessage: { fontSize: 12, lineHeight: 17 },
  bar: { height: 5, borderRadius: 3, overflow: "hidden" }, barFill: { height: "100%", borderRadius: 3 },
  empty: { alignItems: "center", paddingVertical: 46, paddingHorizontal: 28, gap: 9 }, emptyMark: { width: 52, height: 52, borderRadius: 18, alignItems: "center", justifyContent: "center", marginBottom: 4 }, emptyGlyph: { fontSize: 28 }, emptyTitle: { fontSize: 19, fontWeight: "800", letterSpacing: -0.35 }, emptyMessage: { fontSize: 14, lineHeight: 20, textAlign: "center", maxWidth: 320 },
});
