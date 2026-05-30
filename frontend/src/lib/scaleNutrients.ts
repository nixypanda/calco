import type { NutrientEntry, ServingEntry } from "@/api/foods";

export interface ScaledNutrient {
  code: string;
  amount: number;
  unit: string;
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
