import { apiRequest } from "./client";

export interface QuantityDto {
  amount: string;
  unit: string;
}

export interface MealComponentResponse {
  id: string;
  item: { type: string; id: string };
  quantity: QuantityDto;
}

export interface MealResponse {
  id: string;
  name: string;
  notes: string | null;
  total_quantity: QuantityDto | null;
  components: MealComponentResponse[];
  created_at: string;
  updated_at: string;
}

export interface MealListResponse {
  items: MealResponse[];
}

export interface CreateMealComponentRequest {
  item: { type: string; id: string };
  quantity: QuantityDto;
}

export interface CreateMealRequest {
  name: string;
  notes?: string | null;
  total_quantity?: QuantityDto | null;
  components: CreateMealComponentRequest[];
}

export interface UpdateMealRequest {
  name?: string;
  notes?: string | null;
  total_quantity?: QuantityDto | null;
  components?: CreateMealComponentRequest[];
}

export interface MealNutrientEntry {
  code: string;
  amount: string;
  unit: string;
}

export interface MealNutritionResponse {
  meal_id: string;
  quantity: QuantityDto;
  nutrients: MealNutrientEntry[];
}

export async function listMeals(): Promise<MealListResponse> {
  return apiRequest<MealListResponse>("/api/meals");
}

export async function getMeal(id: string): Promise<MealResponse> {
  return apiRequest<MealResponse>(`/api/meals/${id}`);
}

export async function createMeal(
  data: CreateMealRequest,
): Promise<MealResponse> {
  return apiRequest<MealResponse>("/api/meals", {
    method: "POST",
    body: JSON.stringify(data),
  });
}

export async function updateMeal(
  id: string,
  data: UpdateMealRequest,
): Promise<MealResponse> {
  return apiRequest<MealResponse>(`/api/meals/${id}`, {
    method: "PUT",
    body: JSON.stringify(data),
  });
}

export async function deleteMeal(id: string): Promise<void> {
  await apiRequest<void>(`/api/meals/${id}`, { method: "DELETE" });
}

export async function getMealNutrients(
  id: string,
  amount: string,
  unit: string,
): Promise<MealNutritionResponse> {
  return apiRequest<MealNutritionResponse>(
    `/api/meals/${id}/nutrients?amount=${encodeURIComponent(amount)}&unit=${encodeURIComponent(unit)}`,
  );
}
