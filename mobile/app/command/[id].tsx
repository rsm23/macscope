import { useLocalSearchParams } from "expo-router";
import React from "react";
import { ScrollView, Text } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import { Card, SectionLabel } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function CommandResultScreen() {
  const { id, actionID, accepted, errorCode } = useLocalSearchParams<{
    id: string;
    actionID?: string;
    accepted?: string;
    errorCode?: string;
  }>();
  const remote = useRemote();
  const theme = useTheme();
  const live = remote.commandResults.find((result) => result.commandID === id);
  const succeeded = live?.accepted ?? accepted === "true";

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{ padding: 18, gap: 18, paddingBottom: 36 }}>
      <Card>
        <Text selectable style={{ color: succeeded ? palette.mint : palette.red, fontSize: 12, fontWeight: "900" }}>
          {succeeded ? "COMPLETED" : "FAILED"}
        </Text>
        <Text selectable style={{ color: theme.text, fontSize: 22, fontWeight: "900" }}>{live?.actionID ?? actionID ?? "Remote command"}</Text>
        <Text selectable style={{ color: theme.secondary, fontSize: 12, fontFamily: process.env.EXPO_OS === "ios" ? "Menlo" : "monospace" }}>{id}</Text>
      </Card>
      {(live?.errorMessage || errorCode) ? (
        <>
          <SectionLabel>Error category</SectionLabel>
          <Card><Text selectable style={{ color: palette.red }}>{live?.errorMessage ?? errorCode}</Text></Card>
        </>
      ) : null}
      <Text selectable style={{ color: theme.secondary, fontSize: 12, lineHeight: 18 }}>
        Notifications and audit records intentionally exclude command arguments and sensitive local values.
      </Text>
    </ScrollView>
  );
}
