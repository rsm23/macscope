import { router } from "expo-router";
import React, { useMemo, useState } from "react";
import { ScrollView, Switch, Text, View } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import type { RemoteFeature } from "@/remote/types";
import { roleCanWrite } from "@/remote/security";
import { Card, EmptyState, SectionLabel } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function FeaturesScreen() {
  const remote = useRemote();
  const theme = useTheme();
  const [busyID, setBusyID] = useState<string>();
  const [error, setError] = useState<string>();
  const canWrite = roleCanWrite(remote.activeEnvironment?.role);
  const grouped = useMemo(() => ({
    modules: remote.features.filter((feature) => feature.kind === "feature_hub"),
    macOS: remote.features.filter((feature) => feature.kind === "macos"),
  }), [remote.features]);

  const toggle = async (feature: RemoteFeature, enabled: boolean) => {
    setBusyID(feature.id);
    setError(undefined);
    try {
      const actionID = feature.kind === "feature_hub" ? `featurehub.${feature.id}` : `macos.${feature.id}`;
      const command = await remote.prepareCommand(actionID, { enabled });
      router.push({ pathname: "/confirm", params: { command: JSON.stringify(command) } });
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The feature change could not be prepared.");
    } finally {
      setBusyID(undefined);
    }
  };

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18, gap: 18, paddingBottom: 36 }}>
      {error ? <Card style={{ borderColor: "rgba(255,125,125,0.35)" }}><Text selectable style={{ color: palette.red }}>{error}</Text></Card> : null}
      {remote.features.length === 0 ? (
        <EmptyState title="No feature state yet" message={remote.macOnline ? "MacScope is refreshing its supported feature catalog." : "Open MacScope on the paired Mac to inspect and manage features."} />
      ) : (
        <>
          <SectionLabel>MacScope modules</SectionLabel>
          <Card style={{ padding: 0, gap: 0, overflow: "hidden" }}>
            {grouped.modules.map((feature, index) => (
              <FeatureRow key={feature.id} feature={feature} busy={busyID === feature.id} roleAllowsWrite={canWrite} onToggle={(enabled) => void toggle(feature, enabled)} divider={index < grouped.modules.length - 1} />
            ))}
          </Card>

          <SectionLabel>macOS preferences</SectionLabel>
          <Card style={{ padding: 0, gap: 0, overflow: "hidden" }}>
            {grouped.macOS.map((feature, index) => (
              <FeatureRow key={feature.id} feature={feature} busy={busyID === feature.id} roleAllowsWrite={canWrite} onToggle={(enabled) => void toggle(feature, enabled)} divider={index < grouped.macOS.length - 1} />
            ))}
          </Card>
          <Text selectable style={{ color: theme.secondary, fontSize: 12, lineHeight: 18 }}>
            Preference changes are prepared on the Mac, checked against the current state, and expire before apply. Experimental and protected entries remain unavailable remotely.
          </Text>
        </>
      )}
    </ScrollView>
  );
}

function FeatureRow({ feature, busy, roleAllowsWrite, onToggle, divider }: { feature: RemoteFeature; busy: boolean; roleAllowsWrite: boolean; onToggle: (enabled: boolean) => void; divider: boolean }) {
  const theme = useTheme();
  const unavailable = feature.enabled == null || feature.availability === "restricted" || feature.availability === "unsupported";
  return (
    <View style={{ padding: 16, gap: 8, borderBottomColor: divider ? theme.border : "transparent", borderBottomWidth: divider ? 1 : 0 }}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 14 }}>
        <View style={{ flex: 1, gap: 4 }}>
          <View style={{ flexDirection: "row", gap: 7, alignItems: "center" }}>
            <Text selectable style={{ color: theme.text, fontSize: 16, fontWeight: "800" }}>{feature.title}</Text>
            {feature.experimental ? <Text style={{ color: palette.amber, fontSize: 10, fontWeight: "800" }}>EXPERIMENTAL</Text> : null}
          </View>
          <Text selectable style={{ color: theme.secondary, fontSize: 13, lineHeight: 18 }}>{feature.summary}</Text>
        </View>
        <Switch value={feature.enabled ?? false} disabled={busy || unavailable || !feature.writable || !roleAllowsWrite} onValueChange={onToggle} trackColor={{ true: palette.cyan }} />
      </View>
      {!feature.writable || unavailable ? (
        <Text selectable style={{ color: feature.availability === "available" ? theme.secondary : palette.amber, fontSize: 11 }}>
          {unavailable ? feature.availability : !roleAllowsWrite ? "Viewer access is read-only" : "Remote writes are disabled on this Mac"}
        </Text>
      ) : !roleAllowsWrite ? <Text selectable style={{ color: theme.secondary, fontSize: 11 }}>Viewer access is read-only</Text> : null}
    </View>
  );
}
