export function parseArgument(value: string, description: string): unknown {
  const normalized = value.trim();
  const hint = description.toLowerCase();
  if (hint.includes("boolean")) return normalized.toLowerCase() === "true" || normalized === "1";
  if (hint.includes("array")) return normalized.split(",").map((entry) => entry.trim()).filter(Boolean);
  if (["number", "integer", "seconds", "pixels", "identifier", "pid", "offset", "duration", "0 through", "-1 for"].some((part) => hint.includes(part))) {
    const number = Number(normalized);
    if (Number.isFinite(number)) return number;
  }
  if (normalized.toLowerCase() === "null") return null;
  return normalized;
}
