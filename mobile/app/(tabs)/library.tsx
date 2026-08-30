import * as Clipboard from "expo-clipboard";
import * as Sharing from "expo-sharing";
import { useFocusEffect } from "expo-router";
import { useVideoPlayer, VideoView } from "expo-video";
import React, { useCallback, useEffect, useState } from "react";
import { Pressable, RefreshControl, ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRemote } from "@/remote/remote-provider";
import type { RemoteArtifact } from "@/remote/types";
import { CapturePreview } from "@/ui/capture-preview";
import { ActionButton, Card, EmptyState, InlineNotice, ScreenHeader, SectionLabel, Tag } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function LibraryScreen() {
  const remote = useRemote();
  const theme = useTheme();
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string>();
  const clipboard = object(remote.utilityStates.clipboard);
  const history = array(clipboard?.history);
  const macOnline = remote.macOnline;
  const refreshArtifacts = remote.refreshArtifacts;
  const refreshUtilityState = remote.refreshUtilityState;

  const refresh = useCallback(async () => {
    if (!macOnline) return;
    setRefreshing(true);
    setError(undefined);
    try {
      await refreshUtilityState("clipboard");
      await refreshArtifacts();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The Library could not be refreshed.");
    } finally {
      setRefreshing(false);
    }
  }, [macOnline, refreshArtifacts, refreshUtilityState]);

  useFocusEffect(useCallback(() => { void refresh(); }, [refresh]));

  return (
    <SafeAreaView style={[styles.safe, { backgroundColor: theme.background }]} edges={["top"]}>
      <ScrollView refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => void refresh()} tintColor={theme.accent} />} contentContainerStyle={styles.content}>
        <ScreenHeader eyebrow="From your Mac" title="Library" detail="Captures and clipboard content arrive here without exposing local Mac paths." />
        {!remote.macOnline ? <InlineNotice title="Mac unavailable" message="Downloaded captures remain usable, but new files and clipboard changes appear after MacScope reconnects." tone="warning" /> : null}
        {error ? <InlineNotice title="Library refresh failed" message={error} tone="danger" /> : null}

        <SectionLabel detail="Screenshots and recordings created by MacScope.">Captures</SectionLabel>
        {remote.artifacts.length ? remote.artifacts.map((artifact, index) => <ArtifactCard key={artifact.id} artifact={artifact} eager={index < 6 && artifact.kind !== "recording"} />) : <EmptyState title="No captures yet" message="Run Screenshot or stop a screen recording. The result will appear here automatically." />}

        <SectionLabel detail={`${number(clipboard?.history_count)} recent · ${number(clipboard?.pinned_count)} pinned`}>Clipboard on Mac</SectionLabel>
        {history.length ? history.slice(0, 30).map((item, index) => <ClipboardCard key={string(item.id) || String(index)} item={item} />) : <EmptyState title="No clipboard history" message="Enable clipboard history on the Mac, then copy text to make it available here." />}
      </ScrollView>
    </SafeAreaView>
  );
}

function ArtifactCard({ artifact, eager }: { artifact: RemoteArtifact; eager: boolean }) {
  const remote = useRemote();
  const theme = useTheme();
  const download = remote.artifactDownloads[artifact.id];
  const [error, setError] = useState<string>();
  const downloadArtifact = remote.downloadArtifact;
  const load = async () => {
    setError(undefined);
    try { await downloadArtifact(artifact, Boolean(download?.uri)); }
    catch (reason) { setError(reason instanceof Error ? reason.message : "The capture could not be loaded."); }
  };
  useEffect(() => {
    if (!eager || download?.uri || download?.downloading || artifact.byteCount > 20 * 1024 * 1024) return;
    const timer = setTimeout(() => void load(), 0);
    return () => clearTimeout(timer);
  // `load` intentionally follows the immutable artifact; download state stops repeat requests.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [artifact, download?.downloading, download?.uri, eager]);
  const share = async () => {
    const uri = download?.uri ?? await downloadArtifact(artifact);
    if (await Sharing.isAvailableAsync()) await Sharing.shareAsync(uri, { mimeType: artifact.mimeType });
  };
  return (
    <Card>
      {download?.uri && artifact.kind !== "recording" ? <CapturePreview uri={download.uri} onError={setError} /> : null}
      {download?.uri && artifact.kind === "recording" ? <VideoPreview uri={download.uri} /> : null}
      <View style={styles.artifactHeader}><View style={styles.artifactCopy}><Text selectable numberOfLines={2} style={[styles.artifactTitle, { color: theme.text }]}>{artifact.name}</Text><Text style={[styles.meta, { color: theme.secondary }]}>{formatBytes(artifact.byteCount)} · {new Date(artifact.modifiedAt).toLocaleString()}</Text></View><Tag tone="accent">{artifact.kind}</Tag></View>
      {download?.downloading ? <Text style={[styles.meta, { color: theme.accent }]}>Loading… {Math.round(download.progress * 100)}%</Text> : null}
      {error || download?.error ? <InlineNotice title="Could not load capture" message={error ?? download?.error ?? "Unknown error"} tone="danger" /> : null}
      <View style={styles.actions}><View style={styles.flex}><ActionButton title={download?.uri ? "Reload" : artifact.kind === "recording" ? "Load video" : "Load preview"} secondary disabled={download?.downloading} onPress={() => void load()} /></View><View style={styles.flex}><ActionButton title="Share or save" disabled={download?.downloading} onPress={() => void share()} /></View></View>
    </Card>
  );
}

function VideoPreview({ uri }: { uri: string }) {
  const player = useVideoPlayer(uri, (instance) => { instance.loop = false; });
  return <VideoView player={player} nativeControls contentFit="contain" style={styles.video} />;
}

function ClipboardCard({ item }: { item: Record<string, unknown> }) {
  const theme = useTheme();
  const text = string(item.text);
  const files = Array.isArray(item.files) ? item.files.filter((value): value is string => typeof value === "string") : [];
  const hasImage = item.has_image === true;
  const content = text || files.join("\n");
  return (
    <Pressable disabled={!content} onPress={() => content ? void Clipboard.setStringAsync(content) : undefined} style={({ pressed }) => [styles.clipboard, { backgroundColor: theme.card, borderColor: theme.border, opacity: pressed ? 0.72 : 1 }]}>
      <View style={styles.clipboardTop}><Tag>{string(item.kind) || "item"}</Tag><Text style={[styles.meta, { color: theme.secondary }]}>{dateLabel(string(item.captured_at))}</Text></View>
      <Text selectable numberOfLines={8} style={[styles.clipboardText, { color: content ? theme.text : theme.secondary }]}>{content || (hasImage ? "Image copied on the Mac" : "Clipboard item")}</Text>
      {content ? <Text style={[styles.copyHint, { color: theme.accent }]}>Tap to copy on this phone</Text> : null}
    </Pressable>
  );
}

function object(value: unknown): Record<string, unknown> | undefined { return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined; }
function array(value: unknown): Record<string, unknown>[] { return Array.isArray(value) ? value.map(object).filter((item): item is Record<string, unknown> => Boolean(item)) : []; }
function string(value: unknown): string { return typeof value === "string" ? value : ""; }
function number(value: unknown): number { return typeof value === "number" ? value : 0; }
function dateLabel(value: string): string { const date = new Date(value); return Number.isFinite(date.getTime()) ? date.toLocaleString() : ""; }
function formatBytes(value: number): string { return value >= 1024 ** 2 ? `${(value / 1024 ** 2).toFixed(1)} MB` : value >= 1024 ? `${Math.round(value / 1024)} KB` : `${value} B`; }

const styles = StyleSheet.create({
  safe: { flex: 1 }, content: { paddingHorizontal: 18, paddingTop: 14, paddingBottom: 48, gap: 22 }, video: { width: "100%", aspectRatio: 16 / 9, borderRadius: 12, backgroundColor: palette.ink }, artifactHeader: { flexDirection: "row", alignItems: "flex-start", gap: 12 }, artifactCopy: { flex: 1, gap: 5 }, artifactTitle: { fontSize: 15, lineHeight: 21, fontWeight: "700" }, meta: { fontSize: 11, lineHeight: 16 }, actions: { flexDirection: "row", gap: 10 }, flex: { flex: 1 }, clipboard: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 16, borderCurve: "continuous", padding: 16, gap: 13 }, clipboardTop: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 12 }, clipboardText: { fontSize: 14, lineHeight: 21 }, copyHint: { fontSize: 11, fontWeight: "700" },
});
