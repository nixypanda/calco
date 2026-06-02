import { beforeEach, describe, expect, it, vi } from "vitest";
import { type ApiError, apiRequest } from "../api/client";

describe("apiRequest", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("returns undefined for 204 responses", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      status: 204,
      text: vi.fn(),
    } as unknown as Response);

    await expect(
      apiRequest<void>("/api/logs/1", { method: "DELETE" }),
    ).resolves.toBeUndefined();
  });

  it("returns undefined for empty success bodies", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      status: 200,
      text: vi.fn().mockResolvedValue(""),
    } as unknown as Response);

    await expect(
      apiRequest<void>("/api/auth/logout", { method: "POST" }),
    ).resolves.toBeUndefined();
  });

  it("parses JSON success bodies", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      status: 200,
      text: vi.fn().mockResolvedValue('{"id":"log-1"}'),
    } as unknown as Response);

    await expect(
      apiRequest<{ id: string }>("/api/logs/log-1"),
    ).resolves.toEqual({ id: "log-1" });
  });

  it("throws structured API errors", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: false,
      status: 400,
      statusText: "Bad Request",
      json: vi.fn().mockResolvedValue({
        error: { code: "validation", message: "invalid input" },
      }),
    } as unknown as Response);

    await expect(apiRequest("/api/logs")).rejects.toMatchObject({
      status: 400,
      code: "validation",
      message: "invalid input",
    } satisfies Partial<ApiError>);
  });
});
