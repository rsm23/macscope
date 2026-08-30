export const palette = {
  ink: "#06090D",
  night: "#090D13",
  panel: "#111821",
  border: "rgba(148, 163, 184, 0.16)",
  accent: "#63E6BE",
  cyan: "#50D7E8",
  mint: "#63E6BE",
  blue: "#7AA2F7",
  amber: "#F3B95F",
  red: "#FF7373",
  white: "#F5F7FA",
  secondary: "#8F9AAA",
};

export function useTheme() {
  return {
    dark: true,
    background: "#080C12",
    card: "#101720",
    elevated: "#17212C",
    subtle: "#0C121A",
    text: "#F3F6FA",
    secondary: "#8F9AAA",
    border: "rgba(148, 163, 184, 0.14)",
    accent: palette.accent,
    onAccent: "#06110E",
    shadow: "#000000",
  };
}
