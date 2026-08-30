import type { UtilityAction } from "./types";

export type ArgumentValue = string | boolean;
export type ArgumentKind = "boolean" | "number" | "choice" | "text" | "multiline" | "array";

export interface ArgumentOption { value: string; label: string; detail?: string }

export interface ArgumentField {
  name: string;
  label: string;
  question: string;
  description: string;
  kind: ArgumentKind;
  optional: boolean;
  nullable: boolean;
  numeric: boolean;
  min?: number;
  max?: number;
  exclusiveMin?: boolean;
  step?: number;
  options: ArgumentOption[];
  initialValue: ArgumentValue;
}

const fixedOptions: Record<string, ArgumentOption[]> = {
  "capture.screenshot:mode": options(["full_screen", "window", "selection"]),
  "windows.arrange:placement": options(["maximize", "center", "left_half", "right_half", "top_half", "bottom_half", "top_left", "top_right", "bottom_left", "bottom_right", "left_third", "center_third", "right_third"]),
  "windows.move-display:offset": [{ value: "-1", label: "Previous display" }, { value: "1", label: "Next display" }],
  "windows.set-input-feature:feature": options(["keyboard_debounce", "focus_follows_mouse", "super_key", "smooth_scrolling", "plain_text_paste", "finder_shortcuts"]),
  "maintenance.media-convert-images:format": options(["png", "jpeg"]),
};

const fieldOrder: Record<string, string[]> = {
  "capture.screenshot": ["mode", "delay_seconds", "copy_to_clipboard"],
  "capture.scrolling-screenshot": ["steps", "overlap_pixels", "copy_to_clipboard"],
  "capture.recording-start": ["source_id", "system_audio", "microphone"],
  "clipboard.add-snippet": ["title", "text", "trigger", "folder"],
  "clipboard.set-clear-events": ["system_sleep", "display_sleep", "screen_lock"],
};

export function fieldsForAction(action: UtilityAction, utilityState?: unknown): ArgumentField[] {
  return Object.entries(action.arguments).sort(([left], [right]) => {
    const order = fieldOrder[action.id] ?? [];
    const leftIndex = order.indexOf(left);
    const rightIndex = order.indexOf(right);
    return (leftIndex < 0 ? Number.MAX_SAFE_INTEGER : leftIndex) - (rightIndex < 0 ? Number.MAX_SAFE_INTEGER : rightIndex);
  }).map(([name, description]) => {
    const lower = description.toLowerCase();
    const optional = lower.includes("optional") || lower.includes("or null") || lower.includes("omit for") || lower.includes("to cancel") || lower.includes("to disable");
    const nullable = lower.includes("null") || lower.includes("turn it off");
    const range = numericRange(description);
    const liveOptions = optionsFromState(action, name, utilityState);
    const availableChoices = liveOptions.length ? liveOptions : fixedOptions[`${action.id}:${name}`] ?? [];
    const choices = optional && availableChoices.length && availableChoices[0]?.value !== ""
      ? [{ value: "", label: "Use current or default" }, ...availableChoices]
      : availableChoices;
    const numeric = Boolean(range) || lower.includes("number") || lower.includes("seconds") || lower.includes("hours") || lower.includes("pixels") || name === "pid" || name === "display_id" || name === "offset" || lower.includes("interval") || lower.includes("duration") || lower.includes("overlap");
    const kind: ArgumentKind = lower.includes("boolean") || lower.includes("desired installed state")
      ? "boolean"
      : choices.length ? "choice"
        : lower.includes("array") ? "array"
          : lower.includes("text") || name === "watermark" || name === "query" || name === "name" || name === "title" || name === "trigger" || name === "folder"
            ? (name === "text" ? "multiline" : "text")
            : numeric
              ? "number"
              : "text";
    return {
      name,
      label: fieldLabel(name),
      question: questionFor(name, action.title),
      description,
      kind,
      optional,
      nullable,
      numeric,
      min: range?.min,
      max: range?.max,
      exclusiveMin: range?.exclusiveMin,
      step: range ? sensibleStep(range.min, range.max) : undefined,
      options: choices,
      initialValue: initialValue(action.id, name, kind, choices, range, optional),
    };
  });
}

export function serializeArguments(fields: ArgumentField[], values: Record<string, ArgumentValue>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const field of fields) {
    const value = values[field.name] ?? field.initialValue;
    if (field.kind === "boolean") {
      if (field.optional && value === "") continue;
      result[field.name] = value === true || value === "true";
      continue;
    }
    const text = String(value).trim();
    if (!text) {
      if (!field.optional) throw new Error(`Choose or enter ${field.label.toLowerCase()}.`);
      continue;
    }
    if (field.nullable && text === "null") {
      result[field.name] = null;
      continue;
    }
    if (field.kind === "number" || (field.kind === "choice" && field.numeric)) {
      const number = Number(text);
      if (!Number.isFinite(number)) throw new Error(`${field.label} must be a number.`);
      if (field.exclusiveMin && number <= 0) throw new Error(`${field.label} must be greater than 0.`);
      if (field.min != null && number < field.min) throw new Error(`${field.label} must be at least ${field.min}.`);
      if (field.max != null && number > field.max) throw new Error(`${field.label} must be at most ${field.max}.`);
      result[field.name] = number;
    } else if (field.kind === "array") {
      const items = text.split(/\n|,/u).map((item) => item.trim()).filter(Boolean);
      if (!items.length && !field.optional) throw new Error(`Add at least one ${field.label.toLowerCase()}.`);
      result[field.name] = items;
    } else {
      result[field.name] = text === "null" && field.optional ? null : text;
    }
  }
  return result;
}

function optionsFromState(action: UtilityAction, name: string, state: unknown): ArgumentOption[] {
  const root = object(state);
  if (!root) return [];
  if (name === "pid") {
    const list = action.module === "sound" ? array(root.applications) : array(root.applications);
    return list.flatMap((item) => optionFromObject(item, "pid", "name"));
  }
  if (name === "device_uid") {
    const list = action.id.includes("input") ? array(root.inputs) : array(root.outputs);
    const values = list.flatMap((item) => optionFromObject(item, "uid", "name"));
    return action.id === "sound.set-app-output" ? [{ value: "null", label: "Use system output" }, ...values] : values;
  }
  if (name === "source_id") return array(object(root.recording)?.sources).flatMap((item) => optionFromObject(item, "id", "name"));
  if (name === "device_id" && action.id === "capture.camera-start") return array(object(root.camera)?.devices).flatMap((item) => optionFromObject(item, "id", "name"));
  if (name === "display_id") {
    const list = action.id.includes("software") ? array(root.software_displays) : array(root.hardware_displays);
    return list.flatMap((item) => optionFromObject(item, "id", "name"));
  }
  if (name === "id" && action.module === "notes") return array(root.pads).flatMap((item) => optionFromObject(item, "id", "name"));
  if (name === "id" && action.id === "clipboard.delete-snippet") return array(root.snippets).flatMap((item) => optionFromObject(item, "id", "title"));
  if (name === "id" && action.id === "clipboard.remove-shelf-text") return array(root.shelf_text).flatMap((item) => optionFromObject(item, "id", "text"));
  if (name === "path" && action.id === "clipboard.remove-shelf-file") return array(root.shelf_files).flatMap((item) => optionFromObject(item, "path", "name"));
  if (name === "id" && action.id === "maintenance.upgrade-homebrew") return array(root.homebrew_outdated).flatMap((item) => optionFromObject(item, "id", "name"));
  if (name === "id" && action.id === "maintenance.set-homebrew-installed") return array(root.homebrew_search).flatMap((item) => optionFromObject(item, "id", "name"));
  return [];
}

function numericRange(description: string): { min?: number; max?: number; exclusiveMin?: boolean } | undefined {
  const match = description.match(/(-?\d+(?:\.\d+)?)\s+(?:through|to)\s+(-?\d+(?:\.\d+)?)/iu);
  if (match) return { min: Number(match[1]), max: Number(match[2]) };
  if (/\bnon-negative\b/iu.test(description)) return { min: 0 };
  if (/\bpositive\b/iu.test(description)) return { exclusiveMin: true };
  return undefined;
}

function initialValue(actionID: string, name: string, kind: ArgumentKind, choices: ArgumentOption[], range: { min?: number; max?: number; exclusiveMin?: boolean } | undefined, optional: boolean): ArgumentValue {
  if (kind === "boolean") return optional ? "" : false;
  if (actionID === "capture.screenshot" && name === "delay_seconds") return "0";
  if (optional) return "";
  if (choices.length) return choices[0]?.value ?? "";
  if (range?.min != null) return String(range.min);
  return "";
}

function sensibleStep(min?: number, max?: number): number {
  if (min == null || max == null) return 1;
  const precision = Math.max(decimalPlaces(min), decimalPlaces(max));
  return precision ? 10 ** -Math.min(precision, 3) : 1;
}

function decimalPlaces(value: number): number { return String(value).split(".")[1]?.length ?? 0; }

function questionFor(name: string, actionTitle: string): string {
  const known: Record<string, string> = {
    enabled: "Should this be enabled?",
    mode: "What should the Mac capture?",
    copy_to_clipboard: "Also copy it to the Mac clipboard?",
    delay_seconds: "Wait before starting?",
    pid: "Which running application?",
    device_uid: "Which audio device?",
    source_id: "Which screen or window?",
    text: "What text should be used?",
    paths: "Which paths on the Mac?",
    duration_seconds: "How long should it run?",
    include_display: "Keep the display awake too?",
    display_id: "Which display?",
    value: "What value should be applied?",
  };
  return known[name] ?? `${fieldLabel(name)} for ${actionTitle.toLowerCase()}?`;
}

export function fieldLabel(name: string): string {
  const labels: Record<string, string> = {
    pid: "Application",
    device_uid: "Audio device",
    source_id: "Recording source",
    display_id: "Display",
    copy_to_clipboard: "Copy to clipboard",
    delay_seconds: "Delay",
    duration_seconds: "Duration",
    interval_ms: "Interval",
    delay_ms: "Delay",
    overlap_pixels: "Overlap",
    include_display: "Keep display awake",
    system_audio: "System audio",
    app_store: "App Store",
    on_ac_power: "On AC power",
    with_external_display: "With external display",
  };
  return labels[name] ?? name.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ");
}

function options(values: string[]): ArgumentOption[] {
  const friendly: Record<string, string> = {
    full_screen: "Entire screen", window: "One window", selection: "Selected area",
    left_half: "Left half", right_half: "Right half", top_half: "Top half", bottom_half: "Bottom half",
    top_left: "Top left", top_right: "Top right", bottom_left: "Bottom left", bottom_right: "Bottom right",
    left_third: "Left third", center_third: "Center third", right_third: "Right third",
    keyboard_debounce: "Keyboard debounce", focus_follows_mouse: "Focus follows pointer", super_key: "Super key",
    smooth_scrolling: "Smooth scrolling", plain_text_paste: "Paste as plain text", finder_shortcuts: "Finder shortcuts",
    jpeg: "JPEG", png: "PNG",
  };
  return values.map((value) => ({ value, label: friendly[value] ?? fieldLabel(value) }));
}

function object(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

function array(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.map(object).filter((item): item is Record<string, unknown> => Boolean(item)) : [];
}

function optionFromObject(value: Record<string, unknown>, idKey: string, labelKey: string): ArgumentOption[] {
  const id = value[idKey];
  const label = value[labelKey];
  if ((typeof id !== "string" && typeof id !== "number") || (typeof label !== "string" && typeof label !== "number")) return [];
  return [{ value: String(id), label: String(label) }];
}
