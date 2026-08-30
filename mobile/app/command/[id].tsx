import { Image } from "expo-image";
import { router, useLocalSearchParams } from "expo-router";
import React, { useEffect, useMemo, useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import type { RemoteArtifact } from "@/remote/types";
import { ActionButton, Card, InlineNotice, ScreenHeader, Tag } from "@/ui/primitives";
import { useTheme } from "@/ui/theme";

export default function CommandResultScreen() {
  const { id, actionID, accepted, errorCode } = useLocalSearchParams<{ id: string; actionID?: string; accepted?: string; errorCode?: string }>();
  const remote = useRemote();
  const theme = useTheme();
  const live = remote.commandResults.find((result) => result.commandID.toLowerCase() === id.toLowerCase());
  const hasFallback = accepted != null;
  const succeeded = live?.accepted ?? accepted === "true";
  const pending = !live && !hasFallback;
  const artifactAction = expectsArtifact(live?.actionID ?? actionID);
  const [artifact, setArtifact] = useState<RemoteArtifact>();
  const [previewError, setPreviewError] = useState<string>();
  const download = artifact ? remote.artifactDownloads[artifact.id] : undefined;
  const macOnline = remote.macOnline;
  const refreshArtifacts = remote.refreshArtifacts;
  const downloadArtifact = remote.downloadArtifact;

  useEffect(() => {
    if (!live?.accepted || !artifactAction || !macOnline) return;
    let cancelled = false;
    let attempts = 0;
    const refresh = async () => {
      try {
        const values = await refreshArtifacts(artifactKind(live.actionID));
        if (cancelled) return;
        const completedAt = new Date(live.completedAt).getTime();
        const match = values.find((value) => new Date(value.modifiedAt).getTime() >= completedAt - 3_000);
        if (match) {
          setArtifact(match);
          if (match.kind === "screenshot" && match.byteCount <= 20 * 1024 * 1024) await downloadArtifact(match);
          if (!cancelled) setPreviewError(undefined);
          return;
        }
      } catch (reason) {
        if (!cancelled) setPreviewError(reason instanceof Error ? reason.message : "The capture could not be loaded.");
      }
      attempts += 1;
      // A maximum-size scrolling capture includes a three-second handoff and
      // multiple capture/stitch passes. Keep following it long enough for the
      // result to arrive instead of presenting a successful command with no
      // visible output.
      if (!cancelled && attempts < 45) setTimeout(() => void refresh(), 1_000);
    };
    void refresh();
    return () => { cancelled = true; };
  }, [artifactAction, downloadArtifact, live?.accepted, live?.actionID, live?.completedAt, macOnline, refreshArtifacts]);

  const title = useMemo(() => friendlyAction(live?.actionID ?? actionID), [actionID, live?.actionID]);
  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.content}>
      <ScreenHeader eyebrow="Remote command" title={pending ? "Working on it" : succeeded ? "Completed" : "Could not complete"} detail={pending ? "The Mac accepted the request. This screen updates as soon as it responds." : title} />
      <Card>
        <View style={styles.resultHeader}><Tag tone={pending ? "neutral" : succeeded ? "accent" : "danger"}>{pending ? "In progress" : succeeded ? "Completed" : "Failed"}</Tag><Text style={[styles.time, { color: theme.secondary }]}>{live?.completedAt ? new Date(live.completedAt).toLocaleTimeString() : "Waiting…"}</Text></View>
        <Text selectable style={[styles.actionTitle, { color: theme.text }]}>{title}</Text>
        <Text selectable style={[styles.commandID, { color: theme.secondary }]}>{id}</Text>
      </Card>

      {pending ? <InlineNotice title="Nothing needs to stay open" message="You can leave this screen. MacScope will retain the result and notify you according to your settings." /> : null}
      {live?.errorMessage || errorCode ? <InlineNotice title="The Mac reported an error" message={live?.errorMessage ?? errorCode ?? "Unknown error"} tone="danger" /> : null}

      {live?.accepted && artifactAction ? (
        <Card>
          <Text style={[styles.sectionTitle, { color: theme.text }]}>Returned capture</Text>
          {artifact && download?.uri && artifact.kind === "screenshot" ? <Image source={download.uri} cachePolicy="none" contentFit="contain" transition={180} style={[styles.preview, { backgroundColor: theme.subtle }]} /> : null}
          {artifact ? <><Text selectable style={[styles.artifactName, { color: theme.text }]}>{artifact.name}</Text><Text style={[styles.time, { color: theme.secondary }]}>{formatBytes(artifact.byteCount)} · available in Library</Text></> : <Text style={[styles.waiting, { color: theme.secondary }]}>Waiting for the Mac to finish writing the file…</Text>}
          {download?.downloading ? <Text style={[styles.waiting, { color: theme.accent }]}>Loading preview… {Math.round(download.progress * 100)}%</Text> : null}
          {previewError ? <InlineNotice title="Preview unavailable" message={previewError} tone="warning" /> : null}
          <ActionButton title="Open Library" onPress={() => router.replace("/(tabs)/library")} />
        </Card>
      ) : null}

      <Text selectable style={[styles.privacy, { color: theme.secondary }]}>Audit records exclude command arguments, clipboard values, and local file paths.</Text>
    </ScrollView>
  );
}

function expectsArtifact(actionID?: string): boolean { return Boolean(actionID && ["capture.screenshot", "capture.scrolling-screenshot", "capture.recording-stop"].some((value) => actionID.endsWith(value))); }
function artifactKind(actionID: string): RemoteArtifact["kind"] | undefined { return actionID.endsWith("recording-stop") ? "recording" : actionID.includes("screenshot") ? "screenshot" : undefined; }
function friendlyAction(value?: string): string { if (!value) return "Remote command"; return value.replace(/^utility\./u, "").split(".").at(-1)!.replaceAll("-", " ").replace(/^./u, (letter) => letter.toUpperCase()); }
function formatBytes(value: number): string { return value >= 1024 ** 2 ? `${(value / 1024 ** 2).toFixed(1)} MB` : `${Math.max(1, Math.round(value / 1024))} KB`; }

const styles = StyleSheet.create({
  content: { padding: 18, gap: 17, paddingBottom: 42 }, resultHeader: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 12 }, time: { fontSize: 11 }, actionTitle: { fontSize: 20, lineHeight: 25, fontWeight: "800", letterSpacing: -0.4 }, commandID: { fontSize: 10, fontFamily: process.env.EXPO_OS === "ios" ? "Menlo" : "monospace" }, sectionTitle: { fontSize: 17, fontWeight: "800" }, preview: { width: "100%", aspectRatio: 16 / 10, borderRadius: 12 }, artifactName: { fontSize: 14, fontWeight: "700" }, waiting: { fontSize: 12, lineHeight: 17 }, privacy: { fontSize: 11, lineHeight: 16, textAlign: "center" },
});
