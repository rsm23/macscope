export interface RemoteApplication {
  id: string;
  name: string;
  bundleIdentifier?: string;
  pid?: number;
  running: boolean;
  active: boolean;
  hidden: boolean;
}

export interface ApplicationSection {
  key: "running" | "installed";
  title: string;
  detail: string;
  data: RemoteApplication[];
}

export const FINDER_BUNDLE_IDENTIFIER = "com.apple.finder";

export function canQuitApplication(value: RemoteApplication): boolean {
  return value.running && Boolean(value.pid) && Boolean(value.bundleIdentifier)
    && value.bundleIdentifier?.toLocaleLowerCase() !== FINDER_BUNDLE_IDENTIFIER;
}

export function applicationsFromWindowsState(state: unknown): RemoteApplication[] {
  const root = object(state);
  const byID = new Map<string, RemoteApplication>();

  for (const value of array(root?.installed_applications)) {
    const bundleIdentifier = string(value.bundle_identifier);
    const name = string(value.name);
    if (!bundleIdentifier || !name) continue;
    byID.set(`bundle:${bundleIdentifier}`, {
      id: `bundle:${bundleIdentifier}`,
      name,
      bundleIdentifier,
      running: false,
      active: false,
      hidden: false,
    });
  }

  for (const value of array(root?.applications)) {
    const pid = number(value.pid);
    const name = string(value.name);
    if (!pid || !name) continue;
    const bundleIdentifier = string(value.bundle_identifier) || undefined;
    const id = bundleIdentifier ? `bundle:${bundleIdentifier}` : `pid:${pid}`;
    byID.set(id, {
      id,
      name,
      bundleIdentifier,
      pid,
      running: true,
      active: value.active === true,
      hidden: value.hidden === true,
    });
  }

  return [...byID.values()].sort((left, right) => {
    if (left.running !== right.running) return left.running ? -1 : 1;
    if (left.active !== right.active) return left.active ? -1 : 1;
    return left.name.localeCompare(right.name, undefined, { sensitivity: "base" });
  });
}

export function filterApplications(values: RemoteApplication[], query: string): RemoteApplication[] {
  const terms = query.trim().toLocaleLowerCase().split(/\s+/u).filter(Boolean);
  if (!terms.length) return values;
  return values.filter((value) => {
    const searchable = `${value.name} ${value.bundleIdentifier ?? ""} ${value.pid ?? ""}`.toLocaleLowerCase();
    return terms.every((term) => searchable.includes(term));
  });
}

export function applicationSections(values: RemoteApplication[], query: string): ApplicationSection[] {
  const filtered = filterApplications(values, query);
  const running = filtered.filter((value) => value.running);
  const installed = filtered.filter((value) => !value.running);
  return [
    { key: "running", title: "Running now", detail: `${running.length} active on this Mac`, data: running },
    { key: "installed", title: "Installed apps", detail: `${installed.length} available to launch`, data: installed },
  ];
}

function object(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

function array(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.map(object).filter((item): item is Record<string, unknown> => Boolean(item)) : [];
}

function string(value: unknown): string { return typeof value === "string" ? value : ""; }
function number(value: unknown): number | undefined { return typeof value === "number" && Number.isFinite(value) ? value : undefined; }
