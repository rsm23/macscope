import { Image, useImage } from "expo-image";
import React, { useState } from "react";
import { ActivityIndicator, StyleSheet, Text, View, type StyleProp, type ViewStyle } from "react-native";
import { useTheme } from "@/ui/theme";

const MAX_PREVIEW_EDGE = 2_048;

export function CapturePreview({ uri, style, onError }: { uri: string; style?: StyleProp<ViewStyle>; onError?: (message?: string) => void }) {
  const theme = useTheme();
  const [errorState, setErrorState] = useState<{ uri: string; message: string }>();
  const error = errorState?.uri === uri ? errorState.message : undefined;
  const image = useImage(uri, {
    maxWidth: MAX_PREVIEW_EDGE,
    maxHeight: MAX_PREVIEW_EDGE,
    onError(reason) {
      const message = reason.message || "The downloaded image could not be decoded.";
      setErrorState({ uri, message });
      onError?.(message);
    },
  }, [uri]);

  return (
    <View style={[styles.frame, { backgroundColor: theme.subtle }, style]}>
      {image ? (
        <Image
          accessibilityLabel="Screenshot captured on the paired Mac"
          source={image}
          contentFit="contain"
          recyclingKey={uri}
          style={StyleSheet.absoluteFill}
        />
      ) : error ? (
        <Text style={[styles.status, { color: theme.secondary }]}>Preview unavailable</Text>
      ) : (
        <View style={styles.loading}>
          <ActivityIndicator color={theme.accent} />
          <Text style={[styles.status, { color: theme.secondary }]}>Preparing preview…</Text>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  frame: { width: "100%", aspectRatio: 16 / 10, borderRadius: 12, overflow: "hidden", alignItems: "center", justifyContent: "center" },
  loading: { alignItems: "center", gap: 8 },
  status: { fontSize: 12, lineHeight: 17 },
});
