import { router, useLocalSearchParams } from "expo-router";
import React, { useMemo, useState } from "react";
import { ScrollView, Text, TextInput } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import { parseArgument } from "@/remote/arguments";
import { roleCanWrite } from "@/remote/security";
import { ActionButton, Card, EmptyState, SectionLabel } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function UtilityDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const remote = useRemote();
  const theme = useTheme();
  const action = remote.utilities.find((value) => value.id === id);
  const [values, setValues] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const argumentsList = useMemo(() => Object.entries(action?.arguments ?? {}), [action]);
  const canWrite = roleCanWrite(remote.activeEnvironment?.role);

  if (!action) {
    return <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18 }}><EmptyState title="Utility unavailable" message="The action is no longer advertised by this Mac." /></ScrollView>;
  }

  const prepare = async () => {
    setBusy(true);
    setError(undefined);
    try {
      const args = Object.fromEntries(argumentsList.filter(([name]) => values[name]?.trim()).map(([name, description]) => [name, parseArgument(values[name]!, description)]));
      const command = await remote.prepareCommand(`utility.${action.id}`, args);
      if (command.risk === "read_only") {
        await remote.applyCommand(command);
        router.back();
      } else {
        router.push({ pathname: "/confirm", params: { command: JSON.stringify(command) } });
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The utility could not be prepared.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" keyboardShouldPersistTaps="handled" contentContainerStyle={{ padding: 18, gap: 18, paddingBottom: 36 }}>
      <Card>
        <Text selectable style={{ color: theme.text, fontSize: 23, fontWeight: "900" }}>{action.title}</Text>
        <Text selectable style={{ color: theme.secondary, fontSize: 14, lineHeight: 21 }}>{action.summary}</Text>
        <Text selectable style={{ color: action.risk === "destructive" ? palette.red : action.risk === "sensitive" ? palette.amber : palette.cyan, fontSize: 12, fontWeight: "800" }}>{action.risk.replace("_", " ").toUpperCase()}</Text>
      </Card>

      {argumentsList.length ? <SectionLabel>Arguments</SectionLabel> : null}
      {argumentsList.map(([name, description]) => (
        <Card key={name}>
          <Text selectable style={{ color: theme.text, fontSize: 14, fontWeight: "800" }}>{name}</Text>
          <Text selectable style={{ color: theme.secondary, fontSize: 12, lineHeight: 17 }}>{description}</Text>
          <TextInput
            value={values[name] ?? ""}
            onChangeText={(value) => setValues((current) => ({ ...current, [name]: value }))}
            placeholder={description}
            placeholderTextColor={theme.secondary}
            autoCapitalize="none"
            autoCorrect={false}
            style={{ color: theme.text, backgroundColor: theme.background, borderColor: theme.border, borderWidth: 1, borderRadius: 13, borderCurve: "continuous", minHeight: 46, paddingHorizontal: 13 }}
          />
        </Card>
      ))}
      {error ? <Text selectable style={{ color: palette.red }}>{error}</Text> : null}
      <ActionButton title={busy ? "Preparing…" : !canWrite ? "Viewer access is read-only" : action.allowed ? "Review action" : "Blocked on Mac"} disabled={busy || !canWrite || !action.allowed || remote.connection !== "online"} onPress={() => void prepare()} destructive={action.risk === "destructive"} />
    </ScrollView>
  );
}
