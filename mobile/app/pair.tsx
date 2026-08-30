import { CameraView, useCameraPermissions } from "expo-camera";
import { router } from "expo-router";
import React, { useState } from "react";
import { ScrollView, Text, TextInput, View } from "react-native";
import { useRemote } from "@/remote/remote-provider";
import { ActionButton, Card } from "@/ui/primitives";
import { palette, useTheme } from "@/ui/theme";

export default function PairScreen() {
  const remote = useRemote();
  const theme = useTheme();
  const [permission, requestPermission] = useCameraPermissions();
  const [pairingURL, setPairingURL] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [scanned, setScanned] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  const pair = async () => {
    setBusy(true);
    setError(undefined);
    try {
      await remote.pair(pairingURL, displayName.trim() || "Mobile member");
      router.dismiss();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Pairing failed.");
      setScanned(false);
    } finally {
      setBusy(false);
    }
  };

  return (
    <ScrollView contentInsetAdjustmentBehavior="automatic" keyboardShouldPersistTaps="handled" contentContainerStyle={{ padding: 18, gap: 18, paddingBottom: 36 }}>
      <Card>
        <Text selectable style={{ color: theme.text, fontSize: 20, fontWeight: "900" }}>Scan the one-time QR</Text>
        <Text selectable style={{ color: theme.secondary, fontSize: 14, lineHeight: 20 }}>Open MacScope on the Mac, then go to Settings → Remote. Pairing links work once and expire after ten minutes.</Text>
      </Card>

      {permission?.granted ? (
        <View style={{ borderRadius: 22, borderCurve: "continuous", overflow: "hidden", aspectRatio: 1, maxHeight: 430 }}>
          <CameraView
            style={{ flex: 1 }}
            barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
            onBarcodeScanned={scanned ? undefined : ({ data }) => {
              setPairingURL(data);
              setScanned(true);
            }}
          />
          <View pointerEvents="none" style={{ position: "absolute", top: 42, right: 42, bottom: 42, left: 42, borderColor: palette.cyan, borderWidth: 3, borderRadius: 24, borderCurve: "continuous" }} />
        </View>
      ) : (
        <ActionButton title="Allow camera access" onPress={() => void requestPermission()} />
      )}

      <Card>
        <Text selectable style={{ color: theme.text, fontSize: 14, fontWeight: "800" }}>Your display name</Text>
        <TextInput value={displayName} onChangeText={setDisplayName} placeholder="Seif's iPhone" placeholderTextColor={theme.secondary} style={{ color: theme.text, backgroundColor: theme.background, borderColor: theme.border, borderWidth: 1, borderRadius: 13, minHeight: 46, paddingHorizontal: 13 }} />
        <Text selectable style={{ color: theme.text, fontSize: 14, fontWeight: "800" }}>Pairing URL</Text>
        <TextInput value={pairingURL} onChangeText={setPairingURL} placeholder="https://…/pair#token=…" placeholderTextColor={theme.secondary} autoCapitalize="none" autoCorrect={false} multiline style={{ color: theme.text, backgroundColor: theme.background, borderColor: theme.border, borderWidth: 1, borderRadius: 13, minHeight: 70, padding: 13, fontSize: 12 }} />
      </Card>
      {error ? <Text selectable style={{ color: palette.red }}>{error}</Text> : null}
      <ActionButton title={busy ? "Pairing…" : "Pair securely"} disabled={busy || !pairingURL.trim()} onPress={() => void pair()} />
    </ScrollView>
  );
}
