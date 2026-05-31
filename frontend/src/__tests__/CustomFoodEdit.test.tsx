import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { CustomFoodEdit } from "../pages/CustomFoodEdit";

const mockGetSession = vi.fn();
const mockGetFoodDetail = vi.fn();
const mockUpdateCustomFood = vi.fn();
const mockListNutrients = vi.fn();
const mockListUnits = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/foods", () => ({
  getFoodDetail: (...args: unknown[]) => mockGetFoodDetail(...args),
  updateCustomFood: (...args: unknown[]) => mockUpdateCustomFood(...args),
  listNutrients: (...args: unknown[]) => mockListNutrients(...args),
  listUnits: (...args: unknown[]) => mockListUnits(...args),
}));

function renderAtEdit(foodId = "custom-123") {
  return render(
    <MemoryRouter initialEntries={[`/foods/custom/${foodId}/edit`]}>
      <AuthProvider>
        <Routes>
          <Route path="/foods/custom/:id/edit" element={<CustomFoodEdit />} />
          <Route path="/foods/:id" element={<div>Food Detail Page</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

const mockExistingFood = {
  id: "custom-123",
  source: "USER",
  source_id: null,
  visibility: "user_private",
  barcode: null,
  name: "My Protein Shake",
  brand: "Homemade",
  categories: ["beverages"],
  default_quantity: "1",
  default_unit: "serving",
  serving_size_g: "250",
  nutrients: [
    { code: "ENERGY_KCAL", amount_per_100g: "120", unit: "", source: null, confidence: null },
    { code: "PROTEIN_G", amount_per_100g: "25", unit: "", source: null, confidence: null },
  ],
  servings: [
    { label: "scoop", quantity: "1", unit: "piece", grams: "30" },
  ],
};

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockResolvedValue({
    identity: { id: "1", username: "alice", role: "user" },
    profile: { id: "p1", display_name: "Alice" },
  });
  mockListNutrients.mockResolvedValue({
    items: [
      { code: "ENERGY_KCAL", name: "Energy (kcal)", unit: "kcal", category: "Energy" },
      { code: "PROTEIN_G", name: "Protein", unit: "g", category: "Macros" },
    ],
  });
  mockListUnits.mockResolvedValue({
    items: [
      { code: "g", name: "gram", kind: "mass" },
      { code: "ml", name: "milliliter", kind: "volume" },
    ],
  });
});

describe("CustomFoodEdit", () => {
  it("shows loading state", async () => {
    mockGetFoodDetail.mockImplementation(() => new Promise(() => {}));

    renderAtEdit();

    expect(screen.getByText("Edit Custom Food")).toBeInTheDocument();
  });

  it("pre-populates form with existing food data", async () => {
    mockGetFoodDetail.mockResolvedValue(mockExistingFood);

    renderAtEdit();

    await waitFor(() => {
      expect(screen.getByDisplayValue("My Protein Shake")).toBeInTheDocument();
    });

    expect(screen.getByDisplayValue("Homemade")).toBeInTheDocument();
    expect(screen.getByDisplayValue("beverages")).toBeInTheDocument();
    expect(screen.getByDisplayValue("250")).toBeInTheDocument();
  });

  it("updates food on submit", async () => {
    mockGetFoodDetail.mockResolvedValue(mockExistingFood);
    mockUpdateCustomFood.mockResolvedValue({ id: "custom-123" });

    renderAtEdit();

    await waitFor(() => {
      expect(screen.getByDisplayValue("My Protein Shake")).toBeInTheDocument();
    });

    const nameInput = screen.getByDisplayValue("My Protein Shake");
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, "Updated Shake");

    await userEvent.click(screen.getByText("Save Changes"));

    await waitFor(() => {
      expect(mockUpdateCustomFood).toHaveBeenCalledWith(
        "custom-123",
        expect.objectContaining({ name: "Updated Shake" }),
      );
      expect(screen.getByText("Food Detail Page")).toBeInTheDocument();
    });
  });

  it("shows error on update failure", async () => {
    mockGetFoodDetail.mockResolvedValue(mockExistingFood);
    mockUpdateCustomFood.mockRejectedValue(new Error("Update failed"));

    renderAtEdit();

    await waitFor(() => {
      expect(screen.getByDisplayValue("My Protein Shake")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Save Changes"));

    await waitFor(() => {
      expect(screen.getByText("Update failed")).toBeInTheDocument();
    });
  });

  it("handles load error", async () => {
    mockGetFoodDetail.mockRejectedValue(new Error("Food not found"));

    renderAtEdit();

    await waitFor(() => {
      expect(screen.getByText("Food not found")).toBeInTheDocument();
    });
  });
});
