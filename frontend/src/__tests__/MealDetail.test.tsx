import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { MealDetail } from "../pages/MealDetail";

const mockGetSession = vi.fn();
const mockGetMeal = vi.fn();
const mockDeleteMeal = vi.fn();
const mockGetMealNutrients = vi.fn();
const mockGetFoodDetail = vi.fn();
const mockCreateLog = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/meals", () => ({
  getMeal: (...args: unknown[]) => mockGetMeal(...args),
  deleteMeal: (...args: unknown[]) => mockDeleteMeal(...args),
  getMealNutrients: (...args: unknown[]) => mockGetMealNutrients(...args),
  listMeals: vi.fn(),
  createMeal: vi.fn(),
  updateMeal: vi.fn(),
}));

vi.mock("../api/foods", () => ({
  getFoodDetail: (...args: unknown[]) => mockGetFoodDetail(...args),
}));

vi.mock("../api/logs", () => ({
  createLog: (...args: unknown[]) => mockCreateLog(...args),
}));

const mockMeal = {
  id: "meal-1",
  name: "Oatmeal Breakfast",
  notes: "My go-to breakfast",
  total_quantity: null,
  components: [
    { id: "c1", item: { type: "product", id: "p1" }, quantity: { amount: "100", unit: "g" } },
    { id: "c2", item: { type: "product", id: "p2" }, quantity: { amount: "200", unit: "ml" } },
  ],
  created_at: "2026-05-30T00:00:00Z",
  updated_at: "2026-05-30T00:00:00Z",
};

const mockNutrients = {
  meal_id: "meal-1",
  quantity: { amount: "100", unit: "g" },
  nutrients: [
    { code: "ENERGY_KCAL", amount: "350", unit: "kcal" },
    { code: "PROTEIN_G", amount: "12", unit: "g" },
  ],
};

function renderAtDetail() {
  return render(
    <MemoryRouter initialEntries={["/meals/meal-1"]}>
      <AuthProvider>
        <Routes>
          <Route path="/meals/:id" element={<MealDetail />} />
          <Route path="/meals" element={<div>Meals List Page</div>} />
          <Route
            path="/meals/:id/edit"
            element={<div>Edit Meal Page</div>}
          />
          <Route path="/home" element={<div>Diary Page</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockResolvedValue({
    identity: { id: "1", username: "alice", role: "user" },
    profile: { id: "p1", display_name: "Alice" },
  });
  mockGetMeal.mockResolvedValue(mockMeal);
  mockGetFoodDetail.mockResolvedValue({ id: "p1", name: "Oats" });
});

describe("MealDetail", () => {
  it("renders meal name and notes", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Oatmeal Breakfast")).toBeInTheDocument();
    });

    expect(screen.getByText("My go-to breakfast")).toBeInTheDocument();
  });

  it("shows components with product names", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Oats")).toBeInTheDocument();
    });

    expect(screen.getByText("100 g")).toBeInTheDocument();
    expect(screen.getByText("200 ml")).toBeInTheDocument();
  });

  it("shows log section", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Oatmeal Breakfast")).toBeInTheDocument();
    });

    expect(screen.getByText("Log this meal")).toBeInTheDocument();
    expect(screen.getByText("Calculate")).toBeInTheDocument();
  });

  it("calculates and shows nutrients", async () => {
    mockGetMealNutrients.mockResolvedValue(mockNutrients);
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Oatmeal Breakfast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Calculate"));

    await waitFor(() => {
      expect(screen.getByText("ENERGY_KCAL")).toBeInTheDocument();
    });

    expect(screen.getByText("350")).toBeInTheDocument();
    expect(screen.getByText("Log Meal")).toBeInTheDocument();
  });

  it("logs meal and navigates to diary", async () => {
    mockGetMealNutrients.mockResolvedValue(mockNutrients);
    mockCreateLog.mockResolvedValue({ id: "log-1" });
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Oatmeal Breakfast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Calculate"));

    await waitFor(() => {
      expect(screen.getByText("Log Meal")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Log Meal"));

    await waitFor(() => {
      expect(screen.getByText("Diary Page")).toBeInTheDocument();
    });
  });

  it("navigates to edit page", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Oatmeal Breakfast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Edit"));

    await waitFor(() => {
      expect(screen.getByText("Edit Meal Page")).toBeInTheDocument();
    });
  });

  it("deletes meal and navigates to list", async () => {
    mockDeleteMeal.mockResolvedValue(undefined);
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Oatmeal Breakfast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Delete"));

    await waitFor(() => {
      expect(screen.getByText("Confirm Delete")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Confirm Delete"));

    await waitFor(() => {
      expect(screen.getByText("Meals List Page")).toBeInTheDocument();
    });
  });

  it("shows error state", async () => {
    mockGetMeal.mockRejectedValue(new Error("Meal not found"));
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Meal not found")).toBeInTheDocument();
    });
  });

  it("shows not-found state when meal is null", async () => {
    mockGetMeal.mockResolvedValue(null);
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Meal not found.")).toBeInTheDocument();
    });
  });
});
