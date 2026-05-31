import type { UnitItem } from "@/api/foods";

const BUILTIN_GRAM_UNITS = ["g", "kg"] as const;

export function buildAllowedUnitCodes(
  extras: Iterable<string | null | undefined>,
): Set<string> {
  const codes = new Set<string>(BUILTIN_GRAM_UNITS);
  for (const e of extras) {
    if (e) codes.add(e);
  }
  return codes;
}

export function filterUnits(
  units: UnitItem[],
  allowed: Set<string>,
  keepCurrent?: string,
): UnitItem[] {
  const filtered = units.filter((u) => allowed.has(u.code));
  if (keepCurrent && !filtered.some((u) => u.code === keepCurrent)) {
    return [{ code: keepCurrent, name: keepCurrent, kind: "" }, ...filtered];
  }
  return filtered;
}
