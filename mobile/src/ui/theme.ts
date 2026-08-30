import { useColorScheme } from "react-native";

export const palette = {
  ink: "#071018",
  night: "#0B1721",
  panel: "#10232F",
  border: "rgba(132, 206, 223, 0.16)",
  cyan: "#5CE1E6",
  mint: "#8DF0C7",
  blue: "#60A5FA",
  amber: "#F5BE63",
  red: "#FF7D7D",
  white: "#F3F8FA",
  secondary: "#9CB1BB",
};

export function useTheme() {
  const scheme = useColorScheme();
  const dark = scheme !== "light";
  return {
    dark,
    background: dark ? palette.ink : "#EEF4F5",
    card: dark ? palette.panel : "#FFFFFF",
    text: dark ? palette.white : "#10212A",
    secondary: dark ? palette.secondary : "#5D717A",
    border: dark ? palette.border : "rgba(16, 33, 42, 0.10)",
  };
}
