import { Tabs } from "expo-router";
import React from "react";
import { Text, type ColorValue } from "react-native";
import { useTheme } from "@/ui/theme";

const icon = (symbol: string, color: ColorValue) => <Text style={{ color, fontSize: 18, fontWeight: "800" }}>{symbol}</Text>;

export default function TabLayout() {
  const theme = useTheme();
  return (
    <Tabs screenOptions={{ headerShown: false, sceneStyle: { backgroundColor: theme.background }, tabBarActiveTintColor: theme.accent, tabBarInactiveTintColor: theme.secondary, tabBarLabelStyle: { fontSize: 10.5, fontWeight: "700" }, tabBarStyle: { backgroundColor: theme.card, borderTopColor: theme.border } }}>
      <Tabs.Screen name="index" options={{ title: "Overview", tabBarIcon: ({ color }) => icon("◉", color) }} />
      <Tabs.Screen name="live" options={{ title: "Live", tabBarIcon: ({ color }) => icon("⌁", color) }} />
      <Tabs.Screen name="utilities" options={{ title: "Tools", tabBarIcon: ({ color }) => icon("◇", color) }} />
      <Tabs.Screen name="library" options={{ title: "Library", tabBarIcon: ({ color }) => icon("▣", color) }} />
      <Tabs.Screen name="settings" options={{ title: "Settings", tabBarIcon: ({ color }) => icon("••", color) }} />
    </Tabs>
  );
}
