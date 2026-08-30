import { useColorScheme } from "react-native";

export const palette = {
  ink: "#0B1315",
  night: "#0B1315",
  panel: "#142023",
  border: "rgba(117, 147, 145, 0.18)",
  accent: "#3EB7A5",
  cyan: "#3EB7A5",
  mint: "#73C9A9",
  blue: "#638FA3",
  amber: "#D69B4B",
  red: "#D96666",
  white: "#F4F7F5",
  secondary: "#93A5A3",
};

export function useTheme() {
  const scheme = useColorScheme();
  const dark = scheme === "dark";
  return {
    dark,
    background: dark ? "#0A1113" : "#F2F1EC",
    card: dark ? "#121C1F" : "#FCFBF8",
    elevated: dark ? "#182528" : "#FFFFFF",
    subtle: dark ? "#0F181A" : "#E8EBE6",
    text: dark ? "#F2F5F2" : "#10201F",
    secondary: dark ? "#91A4A1" : "#627572",
    border: dark ? "rgba(155, 187, 181, 0.14)" : "rgba(23, 54, 51, 0.10)",
    accent: palette.accent,
    onAccent: "#071412",
    shadow: dark ? "#000000" : "#394B47",
  };
}
