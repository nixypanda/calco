import { describe, expect, it } from "vitest";
import type { LogResponse, SummaryEntry } from "../api/logs";
import { formatDate } from "../lib/time";
import { type DiaryModel, diaryReducer } from "../pages/Diary";

const mockLogItem: LogResponse = {
  id: "log-1",
  logged_at: "2026-05-30T12:00:00Z",
  meal_slot: "lunch",
  item: { type: "product", id: "food-1" },
  quantity: { amount: "150", unit: "g" },
  nutrients: [
    { code: "ENERGY_KCAL", amount: "247.5", unit: "kcal" },
    { code: "PROTEIN_G", amount: "46.5", unit: "g" },
    { code: "CARBS_G", amount: "0", unit: "g" },
    { code: "FAT_G", amount: "3.5", unit: "g" },
  ],
  notes: null,
};

const mockSummary: SummaryEntry[] = [
  { code: "ENERGY_KCAL", amount: "247.5", unit: "kcal" },
  { code: "PROTEIN_G", amount: "46.5", unit: "g" },
  { code: "CARBS_G", amount: "0", unit: "g" },
  { code: "FAT_G", amount: "3.5", unit: "g" },
];

function todayAtMidnight(): Date {
  const date = new Date();
  date.setHours(0, 0, 0, 0);
  return date;
}

function createDiaryModel(overrides: Partial<DiaryModel> = {}): DiaryModel {
  return {
    currentDate: new Date("2026-05-30T00:00:00"),
    logs: [],
    summary: [],
    foodNames: {},
    loading: false,
    error: "",
    macroMode: "grams",
    darkMode: false,
    ...overrides,
  };
}

describe("diaryReducer", () => {
  it("moves to the previous day", () => {
    const next = diaryReducer(createDiaryModel(), { type: "date/previous" });

    expect(formatDate(next.currentDate)).toBe("2026-05-29");
  });

  it("moves to the next day when it is not in the future", () => {
    const next = diaryReducer(createDiaryModel(), { type: "date/next" });

    expect(formatDate(next.currentDate)).toBe("2026-05-31");
  });

  it("does not move past today", () => {
    const model = createDiaryModel({ currentDate: todayAtMidnight() });

    const next = diaryReducer(model, { type: "date/next" });

    expect(next.currentDate).toEqual(model.currentDate);
  });

  it("starts diary loading and clears stale errors", () => {
    const next = diaryReducer(createDiaryModel({ error: "Old error" }), {
      type: "diary/loadStarted",
    });

    expect(next.loading).toBe(true);
    expect(next.error).toBe("");
  });

  it("keeps existing diary data while a reload starts", () => {
    const model = createDiaryModel({
      logs: [mockLogItem],
      summary: mockSummary,
      foodNames: { "food-1": "Chicken Breast" },
    });

    const next = diaryReducer(model, { type: "diary/loadStarted" });

    expect(next.logs).toEqual(model.logs);
    expect(next.summary).toEqual(model.summary);
    expect(next.foodNames).toEqual(model.foodNames);
  });

  it("stores loaded diary data", () => {
    const next = diaryReducer(createDiaryModel({ loading: true }), {
      type: "diary/loadSucceeded",
      logs: [mockLogItem],
      summary: mockSummary,
      foodNames: { "food-1": "Chicken Breast" },
    });

    expect(next.loading).toBe(false);
    expect(next.logs).toEqual([mockLogItem]);
    expect(next.summary).toEqual(mockSummary);
    expect(next.foodNames).toEqual({ "food-1": "Chicken Breast" });
  });

  it("stores diary loading errors without clearing existing data", () => {
    const model = createDiaryModel({
      loading: true,
      logs: [mockLogItem],
      summary: mockSummary,
      foodNames: { "food-1": "Chicken Breast" },
    });

    const next = diaryReducer(model, {
      type: "diary/loadFailed",
      error: "Network error",
    });

    expect(next.loading).toBe(false);
    expect(next.error).toBe("Network error");
    expect(next.logs).toEqual(model.logs);
    expect(next.summary).toEqual(model.summary);
    expect(next.foodNames).toEqual(model.foodNames);
  });

  it("toggles macro display mode", () => {
    const percent = diaryReducer(createDiaryModel(), {
      type: "macroMode/toggled",
    });
    const grams = diaryReducer(percent, { type: "macroMode/toggled" });

    expect(percent.macroMode).toBe("percent");
    expect(grams.macroMode).toBe("grams");
  });

  it("toggles theme mode", () => {
    const dark = diaryReducer(createDiaryModel(), { type: "theme/toggled" });
    const light = diaryReducer(dark, { type: "theme/toggled" });

    expect(dark.darkMode).toBe(true);
    expect(light.darkMode).toBe(false);
  });
});
