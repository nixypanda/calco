import { describe, expect, it } from "vitest";
import {
  parseAmount,
  getNutrientAmount,
  getCalories,
  getNutrientVal,
  getMacroTotals,
  computeGrams,
  scaleNutrients,
  parseCategoriesInput,
  formatCategoriesInput,
  createEmptyRow,
  nextRowId,
} from "@/lib/nutrition";

describe("parseAmount", () => {
  it("parses numeric strings", () => {
    expect(parseAmount("12.5")).toBe(12.5);
  });
  it("returns 0 for negatives", () => {
    expect(parseAmount("-1")).toBe(0);
  });
  it("returns 0 for non-numeric", () => {
    expect(parseAmount("abc")).toBe(0);
  });
  it("returns 0 for empty", () => {
    expect(parseAmount("")).toBe(0);
  });
});

describe("getNutrientAmount / getCalories", () => {
  const nutrients = [
    { code: "ENERGY_KCAL", amount: "250" },
    { code: "PROTEIN_G", amount: "10" },
  ];
  it("returns parsed value when present", () => {
    expect(getNutrientAmount(nutrients, "PROTEIN_G")).toBe(10);
  });
  it("returns 0 when missing", () => {
    expect(getNutrientAmount(nutrients, "FAT_G")).toBe(0);
  });
  it("getCalories pulls ENERGY_KCAL", () => {
    expect(getCalories(nutrients)).toBe(250);
  });
});

describe("getNutrientVal", () => {
  const entries = [{ code: "PROTEIN_G", amount: "20", unit: "g" }];
  it("returns amount and unit", () => {
    expect(getNutrientVal(entries, "PROTEIN_G")).toEqual({
      amount: 20,
      unit: "g",
    });
  });
  it("returns null when missing", () => {
    expect(getNutrientVal(entries, "FAT_G")).toBeNull();
  });
});

describe("getMacroTotals", () => {
  it("sums macros and computes percentages by kcal contribution", () => {
    const logs = [
      {
        nutrients: [
          { code: "PROTEIN_G", amount: "10" },
          { code: "CARBS_G", amount: "20" },
          { code: "FAT_G", amount: "5" },
        ],
      },
      {
        nutrients: [
          { code: "PROTEIN_G", amount: "10" },
          { code: "CARBS_G", amount: "10" },
          { code: "FAT_G", amount: "5" },
        ],
      },
    ];
    const m = getMacroTotals(logs);
    expect(m.protein).toBe(20);
    expect(m.carbs).toBe(30);
    expect(m.fat).toBe(10);
    // total kcal = 20*4 + 30*4 + 10*9 = 80 + 120 + 90 = 290
    expect(m.proteinPct).toBeCloseTo((80 / 290) * 100);
    expect(m.carbsPct).toBeCloseTo((120 / 290) * 100);
    expect(m.fatPct).toBeCloseTo((90 / 290) * 100);
  });
  it("returns 0% when no macros", () => {
    const m = getMacroTotals([]);
    expect(m.proteinPct).toBe(0);
    expect(m.carbsPct).toBe(0);
    expect(m.fatPct).toBe(0);
  });
});

describe("computeGrams", () => {
  const servings = [
    { label: "scoop", quantity: "1", unit: "scoop", grams: "30" },
    { label: "cup", quantity: "1", unit: "cup", grams: "240" },
  ];
  it("returns amount when unit is grams", () => {
    expect(computeGrams(50, "g", servings)).toBe(50);
    expect(computeGrams(50, "G", servings)).toBe(50);
    expect(computeGrams(50, "grams", servings)).toBe(50);
  });
  it("uses serving conversion when unit matches", () => {
    expect(computeGrams(2, "scoop", servings)).toBe(60);
  });
  it("returns null for unknown unit", () => {
    expect(computeGrams(1, "fl_oz", servings)).toBeNull();
  });
  it("returns null for negative amounts", () => {
    expect(computeGrams(-1, "g", servings)).toBeNull();
  });
  it("returns null when serving has bad quantity", () => {
    expect(
      computeGrams(1, "bad", [
        { label: "x", quantity: "0", unit: "bad", grams: "10" },
      ]),
    ).toBeNull();
  });
});

describe("scaleNutrients", () => {
  const per100g = [
    {
      code: "ENERGY_KCAL",
      amount_per_100g: "100",
      unit: "kcal",
      source: null,
      confidence: null,
    },
    {
      code: "PROTEIN_G",
      amount_per_100g: "5",
      unit: "g",
      source: null,
      confidence: null,
    },
  ];
  it("scales by gram amount", () => {
    const result = scaleNutrients(per100g, 200, "g", []);
    expect(result).toEqual([
      { code: "ENERGY_KCAL", amount: 200, unit: "kcal" },
      { code: "PROTEIN_G", amount: 10, unit: "g" },
    ]);
  });
  it("falls back to 1x factor when grams cannot be computed", () => {
    const result = scaleNutrients(per100g, 1, "unknown", []);
    expect(result[0].amount).toBe(100);
  });
});

describe("parseCategoriesInput", () => {
  it("splits, trims, lowercases, dedupes", () => {
    expect(parseCategoriesInput("Fruit, Snack ,fruit, ")).toEqual([
      "fruit",
      "snack",
    ]);
  });
  it("returns empty on empty input", () => {
    expect(parseCategoriesInput("")).toEqual([]);
  });
});

describe("formatCategoriesInput", () => {
  it("joins with ', '", () => {
    expect(formatCategoriesInput(["a", "b"])).toBe("a, b");
  });
});

describe("nextRowId / createEmptyRow", () => {
  it("returns monotonically distinct ids", () => {
    const a = nextRowId();
    const b = nextRowId();
    expect(a).not.toBe(b);
    expect(a).toMatch(/^row-\d+$/);
  });
  it("createEmptyRow returns sane defaults", () => {
    const r = createEmptyRow();
    expect(r.quantity).toBe("100");
    expect(r.unit).toBe("g");
    expect(r.productId).toBe("");
    expect(r.searchResults).toEqual([]);
    expect(r.searching).toBe(false);
    expect(r.rowId).toMatch(/^row-\d+$/);
  });
});
