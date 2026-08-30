import type { UtilityAction } from "./types";

export function utilityMatchesQuery(action: UtilityAction, query: string): boolean {
  const terms = query.trim().toLocaleLowerCase().split(/\s+/u).filter(Boolean);
  if (!terms.length) return true;
  const searchable = `${action.title} ${action.summary} ${action.module} ${action.id}`.toLocaleLowerCase();
  return terms.every((term) => searchable.includes(term));
}
