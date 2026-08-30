import { Link } from "expo-router";
import React, { memo, useCallback, useMemo, useState } from "react";
import { Pressable, SectionList, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRemote } from "@/remote/remote-provider";
import type { UtilityAction } from "@/remote/types";
import { utilityMatchesQuery } from "@/remote/utility-search";
import { EmptyState, InlineNotice, ScreenHeader, SearchField, Tag } from "@/ui/primitives";
import { useTheme } from "@/ui/theme";

const moduleMeta: Record<string, { title: string; glyph: string; detail: string }> = {
  sound: { title: "Sound", glyph: "◖", detail: "Outputs, inputs and app audio" },
  capture: { title: "Capture", glyph: "▣", detail: "Screenshots, recordings and OCR" },
  windows: { title: "Windows & input", glyph: "⌘", detail: "Arrange windows and tune input" },
  clipboard: { title: "Clipboard & shelf", glyph: "▤", detail: "History, snippets and parked items" },
  notes: { title: "Notes", glyph: "✎", detail: "Remote scratchpads" },
  maintenance: { title: "Maintenance & media", glyph: "⌁", detail: "Scans, updates and conversion" },
  power: { title: "Power & displays", glyph: "◐", detail: "Keep Awake, brightness and cleaning" },
};

export default function UtilitiesScreen() {
  const remote = useRemote();
  const theme = useTheme();
  const [query, setQuery] = useState("");
  const sections = useMemo(() => {
    const grouped = remote.utilities.reduce<Record<string, UtilityAction[]>>((result, action) => {
      if (!utilityMatchesQuery(action, query)) return result;
      (result[action.module] ??= []).push(action);
      return result;
    }, {});
    return Object.entries(grouped).map(([module, data]) => ({ module, data }));
  }, [query, remote.utilities]);

  const renderItem = useCallback(({ item }: { item: UtilityAction }) => <UtilityRow action={item} />, []);
  const renderHeader = useCallback(({ section }: { section: { module: string } }) => {
    const meta = moduleMeta[section.module] ?? { title: section.module, glyph: "◇", detail: "" };
    return (
      <View style={styles.sectionHeader}>
        <View style={[styles.moduleMark, { backgroundColor: theme.subtle }]}><Text style={[styles.moduleGlyph, { color: theme.accent }]}>{meta.glyph}</Text></View>
        <View style={styles.sectionCopy}>
          <Text style={[styles.sectionTitle, { color: theme.text }]}>{meta.title}</Text>
          <Text style={[styles.sectionDetail, { color: theme.secondary }]}>{meta.detail}</Text>
        </View>
      </View>
    );
  }, [theme]);

  return (
    <SafeAreaView style={[styles.safe, { backgroundColor: theme.background }]} edges={["top"]}>
      <SectionList
        sections={sections}
        keyExtractor={(item) => item.id}
        renderItem={renderItem}
        renderSectionHeader={renderHeader}
        stickySectionHeadersEnabled={false}
        keyboardShouldPersistTaps="handled"
        contentContainerStyle={styles.content}
        SectionSeparatorComponent={() => <View style={styles.sectionGap} />}
        ItemSeparatorComponent={() => <View style={styles.rowGap} />}
        ListHeaderComponent={(
          <View style={styles.header}>
            <ScreenHeader eyebrow="Remote control" title="Utilities" detail="Choose what you want the Mac to do. MacScope asks for the required details before anything runs." />
            <SearchField value={query} onChangeText={setQuery} placeholder={`Search ${remote.utilities.length || 89} actions`} autoCapitalize="none" autoCorrect={false} />
            {!remote.macOnline ? <InlineNotice title="Mac unavailable" message="Actions stay visible, but nothing is queued while MacScope is offline." tone="warning" /> : null}
          </View>
        )}
        ListEmptyComponent={<EmptyState title={query ? "No matching utility" : "Waiting for your Mac"} message={query ? "Try a broader action or category name." : "The utility catalog appears as soon as MacScope connects."} />}
      />
    </SafeAreaView>
  );
}

const UtilityRow = memo(function UtilityRow({ action }: { action: UtilityAction }) {
  const theme = useTheme();
  const tone = action.risk === "destructive" ? "danger" : action.risk === "sensitive" ? "warning" : action.risk === "read_only" ? "neutral" : "accent";
  return (
    <Link href={{ pathname: "/utility/[id]", params: { id: action.id } }} asChild>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={action.title}
        style={({ pressed }) => [styles.row, { backgroundColor: theme.card, borderColor: theme.border, opacity: pressed ? 0.72 : 1, transform: [{ scale: pressed ? 0.992 : 1 }] }]}
      >
        <View style={styles.rowCopy}>
          <Text style={[styles.rowTitle, { color: theme.text }]}>{action.title}</Text>
          <Text numberOfLines={2} style={[styles.rowDetail, { color: theme.secondary }]}>{action.summary}</Text>
          <View style={styles.tags}>
            <Tag tone={tone}>{action.risk.replace("_", " ")}</Tag>
            {action.producesArtifact ? <Tag tone="accent">Returns media</Tag> : null}
            {!action.allowed ? <Tag tone="warning">Blocked on Mac</Tag> : null}
          </View>
        </View>
        <Text style={[styles.chevron, { color: theme.secondary }]}>›</Text>
      </Pressable>
    </Link>
  );
});

const styles = StyleSheet.create({
  safe: { flex: 1 },
  content: { paddingHorizontal: 18, paddingBottom: 42 },
  header: { gap: 17, paddingTop: 12, paddingBottom: 28 },
  sectionHeader: { flexDirection: "row", alignItems: "center", gap: 11, paddingBottom: 10 },
  moduleMark: { width: 38, height: 38, borderRadius: 12, alignItems: "center", justifyContent: "center" },
  moduleGlyph: { fontSize: 19, fontWeight: "800" },
  sectionCopy: { flex: 1, gap: 2 },
  sectionTitle: { fontSize: 17, fontWeight: "800", letterSpacing: -0.35 },
  sectionDetail: { fontSize: 11.5 },
  row: { minHeight: 98, borderRadius: 16, borderCurve: "continuous", borderWidth: StyleSheet.hairlineWidth, padding: 15, flexDirection: "row", alignItems: "center", gap: 10 },
  rowCopy: { flex: 1, gap: 6 },
  rowTitle: { fontSize: 16, fontWeight: "700", letterSpacing: -0.25 },
  rowDetail: { fontSize: 12.5, lineHeight: 17 },
  tags: { flexDirection: "row", flexWrap: "wrap", gap: 6, paddingTop: 2 },
  chevron: { fontSize: 28, fontWeight: "300" },
  rowGap: { height: 8 },
  sectionGap: { height: 26 },
});
