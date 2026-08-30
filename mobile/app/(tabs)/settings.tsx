import { Link } from "expo-router";
import React, { useState } from "react";
import { Alert, Pressable, ScrollView, Share, Switch, Text, View } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import type { RemoteRole } from "@/remote/types";
import { ActionButton, Card, EmptyState, SectionLabel } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function SettingsScreen() {
  const remote = useRemote();
  const theme = useTheme();
  const [busy, setBusy] = useState(false);
  const owner = remote.activeEnvironment?.role === "owner";

  const invite = async (role: RemoteRole) => {
    setBusy(true);
    try {
      const pairing = await remote.createPairing(role);
      await Share.share({ title: `MacScope ${role} invitation`, message: `Pair with MacScope as ${role}. This link works once and expires at ${new Date(pairing.expiresAt).toLocaleTimeString()}:\n\n${pairing.pairingURL}` });
    } catch (reason) {
      Alert.alert("Could not create invitation", reason instanceof Error ? reason.message : "Unknown error");
    } finally {
      setBusy(false);
    }
  };

  if (!remote.activeEnvironment) {
    return (
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18, gap: 18 }}>
        <EmptyState title="No paired Mac" message="Pair the first Mac to configure notifications, members, and stored environments." />
        <Link href="/pair" asChild><Pressable><Text style={{ color: palette.cyan, textAlign: "center", fontWeight: "800" }}>Pair a Mac</Text></Pressable></Link>
      </ScrollView>
    );
  }

  const setNotification = (key: keyof typeof remote.notifications, value: boolean) => {
    void remote.setNotifications({ ...remote.notifications, [key]: value });
  };

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18, gap: 18, paddingBottom: 36 }}>
      <SectionLabel>Paired Macs</SectionLabel>
      <Card style={{ padding: 0, gap: 0, overflow: "hidden" }}>
        {remote.environments.map((environment, index) => {
          const active = environment.environmentID === remote.activeEnvironment?.environmentID;
          return (
            <Pressable key={environment.environmentID} onPress={() => void remote.selectEnvironment(environment.environmentID)} style={{ padding: 16, flexDirection: "row", alignItems: "center", gap: 12, borderBottomColor: theme.border, borderBottomWidth: index < remote.environments.length - 1 ? 1 : 0 }}>
              <View style={{ width: 10, height: 10, borderRadius: 99, backgroundColor: active ? palette.mint : theme.border }} />
              <View style={{ flex: 1, gap: 3 }}>
                <Text selectable style={{ color: theme.text, fontSize: 15, fontWeight: "800" }}>{environment.displayName}</Text>
                <Text selectable style={{ color: theme.secondary, fontSize: 11 }}>{environment.role} · {environment.environmentID.slice(0, 12)}…</Text>
              </View>
              {active ? <Text style={{ color: palette.mint, fontWeight: "800" }}>ACTIVE</Text> : null}
            </Pressable>
          );
        })}
      </Card>
      <Link href="/pair" asChild><Pressable><Text style={{ color: palette.cyan, textAlign: "center", fontWeight: "800" }}>＋ Pair another Mac</Text></Pressable></Link>

      <SectionLabel>Notifications</SectionLabel>
      <Card style={{ padding: 0, gap: 0, overflow: "hidden" }}>
        <ToggleRow title="Usage alerts" detail="Configured CPU, memory, and power thresholds." value={remote.notifications.alerts} onValue={(value) => setNotification("alerts", value)} divider />
        <ToggleRow title="Mac presence" detail="Online and offline connection changes." value={remote.notifications.presence} onValue={(value) => setNotification("presence", value)} divider />
        <ToggleRow title="Command results" detail="Completion and failure of remote actions." value={remote.notifications.commands} onValue={(value) => setNotification("commands", value)} />
      </Card>

      {owner ? (
        <>
          <SectionLabel>Invite members</SectionLabel>
          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 10 }}>
            <View style={{ flexGrow: 1 }}><ActionButton title="Invite viewer" disabled={busy} onPress={() => void invite("viewer")} /></View>
            <View style={{ flexGrow: 1 }}><ActionButton title="Invite operator" disabled={busy} onPress={() => void invite("operator")} /></View>
            <View style={{ flexGrow: 1 }}><ActionButton title="Invite owner" disabled={busy} onPress={() => void invite("owner")} /></View>
          </View>

          <SectionLabel>Members</SectionLabel>
          <Card style={{ padding: 0, gap: 0, overflow: "hidden" }}>
            {remote.members.length === 0 ? <Text selectable style={{ color: theme.secondary, padding: 16 }}>Refresh after the Mac reconnects to load members.</Text> : remote.members.map((member, index) => (
              <View key={member.id} style={{ padding: 16, flexDirection: "row", alignItems: "center", gap: 12, borderBottomColor: theme.border, borderBottomWidth: index < remote.members.length - 1 ? 1 : 0 }}>
                <View style={{ flex: 1, gap: 3 }}>
                  <Text selectable style={{ color: theme.text, fontSize: 15, fontWeight: "800" }}>{member.displayName}</Text>
                  <Text selectable style={{ color: theme.secondary, fontSize: 12 }}>{member.role} · {member.deviceCount} device{member.deviceCount === 1 ? "" : "s"}</Text>
                </View>
                <Pressable onPress={() => Alert.alert("Revoke member?", "Every session for this member will close immediately.", [{ text: "Cancel", style: "cancel" }, { text: "Revoke", style: "destructive", onPress: () => void remote.revokeMember(member.id) }])}>
                  <Text style={{ color: palette.red, fontWeight: "800" }}>Revoke</Text>
                </Pressable>
              </View>
            ))}
          </Card>

          <SectionLabel>Recent audit</SectionLabel>
          <Card style={{ padding: 0, gap: 0, overflow: "hidden" }}>
            {remote.audit.length === 0 ? <Text selectable style={{ color: theme.secondary, padding: 16 }}>No remote command metadata yet.</Text> : remote.audit.slice(0, 20).map((event, index) => (
              <View key={event.id} style={{ padding: 14, gap: 4, borderBottomColor: theme.border, borderBottomWidth: index < Math.min(remote.audit.length, 20) - 1 ? 1 : 0 }}>
                <Text selectable style={{ color: theme.text, fontSize: 13, fontWeight: "800" }}>{event.actionID}</Text>
                <Text selectable style={{ color: theme.secondary, fontSize: 11 }}>{event.actorName} · {event.outcome} · {new Date(event.createdAt).toLocaleString()}</Text>
              </View>
            ))}
          </Card>
        </>
      ) : null}

      <SectionLabel>This device</SectionLabel>
      <ActionButton title="Remove this Mac from the app" destructive onPress={() => Alert.alert("Remove paired Mac?", "This deletes the credentials from this device. It does not reset other members.", [{ text: "Cancel", style: "cancel" }, { text: "Remove", style: "destructive", onPress: () => void remote.removeEnvironment(remote.activeEnvironment!.environmentID) }])} />
    </ScrollView>
  );
}

function ToggleRow({ title, detail, value, onValue, divider = false }: { title: string; detail: string; value: boolean; onValue: (value: boolean) => void; divider?: boolean }) {
  const theme = useTheme();
  return (
    <View style={{ padding: 16, flexDirection: "row", alignItems: "center", gap: 14, borderBottomColor: theme.border, borderBottomWidth: divider ? 1 : 0 }}>
      <View style={{ flex: 1, gap: 3 }}>
        <Text selectable style={{ color: theme.text, fontSize: 15, fontWeight: "800" }}>{title}</Text>
        <Text selectable style={{ color: theme.secondary, fontSize: 12 }}>{detail}</Text>
      </View>
      <Switch value={value} onValueChange={onValue} trackColor={{ true: palette.cyan }} />
    </View>
  );
}
