import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { FoodDetail } from "../pages/FoodDetail";

const mockGetSession = vi.fn();
const mockGetFoodDetail = vi.fn();
const mockDeleteCustomFood = vi.fn();
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
  deleteCustomFood: (...args: unknown[]) => mockDeleteCustomFood(...args),
  listUnits: (...args: unknown[]) => mockListUnits(...args),
}));

vi.mock("../api/logs", () => ({
  createLog: (...args: unknown[]) => mockCreateLog(...args),
}));

function renderAtDetail(foodId = "some-id") {
  return render(
    <MemoryRouter initialEntries={[`/foods/${foodId}`]}>
      <AuthProvider>
        <Routes>
          <Route path="/foods/:id" element={<FoodDetail />} />
          <Route path="/search" element={<div>Search Page</div>} />
          <Route path="/home" element={<div>User Home</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

const mockProduct = {
  id: "abc-123",
  source: "SYSTEM",
  source_id: null,
  visibility: "global",
  barcode: "123456789",
  name: "Chicken Breast",
  brand: "Organic Farms",
  category: "Meat",
  default_quantity: null,
  default_unit: null,
  serving_size_g: "100",
  nutrients: [
    { code: "ENERGY_KCAL", amount_per_100g: "165", unit: "", source: null, confidence: null },
    { code: "PROTEIN_G", amount_per_100g: "31", unit: "", source: null, confidence: null },
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
    { code: "ENERGY_KCAL", amount_per_100g: "120", unit: "", source: null, confidence: null },
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

    expect(screen.getByText("Food Detail")).toBeInTheDocument();
  });

  it("shows food details when loaded", async () => {
    mockGetFoodDetail.mockResolvedValue(mockProduct);

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    expect(screen.getByText("Organic Farms")).toBeInTheDocument();
    expect(screen.getByText("Meat")).toBeInTheDocument();
    expect(screen.getByText("165")).toBeInTheDocument();
    expect(screen.getByText("31")).toBeInTheDocument();
    expect(screen.getByText("fillet")).toBeInTheDocument();
  });

  it("shows error state", async () => {
    mockGetFoodDetail.mockRejectedValue(new Error("Food not found"));

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Food not found")).toBeInTheDocument();
    });
  });

  it("shows edit/delete for custom foods", async () => {
    mockGetFoodDetail.mockResolvedValue(mockCustomProduct);

    renderAtDetail("custom-123");

    await waitFor(() => {
      expect(screen.getByText("My Protein Shake")).toBeInTheDocument();
    });

    expect(screen.getByText("Edit")).toBeInTheDocument();
    expect(screen.getByText("Delete")).toBeInTheDocument();
  });

  it("does not show edit/delete for system foods", async () => {
    mockGetFoodDetail.mockResolvedValue(mockProduct);

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    expect(screen.queryByText("Edit")).not.toBeInTheDocument();
    expect(screen.queryByText("Delete")).not.toBeInTheDocument();
  });

  it("deletes custom food and navigates to search", async () => {
    mockGetFoodDetail.mockResolvedValue(mockCustomProduct);
    mockDeleteCustomFood.mockResolvedValue(undefined);
    vi.spyOn(window, "confirm").mockReturnValue(true);

    renderAtDetail("custom-123");

    await waitFor(() => {
      expect(screen.getByText("My Protein Shake")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Delete"));

    await waitFor(() => {
      expect(mockDeleteCustomFood).toHaveBeenCalledWith("custom-123");
      expect(screen.getByText("Search Page")).toBeInTheDocument();
    });
  });

  it("cancels delete when confirm is false", async () => {
    mockGetFoodDetail.mockResolvedValue(mockCustomProduct);
    vi.spyOn(window, "confirm").mockReturnValue(false);

    renderAtDetail("custom-123");

    await waitFor(() => {
      expect(screen.getByText("My Protein Shake")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Delete"));

    expect(mockDeleteCustomFood).not.toHaveBeenCalled();
  });
});
