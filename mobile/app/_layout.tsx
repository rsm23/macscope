import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Stack } from "expo-router/stack";
import { StatusBar } from "expo-status-bar";
import React from "react";
import { RemoteProvider } from "@/remote/remote-provider";
import { useTheme } from "@/ui/theme";

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 30_000, retry: 1 }, mutations: { retry: 0 } },
});

export default function RootLayout() {
  const theme = useTheme();
  return (
    <QueryClientProvider client={queryClient}>
      <RemoteProvider>
        <StatusBar style="light" />
        <Stack
          screenOptions={{
            headerTransparent: true,
            headerShadowVisible: false,
            headerBackButtonDisplayMode: "minimal",
            contentStyle: { backgroundColor: theme.background },
            headerTitleStyle: { color: theme.text },
          }}
        >
          <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
          <Stack.Screen name="pair" options={{ title: "Pair a Mac", presentation: "modal" }} />
          <Stack.Screen name="confirm" options={{ title: "Confirm action", presentation: "formSheet", sheetGrabberVisible: true, sheetAllowedDetents: [0.6, 1] }} />
          <Stack.Screen name="utility/[id]" options={{ title: "Utility" }} />
          <Stack.Screen name="command/[id]" options={{ title: "Command result", headerTransparent: false, headerStyle: { backgroundColor: theme.background } }} />
          <Stack.Screen name="features" options={{ title: "Features & preferences" }} />
        </Stack>
      </RemoteProvider>
    </QueryClientProvider>
  );
}
