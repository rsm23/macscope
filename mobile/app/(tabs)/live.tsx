import { router, useFocusEffect } from "expo-router";
import React, { useCallback, useEffect, useMemo, useState } from "react";
import { Pressable, RefreshControl, ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRemote } from "@/remote/remote-provider";
import type { ProcessSnapshot, SnapshotSection } from "@/remote/types";
import { ActionButton, Card, EmptyState, InlineNotice, MetricBar, ScreenHeader, SearchField, SectionLabel, Tag } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

type Mode = "metrics" | "processes";
const detailSections: SnapshotSection[][] = [
  ["summary", "cpu", "memory", "battery"],
  ["network"], ["storage"], ["startup"], ["hardware", "thermals", "accelerators", "metrics"],
];

export default function LiveScreen() {
  const remote = useRemote();
  const theme = useTheme();
  const [mode, setMode] = useState<Mode>("metrics");
  const [query, setQuery] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string>();
  const macOnline = remote.macOnline;
  const refreshLiveData = remote.refreshLiveData;

  const refreshMetrics = useCallback(async () => {
    if (!macOnline) return;
    setRefreshing(true); setError(undefined);
    try { await Promise.all(detailSections.map((sections) => refreshLiveData(sections))); }
    catch (reason) { setError(reason instanceof Error ? reason.message : "Live data could not be refreshed."); }
    finally { setRefreshing(false); }
  }, [macOnline, refreshLiveData]);

  const refreshProcesses = useCallback(async () => {
    if (!macOnline) return;
    setRefreshing(true); setError(undefined);
    try { await refreshLiveData(["processes"], { processLimit: 150, processQuery: query.trim() || undefined }); }
    catch (reason) { setError(reason instanceof Error ? reason.message : "Processes could not be refreshed."); }
    finally { setRefreshing(false); }
  }, [macOnline, query, refreshLiveData]);

  useFocusEffect(useCallback(() => { void (mode === "metrics" ? refreshMetrics() : refreshProcesses()); }, [mode, refreshMetrics, refreshProcesses]));
  useEffect(() => {
    if (mode !== "processes" || !macOnline) return;
    const timer = setInterval(() => { void refreshProcesses(); }, 4_000);
    return () => clearInterval(timer);
  }, [macOnline, mode, refreshProcesses]);

  return (
    <SafeAreaView style={[styles.safe, { backgroundColor: theme.background }]} edges={["top"]}>
      <ScrollView refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => void (mode === "metrics" ? refreshMetrics() : refreshProcesses())} tintColor={theme.accent} />} contentContainerStyle={styles.content}>
        <ScreenHeader eyebrow="Live from MacScope" title="System" detail="Detailed telemetry and running processes from the connected Mac." />
        <View accessibilityRole="tablist" style={[styles.segment, { backgroundColor: theme.subtle }]}><Segment label="Metrics" selected={mode === "metrics"} onPress={() => setMode("metrics")} /><Segment label="Processes" selected={mode === "processes"} onPress={() => setMode("processes")} /></View>
        {error ? <InlineNotice title="Live refresh failed" message={error} tone="danger" /> : null}
        {!remote.macOnline ? <InlineNotice title="Mac unavailable" message="Live values pause while MacScope is offline, even when the phone remains connected to the relay." tone="warning" /> : null}
        {mode === "metrics" ? <MetricsContent /> : <ProcessesContent query={query} setQuery={setQuery} refresh={refreshProcesses} />}
      </ScrollView>
    </SafeAreaView>
  );
}

function Segment({ label, selected, onPress }: { label: string; selected: boolean; onPress(): void }) {
  const theme = useTheme();
  return <Pressable accessibilityRole="tab" accessibilityState={{ selected }} onPress={onPress} style={[styles.segmentButton, { backgroundColor: selected ? theme.card : "transparent", shadowColor: theme.shadow }]}><Text style={[styles.segmentText, { color: selected ? theme.text : theme.secondary }]}>{label}</Text></Pressable>;
}

function MetricsContent() {
  const remote = useRemote();
  const theme = useTheme();
  const frame = remote.metric;
  if (!frame) return <EmptyState title={remote.macOnline ? "Waiting for telemetry" : "Live data paused"} message={remote.macOnline ? "MacScope sends the first live snapshot after the connection is ready." : "Open MacScope on the paired Mac to resume live telemetry."} />;
  const summary = object(remote.liveData.summary);
  const cpu = object(remote.liveData.cpu);
  const memory = object(remote.liveData.memory);
  const battery = object(remote.liveData.battery);
  const network = object(remote.liveData.network);
  const storage = object(remote.liveData.storage);
  const thermals = object(remote.liveData.thermals);
  const accelerators = object(remote.liveData.accelerators);
  const hardware = object(remote.liveData.hardware);
  const startup = object(remote.liveData.startup);
  const metricSamples = array(remote.liveData.metrics);
  return (
    <>
      <SectionLabel detail={`Updated ${new Date(frame.timestamp).toLocaleTimeString()}`}>At a glance</SectionLabel>
      <View style={styles.grid}>
        <MetricCard title="CPU" value={`${frame.cpuPercent.toFixed(0)}%`} percent={frame.cpuPercent} detail={`${numeric(cpu?.cpuUser).toFixed(0)}% user · ${numeric(cpu?.cpuSystem).toFixed(0)}% system`} color={palette.cyan} />
        <MetricCard title="Memory" value={`${frame.memoryPercent.toFixed(0)}%`} percent={frame.memoryPercent} detail={`${formatBytes(frame.memoryUsedBytes)} used`} color={palette.blue} />
        <MetricCard title="GPU" value={frame.gpuPercent == null ? "—" : `${frame.gpuPercent.toFixed(0)}%`} percent={frame.gpuPercent} detail={frame.anePercent == null ? "ANE unavailable" : `ANE ${frame.anePercent.toFixed(0)}%`} color={palette.mint} />
        <MetricCard title="Power" value={frame.systemPowerWatts == null ? "—" : `${frame.systemPowerWatts.toFixed(1)} W`} detail={frame.batteryPercent == null ? "Desktop power" : `${frame.batteryPercent.toFixed(0)}% battery`} color={palette.amber} />
      </View>

      <SectionLabel detail="Per-core load, pressure, swap, battery and deep telemetry.">Detailed telemetry</SectionLabel>
      <DataCard title="System summary" value={summary} />
      <DataCard title="CPU cores" value={cpu?.cores} />
      <DataCard title="Memory & swap" value={memory} />
      <DataCard title="Battery & power" value={battery} />
      <DataCard title="Thermal sensors & fans" value={thermals} />
      <DataCard title="GPU, ANE & frequencies" value={accelerators} />
      <DataCard title="Hardware inventory" value={hardware} />
      <DataCard title="Network interfaces & connections" value={network} />
      <DataCard title="Disks & SMART" value={storage} />
      <DataCard title="Startup items" value={startup} />

      <SectionLabel detail={`${metricSamples.length} samples, including availability and provenance.`}>All MacScope metrics</SectionLabel>
      {metricSamples.length ? metricSamples.map((sample, index) => <MetricSampleRow key={`${string(sample.id)}-${index}`} value={sample} />) : <Card><Text style={{ color: theme.secondary }}>No detailed metric samples are available yet.</Text></Card>}
    </>
  );
}

function ProcessesContent({ query, setQuery, refresh }: { query: string; setQuery(value: string): void; refresh(): Promise<void> }) {
  const remote = useRemote();
  const processes = useMemo(() => array(remote.liveData.processes).map(toProcess).filter((value): value is ProcessSnapshot => Boolean(value)).sort((a, b) => b.cpuPercent - a.cpuPercent), [remote.liveData.processes]);
  return (
    <>
      <SearchField value={query} onChangeText={setQuery} onSubmitEditing={() => void refresh()} returnKeyType="search" placeholder="Search name or PID, then press Search" autoCapitalize="none" autoCorrect={false} />
      <SectionLabel detail={`${processes.length} live processes · refreshes every 4 seconds · search checks the full Mac process list`}>Running processes</SectionLabel>
      {processes.length ? processes.map((process) => <ProcessCard key={`${process.pid}-${process.startedAt}`} process={process} />) : <EmptyState title={remote.macOnline ? "No processes returned" : "Processes unavailable"} message={remote.macOnline ? "Try a different search or wait for the next telemetry sample." : "Open MacScope on the paired Mac to load and manage running processes."} />}
    </>
  );
}

function ProcessCard({ process }: { process: ProcessSnapshot }) {
  const remote = useRemote();
  const theme = useTheme();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const terminate = async () => {
    if (!process.startedAt) { setError("MacScope did not return a safe process start identity."); return; }
    setBusy(true); setError(undefined);
    try {
      const command = await remote.prepareCommand("utility.maintenance.process-terminate", { pid: process.pid, expected_start_time: process.startedAt });
      router.push({ pathname: "/confirm", params: { command: JSON.stringify(command) } });
    } catch (reason) { setError(reason instanceof Error ? reason.message : "The process action could not be prepared."); }
    finally { setBusy(false); }
  };
  return (
    <Card>
      <View style={styles.processHeader}><View style={styles.processCopy}><Text selectable numberOfLines={1} style={[styles.processName, { color: theme.text }]}>{process.name}</Text><Text style={[styles.processMeta, { color: theme.secondary }]}>PID {process.pid} · {process.state} · {process.threads} threads</Text></View><Tag tone={process.cpuPercent > 50 ? "warning" : "neutral"}>{process.cpuPercent.toFixed(1)}% CPU</Tag></View>
      <MetricBar value={Math.min(process.cpuPercent, 100)} color={process.cpuPercent > 50 ? palette.amber : palette.cyan} />
      <Text style={[styles.processMeta, { color: theme.secondary }]}>{formatBytes(process.residentMemory)} memory · ↓ {formatBytes(process.bytesRead)} · ↑ {formatBytes(process.bytesWritten)}</Text>
      {error ? <InlineNotice title="Cannot terminate" message={error} tone="danger" /> : null}
      <ActionButton title={busy ? "Preparing…" : "Terminate process…"} secondary destructive disabled={busy || !process.startedAt || !remote.macOnline} onPress={() => void terminate()} />
    </Card>
  );
}

function MetricCard({ title, value, detail, percent, color }: { title: string; value: string; detail: string; percent?: number; color: string }) {
  const theme = useTheme();
  return <Card style={styles.metricCard}><Text style={[styles.metricTitle, { color: theme.secondary }]}>{title}</Text><Text style={[styles.metricValue, { color: theme.text }]}>{value}</Text>{percent != null ? <MetricBar value={percent} color={color} /> : <View style={{ height: 5 }} />}<Text numberOfLines={2} style={[styles.metricDetail, { color: theme.secondary }]}>{detail}</Text></Card>;
}

function DataCard({ title, value }: { title: string; value: unknown }) {
  const theme = useTheme();
  const rows = flatten(value).slice(0, 80);
  if (!rows.length) return null;
  return <Card><Text style={[styles.dataTitle, { color: theme.text }]}>{title}</Text>{rows.map(([key, row], index) => <View key={`${key}-${index}`} style={styles.dataRow}><Text numberOfLines={2} style={[styles.dataKey, { color: theme.secondary }]}>{key}</Text><Text selectable numberOfLines={3} style={[styles.dataValue, { color: theme.text }]}>{row}</Text></View>)}</Card>;
}

function MetricSampleRow({ value }: { value: Record<string, unknown> }) {
  const theme = useTheme();
  return <View style={[styles.sample, { borderBottomColor: theme.border }]}><View style={styles.sampleCopy}><Text selectable style={[styles.sampleName, { color: theme.text }]}>{string(value.name) || string(value.id) || "Metric"}</Text><Text style={[styles.processMeta, { color: theme.secondary }]}>{[string(value.source), string(value.scope), string(value.availability)].filter(Boolean).join(" · ")}</Text></View><Text style={[styles.sampleValue, { color: theme.accent }]}>{metricValue(value)}</Text></View>;
}

function toProcess(value: Record<string, unknown>): ProcessSnapshot | undefined {
  if (typeof value.pid !== "number" || typeof value.name !== "string") return undefined;
  return { pid: value.pid, parentPID: numeric(value.parentPID), name: value.name, state: string(value.state), cpuPercent: numeric(value.cpuPercent), residentMemory: numeric(value.residentMemory), virtualMemory: numeric(value.virtualMemory), threads: numeric(value.threads), bytesRead: numeric(value.bytesRead), bytesWritten: numeric(value.bytesWritten), startedAt: typeof value.startedAt === "string" ? value.startedAt : undefined, availability: string(value.availability) };
}
function flatten(value: unknown, prefix = ""): [string, string][] { if (value == null) return []; if (Array.isArray(value)) return value.flatMap((item, index) => flatten(item, prefix ? `${prefix} ${index + 1}` : `Item ${index + 1}`)); if (typeof value === "object") return Object.entries(value as Record<string, unknown>).flatMap(([key, item]) => flatten(item, prefix ? `${prefix} · ${friendly(key)}` : friendly(key))); return [[prefix || "Value", formatScalar(value)]]; }
function friendly(value: string): string { return value.replace(/([a-z])([A-Z])/gu, "$1 $2").replaceAll("_", " ").replace(/^./u, (letter) => letter.toUpperCase()); }
function formatScalar(value: unknown): string { if (typeof value === "number") return Number.isInteger(value) ? value.toLocaleString() : value.toFixed(2); if (typeof value === "boolean") return value ? "Yes" : "No"; return String(value); }
function metricValue(value: Record<string, unknown>): string { const raw = value.value ?? value.numericValue ?? value.number ?? "—"; return `${formatScalar(raw)}${string(value.unit) ? ` ${string(value.unit)}` : ""}`; }
function object(value: unknown): Record<string, unknown> | undefined { return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined; }
function array(value: unknown): Record<string, unknown>[] { return Array.isArray(value) ? value.map(object).filter((item): item is Record<string, unknown> => Boolean(item)) : []; }
function string(value: unknown): string { return typeof value === "string" ? value : ""; }
function numeric(value: unknown): number { return typeof value === "number" && Number.isFinite(value) ? value : 0; }
function formatBytes(value: number): string { if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(1)} GB`; if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(1)} MB`; if (value >= 1024) return `${Math.round(value / 1024)} KB`; return `${value} B`; }

const styles = StyleSheet.create({
  safe: { flex: 1 }, content: { paddingHorizontal: 18, paddingTop: 12, paddingBottom: 42, gap: 17 }, segment: { flexDirection: "row", borderRadius: 14, padding: 4, gap: 3 }, segmentButton: { flex: 1, minHeight: 42, borderRadius: 11, alignItems: "center", justifyContent: "center", shadowOpacity: 0.05, shadowRadius: 8, shadowOffset: { width: 0, height: 3 } }, segmentText: { fontSize: 14, fontWeight: "700" },
  grid: { flexDirection: "row", flexWrap: "wrap", gap: 10 }, metricCard: { width: "48%", minWidth: 145 }, metricTitle: { fontSize: 11, fontWeight: "800", letterSpacing: 0.8, textTransform: "uppercase" }, metricValue: { fontSize: 25, fontWeight: "900", letterSpacing: -0.6 }, metricDetail: { fontSize: 11, lineHeight: 15 },
  dataTitle: { fontSize: 16, fontWeight: "800", marginBottom: 2 }, dataRow: { flexDirection: "row", gap: 12, paddingVertical: 5 }, dataKey: { flex: 1, fontSize: 11, lineHeight: 15 }, dataValue: { flex: 1, textAlign: "right", fontSize: 11, lineHeight: 15, fontVariant: ["tabular-nums"] },
  sample: { minHeight: 58, flexDirection: "row", alignItems: "center", gap: 12, borderBottomWidth: StyleSheet.hairlineWidth, paddingVertical: 9 }, sampleCopy: { flex: 1, gap: 3 }, sampleName: { fontSize: 13, fontWeight: "700" }, sampleValue: { maxWidth: "35%", textAlign: "right", fontSize: 13, fontWeight: "800", fontVariant: ["tabular-nums"] },
  processHeader: { flexDirection: "row", alignItems: "flex-start", gap: 10 }, processCopy: { flex: 1, gap: 3 }, processName: { fontSize: 15, fontWeight: "800" }, processMeta: { fontSize: 11, lineHeight: 15 },
});
