import { Tabs } from "expo-router";
import React from "react";
import { Text, type ColorValue } from "react-native";
import { palette, useTheme } from "@/ui/theme";

const icon = (symbol: string, color: ColorValue) => <Text style={{ color, fontSize: 18, fontWeight: "800" }}>{symbol}</Text>;

export default function TabLayout() {
  const theme = useTheme();
  return (
    <Tabs screenOptions={{ headerShown: true, headerTransparent: true, headerShadowVisible: false, headerTitleStyle: { color: theme.text }, sceneStyle: { backgroundColor: theme.background }, tabBarActiveTintColor: palette.cyan, tabBarInactiveTintColor: theme.secondary, tabBarStyle: { backgroundColor: theme.card, borderTopColor: theme.border } }}>
      <Tabs.Screen name="index" options={{ title: "Overview", tabBarIcon: ({ color }) => icon("◉", color) }} />
      <Tabs.Screen name="features" options={{ title: "Features", tabBarIcon: ({ color }) => icon("⌁", color) }} />
      <Tabs.Screen name="utilities" options={{ title: "Utilities", tabBarIcon: ({ color }) => icon("◇", color) }} />
      <Tabs.Screen name="settings" options={{ title: "Settings", tabBarIcon: ({ color }) => icon("••", color) }} />
    </Tabs>
  );
}
