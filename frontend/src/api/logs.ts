import { apiRequest } from "./client";
import type { ItemRef, QuantityDto } from "./types";

export type { ItemRef, QuantityDto };

export interface NutrientSnapshotDto {
  code: string;
  amount: string;
  unit: string;
}

export interface LogResponse {
  id: string;
  logged_at: string;
  meal_slot: string | null;
  item: ItemRef;
  quantity: QuantityDto;
  nutrients: NutrientSnapshotDto[];
  notes: string | null;
}

export interface LogListResponse {
  from: string;
  to: string;
  items: LogResponse[];
}

export interface SummaryEntry {
  code: string;
  amount: string;
  unit: string;
}

export interface SummaryResponse {
  from: string;
  to: string;
  totals: SummaryEntry[];
}

export interface CreateLogRequest {
  logged_at: string;
  meal_slot?: string | null;
  item: { type: string; id: string };
  quantity: { amount: string; unit: string };
  notes?: string | null;
}

export interface UpdateLogRequest {
  logged_at?: string;
  meal_slot?: string | null;
  item?: { type: string; id: string };
  quantity?: { amount: string; unit: string };
  notes?: string | null;
}

export async function createLog(data: CreateLogRequest): Promise<LogResponse> {
  return apiRequest<LogResponse>("/api/logs", {
    method: "POST",
    body: JSON.stringify(data),
  });
}

export async function getLog(id: string): Promise<LogResponse> {
  return apiRequest<LogResponse>(`/api/logs/${id}`);
}

export async function listLogs(
  from: string,
  to: string,
): Promise<LogListResponse> {
  return apiRequest<LogListResponse>(
    `/api/logs?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`,
  );
}

export async function updateLog(
  id: string,
  data: UpdateLogRequest,
): Promise<LogResponse> {
  return apiRequest<LogResponse>(`/api/logs/${id}`, {
    method: "PUT",
    body: JSON.stringify(data),
  });
}

export async function deleteLog(id: string): Promise<void> {
  await apiRequest<void>(`/api/logs/${id}`, { method: "DELETE" });
}

export async function getSummary(
  from: string,
  to: string,
  codes?: string,
): Promise<SummaryResponse> {
  const params = `from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}${codes ? `&codes=${encodeURIComponent(codes)}` : ""}`;
  return apiRequest<SummaryResponse>(`/api/summary?${params}`);
}
