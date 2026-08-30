import { router, useFocusEffect, useLocalSearchParams } from "expo-router";
import React, { memo, useCallback, useEffect, useMemo, useState } from "react";
import { FlatList, Pressable, RefreshControl, ScrollView, SectionList, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { applicationSections, applicationsFromWindowsState, canQuitApplication, type ApplicationSection, type RemoteApplication } from "@/remote/applications";
import { useRemote } from "@/remote/remote-provider";
import type { ProcessSnapshot, SnapshotSection } from "@/remote/types";
import { ActionButton, Card, EmptyState, InlineNotice, MetricBar, ScreenHeader, SearchField, SectionLabel, Tag } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

type Mode = "metrics" | "apps" | "processes";
const detailSections: SnapshotSection[][] = [
  ["summary", "cpu", "memory", "battery"],
  ["network"], ["storage"], ["startup"], ["hardware", "thermals", "accelerators", "metrics"],
];

export default function LiveScreen() {
  const { mode: requestedMode } = useLocalSearchParams<{ mode?: Mode }>();
  const remote = useRemote();
  const theme = useTheme();
  const mode: Mode = requestedMode === "apps" || requestedMode === "processes" ? requestedMode : "metrics";
  const setMode = useCallback((value: Mode) => router.setParams({ mode: value }), []);
  const [processQuery, setProcessQuery] = useState("");
  const [appQuery, setAppQuery] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string>();
  const macOnline = remote.macOnline;
  const refreshLiveData = remote.refreshLiveData;
  const refreshUtilityState = remote.refreshUtilityState;

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
    try { await refreshLiveData(["processes"], { processLimit: 150, processQuery: processQuery.trim() || undefined }); }
    catch (reason) { setError(reason instanceof Error ? reason.message : "Processes could not be refreshed."); }
    finally { setRefreshing(false); }
  }, [macOnline, processQuery, refreshLiveData]);

  const refreshApps = useCallback(async () => {
    if (!macOnline) return;
    setRefreshing(true); setError(undefined);
    try { await refreshUtilityState("windows"); }
    catch (reason) { setError(reason instanceof Error ? reason.message : "Applications could not be refreshed."); }
    finally { setRefreshing(false); }
  }, [macOnline, refreshUtilityState]);

  const refreshCurrent = useCallback(() => {
    if (mode === "metrics") return refreshMetrics();
    if (mode === "apps") return refreshApps();
    return refreshProcesses();
  }, [mode, refreshApps, refreshMetrics, refreshProcesses]);

  useFocusEffect(useCallback(() => { void refreshCurrent(); }, [refreshCurrent]));
  useEffect(() => {
    if (mode === "metrics" || !macOnline) return;
    const timer = setInterval(() => { void (mode === "apps" ? refreshApps() : refreshProcesses()); }, 4_000);
    return () => clearInterval(timer);
  }, [macOnline, mode, refreshApps, refreshProcesses]);

  const header = <LiveHeader mode={mode} setMode={setMode} error={error} macOnline={remote.macOnline} />;

  return (
    <SafeAreaView style={[styles.safe, { backgroundColor: theme.background }]} edges={["top"]}>
      {mode === "metrics" ? (
        <ScrollView refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => void refreshMetrics()} tintColor={theme.accent} />} contentContainerStyle={styles.content}>
          {header}
          <MetricsContent />
        </ScrollView>
      ) : mode === "apps" ? (
        <ApplicationsList header={header} query={appQuery} setQuery={setAppQuery} refreshing={refreshing} refresh={refreshApps} />
      ) : (
        <ProcessesList header={header} query={processQuery} setQuery={setProcessQuery} refreshing={refreshing} refresh={refreshProcesses} />
      )}
    </SafeAreaView>
  );
}

function LiveHeader({ mode, setMode, error, macOnline }: { mode: Mode; setMode(value: Mode): void; error?: string; macOnline: boolean }) {
  const theme = useTheme();
  return (
    <>
      <ScreenHeader eyebrow="Live from MacScope" title="System" detail="Metrics, running applications and processes from the connected Mac." />
      <View accessibilityRole="tablist" style={[styles.segment, { backgroundColor: theme.subtle }]}>
        <Segment label="Metrics" selected={mode === "metrics"} onPress={() => setMode("metrics")} />
        <Segment label="Apps" selected={mode === "apps"} onPress={() => setMode("apps")} />
        <Segment label="Processes" selected={mode === "processes"} onPress={() => setMode("processes")} />
      </View>
      {error ? <InlineNotice title="Live refresh failed" message={error} tone="danger" /> : null}
      {!macOnline ? <InlineNotice title="Mac unavailable" message="Live values pause while MacScope is offline, even when the phone remains connected to the relay." tone="warning" /> : null}
    </>
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

function ProcessesList({ header, query, setQuery, refreshing, refresh }: { header: React.ReactElement; query: string; setQuery(value: string): void; refreshing: boolean; refresh(): Promise<void> }) {
  const remote = useRemote();
  const processes = useMemo(() => array(remote.liveData.processes).map(toProcess).filter((value): value is ProcessSnapshot => Boolean(value)).sort((a, b) => b.cpuPercent - a.cpuPercent), [remote.liveData.processes]);
  const renderItem = useCallback(({ item }: { item: ProcessSnapshot }) => <ProcessCard process={item} />, []);
  return (
    <FlatList
      data={processes}
      keyExtractor={(item) => `${item.pid}-${item.startedAt}`}
      renderItem={renderItem}
      refreshing={refreshing}
      onRefresh={() => void refresh()}
      keyboardShouldPersistTaps="handled"
      contentContainerStyle={styles.content}
      ListHeaderComponent={<View style={styles.listHeader}>{header}<SearchField value={query} onChangeText={setQuery} onSubmitEditing={() => void refresh()} returnKeyType="search" placeholder="Search name or PID, then press Search" autoCapitalize="none" autoCorrect={false} /><SectionLabel detail={`${processes.length} live processes · refreshes every 4 seconds · search checks the full Mac process list`}>Running processes</SectionLabel></View>}
      ListEmptyComponent={<EmptyState title={remote.macOnline ? "No processes returned" : "Processes unavailable"} message={remote.macOnline ? "Try a different search or wait for the next telemetry sample." : "Open MacScope on the paired Mac to load and manage running processes."} />}
      removeClippedSubviews
      maxToRenderPerBatch={12}
      windowSize={7}
    />
  );
}

const ProcessCard = memo(function ProcessCard({ process }: { process: ProcessSnapshot }) {
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
});

function ApplicationsList({ header, query, setQuery, refreshing, refresh }: { header: React.ReactElement; query: string; setQuery(value: string): void; refreshing: boolean; refresh(): Promise<void> }) {
  const remote = useRemote();
  const theme = useTheme();
  const applications = useMemo(() => applicationsFromWindowsState(remote.utilityStates.windows), [remote.utilityStates.windows]);
  const sections = useMemo(() => applicationSections(applications, query), [applications, query]);
  const renderItem = useCallback(({ item }: { item: RemoteApplication }) => <ApplicationCard application={item} />, []);
  const renderSectionHeader = useCallback(({ section }: { section: ApplicationSection }) => <ApplicationSectionHeader section={section} />, []);
  return (
    <SectionList
      sections={sections}
      keyExtractor={(item) => item.id}
      renderItem={renderItem}
      renderSectionHeader={renderSectionHeader}
      stickySectionHeadersEnabled={false}
      refreshing={refreshing}
      onRefresh={() => void refresh()}
      keyboardShouldPersistTaps="handled"
      contentContainerStyle={styles.content}
      ListHeaderComponent={<View style={styles.listHeader}>{header}<SearchField value={query} onChangeText={setQuery} returnKeyType="search" placeholder="Search applications" autoCapitalize="none" autoCorrect={false} /><Text style={[styles.refreshNote, { color: theme.secondary }]}>{applications.length} applications · refreshes every 4 seconds</Text></View>}
      SectionSeparatorComponent={() => <View style={styles.applicationSectionGap} />}
      ItemSeparatorComponent={() => <View style={styles.applicationRowGap} />}
      ListEmptyComponent={<EmptyState title={remote.macOnline ? "No applications found" : "Applications unavailable"} message={remote.macOnline ? "Try a different search or pull to refresh the application catalog." : "Open MacScope on the paired Mac to manage applications."} />}
      removeClippedSubviews
      maxToRenderPerBatch={12}
      windowSize={7}
    />
  );
}

function ApplicationSectionHeader({ section }: { section: ApplicationSection }) {
  const theme = useTheme();
  return <View style={styles.applicationSectionHeader}><View><Text style={[styles.applicationSectionTitle, { color: theme.text }]}>{section.title}</Text><Text style={[styles.applicationSectionDetail, { color: theme.secondary }]}>{section.detail}</Text></View><View style={[styles.sectionCount, { backgroundColor: theme.elevated }]}><Text style={[styles.sectionCountText, { color: theme.accent }]}>{section.data.length}</Text></View></View>;
}

const ApplicationCard = memo(function ApplicationCard({ application }: { application: RemoteApplication }) {
  const remote = useRemote();
  const theme = useTheme();
  const [busy, setBusy] = useState<"open" | "quit">();
  const [error, setError] = useState<string>();
  const quitAllowed = canQuitApplication(application);

  const prepare = async (kind: "open" | "quit") => {
    if (!application.bundleIdentifier) { setError("This application does not expose a stable bundle identifier."); return; }
    if (kind === "quit" && !application.pid) { setError("The application is no longer running."); return; }
    setBusy(kind); setError(undefined);
    try {
      const command = kind === "quit"
        ? await remote.prepareCommand("utility.windows.quit-app", { pid: application.pid, expected_bundle_identifier: application.bundleIdentifier })
        : application.running && application.pid
          ? await remote.prepareCommand("utility.windows.activate-app", { pid: application.pid })
          : await remote.prepareCommand("utility.windows.launch-app", { bundle_identifier: application.bundleIdentifier });
      router.push({ pathname: "/confirm", params: { command: JSON.stringify(command) } });
    } catch (reason) { setError(reason instanceof Error ? reason.message : "The application action could not be prepared."); }
    finally { setBusy(undefined); }
  };

  return (
    <View style={[styles.applicationRow, { backgroundColor: theme.card, borderColor: theme.border }]}>
      <View style={styles.processHeader}>
        <View style={[styles.appMark, { backgroundColor: application.active ? theme.accent : theme.elevated }]}><Text style={[styles.appMarkText, { color: application.active ? theme.onAccent : theme.text }]}>{application.name.slice(0, 1).toLocaleUpperCase()}</Text></View>
        <View style={styles.processCopy}>
          <Text selectable numberOfLines={1} style={[styles.processName, { color: theme.text }]}>{application.name}</Text>
          <Text selectable numberOfLines={1} style={[styles.processMeta, { color: theme.secondary }]}>{application.bundleIdentifier ?? `PID ${application.pid}`}</Text>
        </View>
        <Tag tone={application.active ? "accent" : "neutral"}>{application.active ? "Frontmost" : application.running ? application.hidden ? "Hidden" : "Running" : "Installed"}</Tag>
      </View>
      {error ? <InlineNotice title="Cannot manage app" message={error} tone="danger" /> : null}
      <View style={styles.applicationActions}><AppAction title={busy === "open" ? "Preparing…" : application.running ? "Bring forward" : "Launch"} disabled={Boolean(busy) || !application.bundleIdentifier || !remote.macOnline} onPress={() => void prepare("open")} />{quitAllowed ? <AppAction title={busy === "quit" ? "Preparing…" : "Quit"} destructive disabled={Boolean(busy) || !remote.macOnline} onPress={() => void prepare("quit")} /> : null}</View>
    </View>
  );
});

function AppAction({ title, disabled, destructive = false, onPress }: { title: string; disabled?: boolean; destructive?: boolean; onPress(): void }) {
  const theme = useTheme();
  const color = destructive ? palette.red : theme.accent;
  return <Pressable accessibilityRole="button" accessibilityLabel={title} disabled={disabled} onPress={onPress} style={({ pressed }) => [styles.appAction, { backgroundColor: `${color}12`, borderColor: `${color}30`, opacity: disabled ? 0.4 : pressed ? 0.68 : 1 }]}><Text style={[styles.appActionText, { color }]}>{title}</Text></Pressable>;
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
  safe: { flex: 1 }, content: { paddingHorizontal: 18, paddingTop: 14, paddingBottom: 48, gap: 22 }, segment: { flexDirection: "row", borderRadius: 14, padding: 4, gap: 4 }, segmentButton: { flex: 1, minHeight: 44, borderRadius: 11, alignItems: "center", justifyContent: "center", shadowOpacity: 0.05, shadowRadius: 8, shadowOffset: { width: 0, height: 3 } }, segmentText: { fontSize: 14, fontWeight: "700" },
  grid: { flexDirection: "row", flexWrap: "wrap", gap: 10 }, metricCard: { width: "48%", minWidth: 145 }, metricTitle: { fontSize: 11, fontWeight: "800", letterSpacing: 0.8, textTransform: "uppercase" }, metricValue: { fontSize: 25, fontWeight: "900", letterSpacing: -0.6 }, metricDetail: { fontSize: 11, lineHeight: 15 },
  dataTitle: { fontSize: 16, fontWeight: "800", marginBottom: 2 }, dataRow: { flexDirection: "row", gap: 12, paddingVertical: 5 }, dataKey: { flex: 1, fontSize: 11, lineHeight: 15 }, dataValue: { flex: 1, textAlign: "right", fontSize: 11, lineHeight: 15, fontVariant: ["tabular-nums"] },
  sample: { minHeight: 58, flexDirection: "row", alignItems: "center", gap: 12, borderBottomWidth: StyleSheet.hairlineWidth, paddingVertical: 9 }, sampleCopy: { flex: 1, gap: 3 }, sampleName: { fontSize: 13, fontWeight: "700" }, sampleValue: { maxWidth: "35%", textAlign: "right", fontSize: 13, fontWeight: "800", fontVariant: ["tabular-nums"] },
  processHeader: { flexDirection: "row", alignItems: "flex-start", gap: 10 }, processCopy: { flex: 1, gap: 3 }, processName: { fontSize: 15, fontWeight: "800" }, processMeta: { fontSize: 11, lineHeight: 15 },
  listHeader: { gap: 16, paddingBottom: 8 }, refreshNote: { fontSize: 11, lineHeight: 16 }, applicationSectionHeader: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingTop: 5, paddingBottom: 10 }, applicationSectionTitle: { fontSize: 18, fontWeight: "800", letterSpacing: -0.35 }, applicationSectionDetail: { fontSize: 11, marginTop: 2 }, sectionCount: { minWidth: 30, minHeight: 26, borderRadius: 8, alignItems: "center", justifyContent: "center" }, sectionCountText: { fontSize: 12, fontWeight: "900" }, applicationSectionGap: { height: 24 }, applicationRowGap: { height: 8 }, applicationRow: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 12, padding: 13, gap: 12 }, appMark: { width: 38, height: 38, borderRadius: 10, alignItems: "center", justifyContent: "center" }, appMarkText: { fontSize: 16, fontWeight: "900" }, applicationActions: { flexDirection: "row", gap: 8, paddingLeft: 48 }, appAction: { minHeight: 34, borderRadius: 8, borderWidth: 1, paddingHorizontal: 12, alignItems: "center", justifyContent: "center" }, appActionText: { fontSize: 12, fontWeight: "800" },
});
