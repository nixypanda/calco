import { describe, it, expect, vi, beforeEach } from "vitest";
import { createLog, getLog, listLogs, updateLog, deleteLog, getSummary } from "../api/logs";
import { apiRequest } from "../api/client";

vi.mock("../api/client", () => ({
  apiRequest: vi.fn(),
}));

describe("Logs API", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("createLog calls apiRequest with POST", async () => {
    const data = {
      logged_at: "2026-05-30T12:00:00Z",
      meal_slot: "lunch",
      item: { type: "product", id: "food-1" },
      quantity: { amount: "150", unit: "g" },
    };
    vi.mocked(apiRequest).mockResolvedValue({ id: "log-1" });

    const result = await createLog(data);

    expect(apiRequest).toHaveBeenCalledWith("/api/logs", {
      method: "POST",
      body: JSON.stringify(data),
    });
    expect(result).toEqual({ id: "log-1" });
  });

  it("getLog calls apiRequest with GET", async () => {
    vi.mocked(apiRequest).mockResolvedValue({ id: "log-1" });

    const result = await getLog("log-1");

    expect(apiRequest).toHaveBeenCalledWith("/api/logs/log-1");
    expect(result).toEqual({ id: "log-1" });
  });

  it("listLogs calls apiRequest with query params", async () => {
    vi.mocked(apiRequest).mockResolvedValue({ from: "2026-05-30", to: "2026-05-30", items: [] });

    const result = await listLogs("2026-05-30", "2026-05-30");

    expect(apiRequest).toHaveBeenCalledWith(
      "/api/logs?from=2026-05-30&to=2026-05-30",
    );
    expect(result.items).toEqual([]);
  });

  it("updateLog calls apiRequest with PUT", async () => {
    const data = { quantity: { amount: "200", unit: "g" } };
    vi.mocked(apiRequest).mockResolvedValue({ id: "log-1" });

    const result = await updateLog("log-1", data);

    expect(apiRequest).toHaveBeenCalledWith("/api/logs/log-1", {
      method: "PUT",
      body: JSON.stringify(data),
    });
    expect(result).toEqual({ id: "log-1" });
  });

  it("deleteLog calls apiRequest with DELETE", async () => {
    vi.mocked(apiRequest).mockResolvedValue(undefined);

    await deleteLog("log-1");

    expect(apiRequest).toHaveBeenCalledWith("/api/logs/log-1", {
      method: "DELETE",
    });
  });

  it("getSummary calls apiRequest with query params and codes", async () => {
    vi.mocked(apiRequest).mockResolvedValue({ from: "2026-05-30", to: "2026-05-30", totals: [] });

    const result = await getSummary("2026-05-30", "2026-05-30", "ENERGY_KCAL,PROTEIN_G");

    expect(apiRequest).toHaveBeenCalledWith(
      "/api/summary?from=2026-05-30&to=2026-05-30&codes=ENERGY_KCAL%2CPROTEIN_G",
    );
    expect(result.totals).toEqual([]);
  });

  it("getSummary calls without optional codes", async () => {
    vi.mocked(apiRequest).mockResolvedValue({ from: "2026-05-30", to: "2026-05-30", totals: [] });

    await getSummary("2026-05-30", "2026-05-30");

    expect(apiRequest).toHaveBeenCalledWith(
      "/api/summary?from=2026-05-30&to=2026-05-30",
    );
  });
});
