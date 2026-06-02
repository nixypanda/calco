import type { NutrientEntry, ServingEntry } from "@/api/foods";

export const MEAL_SLOTS = [
  { value: "breakfast", label: "Breakfast" },
  { value: "lunch", label: "Lunch" },
  { value: "dinner", label: "Dinner" },
  { value: "snack", label: "Snack" },
] as const;

export const MACRO_COLORS = {
  calories: "var(--mantine-color-red-6)",
  protein: "var(--mantine-color-blue-6)",
  carbs: "var(--mantine-color-orange-6)",
  fat: "var(--mantine-color-yellow-6)",
} as const;

export const SUMMARY_CODES = "ENERGY_KCAL,PROTEIN_G,CARBS_G,FAT_G";

export const DEFAULT_CALORIE_GOAL = 2000;

export const UNITS = [
  "g",
  "kg",
  "ml",
  "cup",
  "tbsp",
  "tsp",
  "piece",
  "packet",
  "serving",
];

export interface ScaledNutrient {
  code: string;
  amount: number;
  unit: string;
}

export interface NutrientRow {
  code: string;
  amount_per_100g: string;
}

export interface ServingRow {
  label: string;
  quantity: string;
  unit: string;
  grams: string;
}

export interface ComponentRow {
  rowId: string;
  productId: string;
  productName: string;
  quantity: string;
  unit: string;
  searchQuery: string;
  searchResults: import("@/api/foods").SearchResult[];
  searching: boolean;
}

export function parseAmount(val: string): number {
  const n = parseFloat(val);
  if (!isFinite(n) || n < 0) return 0;
  return n;
}

export function getNutrientAmount(
  nutrients: { code: string; amount: string }[],
  code: string,
): number {
  const entry = nutrients.find((n) => n.code === code);
  return entry ? parseAmount(entry.amount) : 0;
}

export function getCalories(
  nutrients: { code: string; amount: string }[],
): number {
  return getNutrientAmount(nutrients, "ENERGY_KCAL");
}

export function getNutrientVal(
  entries: { code: string; amount: string; unit: string }[],
  code: string,
): { amount: number; unit: string } | null {
  const entry = entries.find((n) => n.code === code);
  return entry ? { amount: parseAmount(entry.amount), unit: entry.unit } : null;
}

export function getMacroTotals(
  logs: { nutrients: { code: string; amount: string }[] }[],
) {
  const protein = logs.reduce(
    (s, l) => s + getNutrientAmount(l.nutrients, "PROTEIN_G"),
    0,
  );
  const carbs = logs.reduce(
    (s, l) => s + getNutrientAmount(l.nutrients, "CARBS_G"),
    0,
  );
  const fat = logs.reduce(
    (s, l) => s + getNutrientAmount(l.nutrients, "FAT_G"),
    0,
  );
  const total = protein * 4 + carbs * 4 + fat * 9;
  const pct = (kcal: number) => (total > 0 ? (kcal / total) * 100 : 0);
  return {
    protein,
    carbs,
    fat,
    proteinPct: pct(protein * 4),
    carbsPct: pct(carbs * 4),
    fatPct: pct(fat * 9),
  };
}

export function computeGrams(
  amount: number,
  unit: string,
  servings: ServingEntry[],
): number | null {
  if (!isFinite(amount) || amount < 0) return null;
  const u = unit.toLowerCase();
  if (u === "g" || u === "gram" || u === "grams") return amount;
  const match = servings.find((s) => s.unit.toLowerCase() === u);
  if (!match) return null;
  const q = parseFloat(match.quantity);
  const g = parseFloat(match.grams);
  if (!isFinite(q) || q <= 0 || !isFinite(g)) return null;
  return amount * (g / q);
}

export function scaleNutrients(
  per100g: NutrientEntry[],
  amount: number,
  unit: string,
  servings: ServingEntry[],
): ScaledNutrient[] {
  const grams = computeGrams(amount, unit, servings);
  const factor = grams != null ? grams / 100 : 1;
  return per100g.map((n) => ({
    code: n.code,
    unit: n.unit,
    amount: (parseFloat(n.amount_per_100g) || 0) * factor,
  }));
}

export function parseCategoriesInput(value: string): string[] {
  const categories: string[] = [];
  for (const raw of value.split(",")) {
    const normalized = raw.trim().toLowerCase();
    if (normalized && !categories.includes(normalized)) {
      categories.push(normalized);
    }
  }
  return categories;
}

export function formatCategoriesInput(categories: string[]): string {
  return categories.join(", ");
}

let rowIdCounter = 0;
export function nextRowId(): string {
  rowIdCounter += 1;
  return `row-${rowIdCounter}`;
}

export function createEmptyRow(): ComponentRow {
  return {
    rowId: nextRowId(),
    productId: "",
    productName: "",
    quantity: "100",
    unit: "g",
    searchQuery: "",
    searchResults: [],
    searching: false,
  };
}
