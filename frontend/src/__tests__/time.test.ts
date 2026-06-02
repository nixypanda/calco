import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  displayDate,
  formatDate,
  formatTimestamp,
  localISOString,
  todayString,
} from "@/lib/time";

describe("localISOString", () => {
  it("formats with timezone offset and zero-pads", () => {
    const d = new Date(2024, 0, 5, 9, 8, 7); // local time Jan 5 2024 09:08:07
    const out = localISOString(d);
    expect(out).toMatch(/^2024-01-05T09:08:07[+-]\d{2}:\d{2}$/);
  });

  it("uses + sign for non-negative offsets and - for negative", () => {
    const d = new Date(2024, 0, 5, 9, 8, 7);
    const sign = -d.getTimezoneOffset() >= 0 ? "+" : "-";
    expect(localISOString(d)).toContain(sign);
  });
});

describe("formatDate", () => {
  it("zero-pads month and day", () => {
    expect(formatDate(new Date(2024, 0, 3))).toBe("2024-01-03");
  });
  it("handles double-digit values", () => {
    expect(formatDate(new Date(2024, 11, 31))).toBe("2024-12-31");
  });
});

describe("displayDate", () => {
  it("returns a non-empty locale-formatted string", () => {
    const out = displayDate(new Date(2024, 0, 3));
    expect(out).toContain("Jan");
    expect(out).toContain("3");
  });
});

describe("todayString", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });
  it("returns today in YYYY-MM-DD local format", () => {
    vi.setSystemTime(new Date(2024, 5, 15, 10, 0, 0));
    expect(todayString()).toBe("2024-06-15");
  });
});

describe("formatTimestamp", () => {
  it("renders weekday/month/day/time", () => {
    const out = formatTimestamp(new Date(2024, 0, 3, 14, 30, 0).toISOString());
    expect(out).toMatch(/Jan/);
    expect(out).toMatch(/3/);
  });
});
