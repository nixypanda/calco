import { apiRequest } from "./client";

export interface SearchResult {
  id: string;
  source: string;
  source_id: string | null;
  barcode: string | null;
  name: string;
  brand: string | null;
  categories: string[];
  serving_size_g: string | null;
  energy_kcal_per_100g: string | null;
  energy_kcal_per_serving: string | null;
}

export interface SearchResponse {
  items: SearchResult[];
}

export interface CategorySuggestion {
  value: string;
  count: number;
}

export interface CategorySuggestionResponse {
  items: CategorySuggestion[];
}

export interface NutrientEntry {
  code: string;
  amount_per_100g: string;
  unit: string;
  source: string | null;
  confidence: string | null;
}

export interface ServingEntry {
  label: string;
  quantity: string;
  unit: string;
  grams: string;
}

export interface ProductDetail {
  id: string;
  source: string;
  source_id: string | null;
  visibility: string;
  barcode: string | null;
  name: string;
  brand: string | null;
  categories: string[];
  default_quantity: string | null;
  default_unit: string | null;
  serving_size_g: string | null;
  nutrients: NutrientEntry[];
  servings: ServingEntry[];
  allowed_units: UnitItem[];
}

export interface NutrientItem {
  code: string;
  name: string;
  unit: string;
  category: string;
}

export interface NutrientListResponse {
  items: NutrientItem[];
}

export interface UnitItem {
  code: string;
  name: string;
  kind: string;
}

export interface UnitListResponse {
  items: UnitItem[];
}

export interface CreateFoodRequest {
  name: string;
  brand?: string | null;
  categories?: string[];
  serving_size_g?: string | null;
  default_quantity?: string | null;
  default_unit?: string | null;
  nutrients: {
    code: string;
    amount_per_100g: string;
    source?: string | null;
    confidence?: string | null;
  }[];
  servings: {
    label: string;
    quantity: string;
    unit: string;
    grams: string;
  }[];
}

export interface CreateFoodResponse {
  id: string;
}

export async function searchFoods(query: string): Promise<SearchResponse> {
  return apiRequest<SearchResponse>(
    `/api/foods/search?q=${encodeURIComponent(query)}`,
  );
}

export async function listCategorySuggestions(
  query: string,
  limit = 10,
): Promise<CategorySuggestionResponse> {
  const params = new URLSearchParams({
    q: query,
    limit: String(limit),
  });
  return apiRequest<CategorySuggestionResponse>(
    `/api/foods/categories?${params.toString()}`,
  );
}

export async function getFoodDetail(id: string): Promise<ProductDetail> {
  return apiRequest<ProductDetail>(`/api/foods/${id}`);
}

export async function createCustomFood(
  data: CreateFoodRequest,
): Promise<CreateFoodResponse> {
  return apiRequest<CreateFoodResponse>("/api/foods/custom", {
    method: "POST",
    body: JSON.stringify(data),
  });
}

export async function updateCustomFood(
  id: string,
  data: CreateFoodRequest,
): Promise<CreateFoodResponse> {
  return apiRequest<CreateFoodResponse>(`/api/foods/custom/${id}`, {
    method: "PUT",
    body: JSON.stringify(data),
  });
}

export async function deleteCustomFood(id: string): Promise<void> {
  await apiRequest<void>(`/api/foods/custom/${id}`, { method: "DELETE" });
}

export async function listNutrients(): Promise<NutrientListResponse> {
  return apiRequest<NutrientListResponse>("/api/nutrients");
}

export async function listUnits(): Promise<UnitListResponse> {
  return apiRequest<UnitListResponse>("/api/units");
}
