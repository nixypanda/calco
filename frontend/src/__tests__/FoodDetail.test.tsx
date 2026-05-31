import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { FoodDetail } from "../pages/FoodDetail";

const mockGetSession = vi.fn();
const mockGetFoodDetail = vi.fn();
const mockListUnits = vi.fn();
const mockCreateLog = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/foods", () => ({
  getFoodDetail: (...args: unknown[]) => mockGetFoodDetail(...args),
  listUnits: (...args: unknown[]) => mockListUnits(...args),
}));

vi.mock("../api/logs", () => ({
  createLog: (...args: unknown[]) => mockCreateLog(...args),
}));

function renderAtDetail(
  foodId = "some-id",
  state?: { mealSlot?: string },
) {
  return render(
    <MemoryRouter initialEntries={[{ pathname: `/foods/${foodId}`, state }]}>
      <AuthProvider>
        <Routes>
          <Route path="/foods/:id" element={<FoodDetail />} />
          <Route path="/foods/custom/:id/edit" element={<div>Edit Custom Food</div>} />
          <Route path="/search" element={<div>Search Page</div>} />
          <Route path="/home" element={<div>User Home</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

const mockProduct = {
  id: "abc-123",
  source: "USDA",
  source_id: null,
  visibility: "global",
  barcode: "123456789",
  name: "Chicken Breast",
  brand: "Organic Farms",
  category: "Meat",
  default_quantity: "100",
  default_unit: "g",
  serving_size_g: "100",
  nutrients: [
    { code: "ENERGY_KCAL", amount_per_100g: "165", unit: "kcal", source: null, confidence: null },
    { code: "PROTEIN_G", amount_per_100g: "31", unit: "g", source: null, confidence: null },
  ],
  servings: [
    { label: "fillet", quantity: "1", unit: "piece", grams: "150" },
  ],
};

const mockCustomProduct = {
  ...mockProduct,
  id: "custom-123",
  source: "USER",
  name: "My Protein Shake",
  brand: "Homemade",
  nutrients: [
    { code: "ENERGY_KCAL", amount_per_100g: "120", unit: "kcal", source: null, confidence: null },
  ],
  servings: [],
};

const mockUnits = {
  items: [
    { code: "g", name: "gram", kind: "mass" },
    { code: "kg", name: "kilogram", kind: "mass" },
  ],
};

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockResolvedValue({
    identity: { id: "1", username: "alice", role: "user" },
    profile: { id: "p1", display_name: "Alice" },
  });
  mockListUnits.mockResolvedValue(mockUnits);
});

describe("FoodDetail", () => {
  it("shows loading state", async () => {
    mockGetFoodDetail.mockImplementation(() => new Promise(() => {}));

    renderAtDetail();

    expect(screen.getByText("Log Food")).toBeInTheDocument();
  });

  it("shows food details when loaded", async () => {
    mockGetFoodDetail.mockResolvedValue(mockProduct);

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    // Brand and category appear together in subtitle
    expect(screen.getByText(/Organic Farms/)).toBeInTheDocument();
    expect(screen.getByText(/Meat/)).toBeInTheDocument();
    // Macro & nutrient values scaled to default amount (100g) = same as per-100g
    expect(screen.getByText("165.0")).toBeInTheDocument();
    expect(screen.getByText("31.0")).toBeInTheDocument();
  });

  it("shows error state", async () => {
    mockGetFoodDetail.mockRejectedValue(new Error("Food not found"));

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Food not found")).toBeInTheDocument();
    });
  });

  it("shows Edit food link for custom foods", async () => {
    mockGetFoodDetail.mockResolvedValue(mockCustomProduct);

    renderAtDetail("custom-123");

    await waitFor(() => {
      expect(screen.getByText("My Protein Shake")).toBeInTheDocument();
    });

    const editLink = screen.getByRole("link", { name: "Edit food" });
    expect(editLink).toBeInTheDocument();
    expect(editLink).toHaveAttribute("href", "/foods/custom/custom-123/edit");
  });

  it("does not show Edit food link for system foods", async () => {
    mockGetFoodDetail.mockResolvedValue(mockProduct);

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    expect(screen.queryByRole("link", { name: "Edit food" })).not.toBeInTheDocument();
  });

  it("preselects meal slot from navigation state", async () => {
    mockGetFoodDetail.mockResolvedValue(mockProduct);

    renderAtDetail("abc-123", { mealSlot: "lunch" });

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    expect(screen.getByRole("combobox", { name: "Meal slot" })).toHaveTextContent("Lunch");
  });

  it("submits a log and navigates to diary", async () => {
    mockGetFoodDetail.mockResolvedValue(mockProduct);
    mockCreateLog.mockResolvedValue({});

    renderAtDetail("abc-123");

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByRole("button", { name: "Log Food" }));

    await waitFor(() => {
      expect(mockCreateLog).toHaveBeenCalledWith(
        expect.objectContaining({
          item: { type: "product", id: "abc-123" },
          quantity: { amount: "100", unit: "g" },
        }),
      );
      expect(screen.getByText("User Home")).toBeInTheDocument();
    });
  });
});
