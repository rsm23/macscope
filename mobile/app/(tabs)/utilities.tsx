import { Link } from "expo-router";
import React, { useMemo } from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import type { UtilityAction } from "@/remote/types";
import { Card, EmptyState, SectionLabel } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function UtilitiesScreen() {
  const remote = useRemote();
  const groups = useMemo(
    () => remote.utilities.reduce<Record<string, UtilityAction[]>>((result, action) => {
      (result[action.module] ??= []).push(action);
      return result;
    }, {}),
    [remote.utilities],
  );

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18, gap: 18, paddingBottom: 36 }}>
      {remote.utilities.length === 0 ? (
        <EmptyState title="No utilities available" message={remote.connection === "online" ? "Waiting for MacScope's typed utility catalog." : "Utilities can only be prepared while the Mac is online."} />
      ) : Object.entries(groups).map(([module, actions]) => (
        <View key={module} style={{ gap: 9 }}>
          <SectionLabel>{module}</SectionLabel>
          <Card style={{ padding: 0, gap: 0, overflow: "hidden" }}>
            {(actions ?? []).map((action, index) => (
              <Link key={action.id} href={{ pathname: "/utility/[id]", params: { id: action.id } }} asChild>
                <Pressable>
                  <UtilityRow action={action} divider={index < (actions?.length ?? 0) - 1} />
                </Pressable>
              </Link>
            ))}
          </Card>
        </View>
      ))}
    </ScrollView>
  );
}

function UtilityRow({ action, divider }: { action: ReturnType<typeof useRemote>["utilities"][number]; divider: boolean }) {
  const theme = useTheme();
  const riskColor = action.risk === "destructive" ? palette.red : action.risk === "sensitive" ? palette.amber : action.risk === "read_only" ? palette.mint : palette.cyan;
  return (
    <View style={{ padding: 16, gap: 7, borderBottomWidth: divider ? 1 : 0, borderBottomColor: divider ? theme.border : "transparent" }}>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
        <Text selectable style={{ color: theme.text, fontSize: 15, fontWeight: "800", flex: 1 }}>{action.title}</Text>
        <View style={{ backgroundColor: `${riskColor}18`, paddingHorizontal: 8, paddingVertical: 4, borderRadius: 99 }}>
          <Text style={{ color: riskColor, fontSize: 10, fontWeight: "800" }}>{action.risk.replace("_", " ").toUpperCase()}</Text>
        </View>
      </View>
      <Text selectable style={{ color: theme.secondary, fontSize: 13, lineHeight: 18 }}>{action.summary}</Text>
      {!action.allowed ? <Text selectable style={{ color: palette.amber, fontSize: 11 }}>Disabled by this Mac&apos;s local Remote policy</Text> : null}
    </View>
  );
}
