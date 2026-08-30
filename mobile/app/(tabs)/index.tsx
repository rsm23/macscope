import { useRouter } from "expo-router";
import React from "react";
import { Pressable, ScrollView, Text, View, useWindowDimensions, type DimensionValue } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import { ActionButton, Card, EmptyState, InlineNotice, MetricBar, SectionLabel, StatusPill } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function OverviewScreen() {
  const remote = useRemote();
  const router = useRouter();
  const theme = useTheme();
  const { width } = useWindowDimensions();
  const columns = width >= 700 ? 3 : 2;
  const metric = remote.metric;
  const latestResult = remote.commandResults[0];
  const undo = undoDetails(latestResult?.result);

  const prepareUndo = async () => {
    if (!undo) return;
    const command = await remote.prepareCommand("macos.undo", {
      undo_token: undo.token,
      undo_confirmation: undo.confirmation,
    });
    router.push({ pathname: "/confirm", params: { command: JSON.stringify(command) } });
  };

  if (!remote.activeEnvironment) {
    return (
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18, gap: 22, flexGrow: 1, justifyContent: "center" }}>
        <EmptyState title="Pair your Mac" message="Open MacScope → Settings → Remote, then scan the one-time owner QR code." />
        <ActionButton title="Scan pairing QR" onPress={() => router.push("/pair")} />
      </ScrollView>
    );
  }

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18, paddingTop: 20, gap: 22, paddingBottom: 48 }}>
      <Card style={{ backgroundColor: theme.dark ? "#0D2732" : "#E5FAFA" }}>
        <View style={{ flexDirection: "row", alignItems: "flex-start", justifyContent: "space-between", gap: 12 }}>
          <View style={{ flex: 1, gap: 5 }}>
            <Text selectable style={{ color: theme.text, fontSize: 24, fontWeight: "900", letterSpacing: -0.6 }}>
              {remote.presence?.macName ?? remote.activeEnvironment.displayName}
            </Text>
            <Text selectable style={{ color: theme.secondary, fontSize: 13 }}>
              {remote.activeEnvironment.role.toUpperCase()} · {remote.presence?.appVersion ?? "Waiting for MacScope"}
            </Text>
          </View>
          <StatusPill online={remote.macOnline} label={remote.macOnline ? "Mac online" : remote.connection === "online" ? "Mac offline" : remote.connection} />
        </View>
        {remote.error ? <Text selectable style={{ color: palette.red, fontSize: 13 }}>{remote.error}</Text> : null}
      </Card>

      {remote.pairingRepairRequired ? (
        <View style={{ gap: 10 }}>
          <InlineNotice title="Pair this Mac again" message="This phone's session was revoked or expired. Create a fresh one-time QR in MacScope; your Mac settings and files are unaffected." tone="warning" />
          <ActionButton title="Scan a new pairing QR" onPress={() => router.push("/pair")} />
        </View>
      ) : null}

      {remote.environments.length > 1 ? (
        <View style={{ gap: 9 }}>
          <SectionLabel>Macs</SectionLabel>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 9 }}>
            {remote.environments.map((environment) => {
              const selected = environment.environmentID === remote.activeEnvironment?.environmentID;
              return (
                <Pressable key={environment.environmentID} onPress={() => void remote.selectEnvironment(environment.environmentID)} style={{ backgroundColor: selected ? palette.cyan : theme.card, borderColor: theme.border, borderWidth: 1, borderRadius: 14, paddingHorizontal: 14, paddingVertical: 10 }}>
                  <Text style={{ color: selected ? palette.ink : theme.text, fontWeight: "800" }}>{environment.displayName}</Text>
                </Pressable>
              );
            })}
          </ScrollView>
        </View>
      ) : null}

      {!metric ? (
        <EmptyState title={remote.macOnline ? "Waiting for telemetry" : "Mac unavailable"} message={remote.macOnline ? "The first compact snapshot normally arrives within two seconds." : remote.connection === "online" ? "The phone reached the relay, but MacScope is not connected. Open MacScope on the paired Mac to resume." : "Commands are disabled while offline and are never queued."} />
      ) : (
        <>
          <SectionLabel>Live system</SectionLabel>
          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 12 }}>
            <MetricCard width={`${100 / columns - 2}%`} label="CPU" value={`${metric.cpuPercent.toFixed(0)}%`} percent={metric.cpuPercent} color={palette.cyan} />
            <MetricCard width={`${100 / columns - 2}%`} label="Memory" value={`${metric.memoryPercent.toFixed(0)}%`} detail={`${formatBytes(metric.memoryUsedBytes)} used`} percent={metric.memoryPercent} color={palette.blue} />
            <MetricCard width={`${100 / columns - 2}%`} label="GPU" value={metric.gpuPercent == null ? "—" : `${metric.gpuPercent.toFixed(0)}%`} percent={metric.gpuPercent ?? 0} color={palette.mint} />
            <MetricCard width={`${100 / columns - 2}%`} label="Thermals" value={metric.hottestSensorCelsius == null ? metric.thermalPressure ?? "—" : `${metric.hottestSensorCelsius.toFixed(0)}°C`} color={palette.amber} />
            <MetricCard width={`${100 / columns - 2}%`} label="Power" value={metric.systemPowerWatts == null ? "—" : `${metric.systemPowerWatts.toFixed(1)} W`} detail={metric.batteryPercent == null ? undefined : `${metric.batteryPercent.toFixed(0)}% battery`} color={palette.amber} />
            <MetricCard width={`${100 / columns - 2}%`} label="Network" value={`↓ ${formatRate(metric.networkDownloadBytesPerSecond)}`} detail={`↑ ${formatRate(metric.networkUploadBytesPerSecond)}`} color={palette.cyan} />
          </View>

          <SectionLabel>Last minute CPU</SectionLabel>
          <Card>
            <View style={{ height: 86, flexDirection: "row", alignItems: "flex-end", gap: 2 }}>
              {remote.metricHistory.map((frame, index) => (
                <View key={`${frame.timestamp}-${index}`} style={{ flex: 1, minWidth: 2, height: `${Math.max(frame.cpuPercent, 2)}%`, backgroundColor: palette.cyan, borderRadius: 2, opacity: 0.35 + index / Math.max(remote.metricHistory.length, 1) * 0.65 }} />
              ))}
            </View>
            <Text selectable style={{ color: theme.secondary, fontSize: 12 }}>{metric.measuredMetricCount} measured · {metric.degradedMetricCount} unavailable or degraded</Text>
          </Card>
        </>
      )}

      {latestResult ? (
        <>
          <SectionLabel>Latest command</SectionLabel>
          <Card>
            <Text selectable style={{ color: latestResult.accepted ? palette.mint : palette.red, fontSize: 12, fontWeight: "900" }}>
              {latestResult.accepted ? "COMPLETED" : "FAILED"}
            </Text>
            <Text selectable style={{ color: theme.text, fontSize: 15, fontWeight: "800" }}>{latestResult.actionID}</Text>
            {latestResult.errorMessage ? <Text selectable style={{ color: palette.red, fontSize: 12 }}>{latestResult.errorMessage}</Text> : null}
            {undo ? <ActionButton title="Review undo" disabled={!remote.macOnline} onPress={() => void prepareUndo()} /> : null}
          </Card>
        </>
      ) : null}
    </ScrollView>
  );
}

function undoDetails(value: unknown): { token: string; confirmation: string } | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const result = value as Record<string, unknown>;
  return typeof result.undoToken === "string" && typeof result.undoConfirmation === "string"
    ? { token: result.undoToken, confirmation: result.undoConfirmation }
    : undefined;
}

function MetricCard({ width, label, value, detail, percent, color }: { width: DimensionValue; label: string; value: string; detail?: string; percent?: number; color: string }) {
  const theme = useTheme();
  return (
    <Card style={{ width, minWidth: 145 }}>
      <Text selectable style={{ color: theme.secondary, fontSize: 12, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.8 }}>{label}</Text>
      <Text selectable style={{ color: theme.text, fontSize: 25, fontWeight: "900", fontVariant: ["tabular-nums"] }}>{value}</Text>
      {percent != null ? <MetricBar value={percent} color={color} /> : <View style={{ height: 7 }} />}
      {detail ? <Text selectable style={{ color: theme.secondary, fontSize: 12 }}>{detail}</Text> : null}
    </Card>
  );
}

function formatBytes(value: number): string {
  if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(1)} GB`;
  if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(0)} MB`;
  return `${Math.round(value / 1024)} KB`;
}

function formatRate(value: number): string {
  return `${formatBytes(value)}/s`;
}
