import * as Haptics from "expo-haptics";
import * as LocalAuthentication from "expo-local-authentication";
import { router, useLocalSearchParams } from "expo-router";
import React, { useEffect, useMemo, useState } from "react";
import { ScrollView, Text, View } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import type { PreparedCommand } from "@/remote/types";
import { requireDeviceAuthentication } from "@/remote/security";
import { ActionButton, Card, SectionLabel } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function ConfirmScreen() {
  const params = useLocalSearchParams<{ command?: string }>();
  const remote = useRemote();
  const theme = useTheme();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [expired, setExpired] = useState(false);
  const command = useMemo(() => {
    try { return params.command ? JSON.parse(params.command) as PreparedCommand : undefined; }
    catch { return undefined; }
  }, [params.command]);

  useEffect(() => {
    if (!command) return;
    const delay = Math.max(new Date(command.expiresAt).getTime() - Date.now(), 0);
    const timer = setTimeout(() => setExpired(true), delay);
    return () => clearTimeout(timer);
  }, [command]);

  if (!command) {
    return <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18 }}><Card><Text selectable style={{ color: palette.red }}>The prepared command is missing or invalid.</Text></Card></ScrollView>;
  }

  const apply = async () => {
    setBusy(true);
    setError(undefined);
    try {
      await requireDeviceAuthentication(command.requiresDeviceAuthentication, {
        hasHardware: LocalAuthentication.hasHardwareAsync,
        isEnrolled: LocalAuthentication.isEnrolledAsync,
        authenticate: () => LocalAuthentication.authenticateAsync({
          promptMessage: "Confirm MacScope remote action",
          cancelLabel: "Cancel",
          disableDeviceFallback: false,
        }),
      });
      await remote.applyCommand(command);
      await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      router.replace({ pathname: "/command/[id]", params: { id: command.commandID, actionID: command.actionID } });
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The command could not be applied.");
    } finally {
      setBusy(false);
    }
  };

  const riskColor = command.risk === "destructive" ? palette.red : command.risk === "sensitive" ? palette.amber : palette.cyan;
  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18, gap: 18, paddingBottom: 36 }}>
      <Card style={{ borderColor: `${riskColor}55` }}>
        <Text selectable style={{ color: riskColor, fontSize: 12, fontWeight: "900", letterSpacing: 1 }}>{command.risk.replace("_", " ").toUpperCase()}</Text>
        <Text selectable style={{ color: theme.text, fontSize: 23, fontWeight: "900" }}>{command.title ?? command.actionID}</Text>
        {command.summary ? <Text selectable style={{ color: theme.secondary, fontSize: 14, lineHeight: 21 }}>{command.summary}</Text> : null}
      </Card>

      <SectionLabel>Exact confirmation</SectionLabel>
      <Card>
        <Text selectable style={{ color: theme.text, fontFamily: process.env.EXPO_OS === "ios" ? "Menlo" : "monospace", fontSize: 13 }}>{command.confirmation}</Text>
        <View style={{ height: 1, backgroundColor: theme.border }} />
        <Text selectable style={{ color: expired ? palette.red : theme.secondary, fontSize: 12 }}>
          {expired ? "This approval has expired." : `Expires ${new Date(command.expiresAt).toLocaleTimeString()}`}
        </Text>
        {command.restartEffect ? <Text selectable style={{ color: palette.amber, fontSize: 12 }}>Restart effect: {command.restartEffect}</Text> : null}
      </Card>
      {command.requiresDeviceAuthentication ? <Card><Text selectable style={{ color: theme.secondary, fontSize: 13 }}>This action requires Face ID, Touch ID, or the device credential before it is sent.</Text></Card> : null}
      {error ? <Text selectable style={{ color: palette.red }}>{error}</Text> : null}
      <ActionButton title={busy ? "Applying…" : expired ? "Approval expired" : "Confirm and apply"} disabled={busy || expired || !remote.macOnline} destructive={command.risk === "destructive"} onPress={() => void apply()} />
    </ScrollView>
  );
}
