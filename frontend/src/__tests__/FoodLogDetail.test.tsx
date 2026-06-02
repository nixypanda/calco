import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { FoodLogDetail } from "../pages/FoodLogDetail";

const mockGetSession = vi.fn();
const mockGetLog = vi.fn();
const mockUpdateLog = vi.fn();
const mockDeleteLog = vi.fn();
const mockGetFoodDetail = vi.fn();
const mockListUnits = vi.fn();
const mockGetMeal = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/logs", () => ({
  getLog: (...args: unknown[]) => mockGetLog(...args),
  updateLog: (...args: unknown[]) => mockUpdateLog(...args),
  deleteLog: (...args: unknown[]) => mockDeleteLog(...args),
}));

vi.mock("../api/foods", () => ({
  getFoodDetail: (...args: unknown[]) => mockGetFoodDetail(...args),
  listUnits: (...args: unknown[]) => mockListUnits(...args),
}));

vi.mock("../api/meals", () => ({
  getMeal: (...args: unknown[]) => mockGetMeal(...args),
}));

function renderAtDetail(logId = "log-1") {
  return render(
    <MemoryRouter initialEntries={[`/logs/${logId}`]}>
      <AuthProvider>
        <Routes>
          <Route path="/logs/:id" element={<FoodLogDetail />} />
          <Route path="/home" element={<div>Diary Page</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

const mockLog = {
  id: "log-1",
  logged_at: "2026-05-30T12:00:00Z",
  meal_slot: "lunch",
  item: { type: "product", id: "food-1" },
  quantity: { amount: "150", unit: "g" },
  nutrients: [
    { code: "ENERGY_KCAL", amount: "247.5", unit: "kcal" },
    { code: "PROTEIN_G", amount: "46.5", unit: "g" },
    { code: "CARBS_G", amount: "0", unit: "g" },
    { code: "FAT_G", amount: "3.5", unit: "g" },
  ],
  notes: "Post-workout meal",
};

const mockFood = {
  id: "food-1",
  source: "USDA",
  source_id: null,
  visibility: "global",
  barcode: null,
  name: "Chicken Breast",
  brand: null,
  categories: [],
  default_quantity: null,
  default_unit: "g",
  serving_size_g: null,
  nutrients: [
    {
      code: "ENERGY_KCAL",
      amount_per_100g: "165",
      unit: "kcal",
      source: null,
      confidence: null,
    },
    {
      code: "PROTEIN_G",
      amount_per_100g: "31",
      unit: "g",
      source: null,
      confidence: null,
    },
    {
      code: "CARBS_G",
      amount_per_100g: "0",
      unit: "g",
      source: null,
      confidence: null,
    },
    {
      code: "FAT_G",
      amount_per_100g: "3.6",
      unit: "g",
      source: null,
      confidence: null,
    },
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
  mockGetLog.mockResolvedValue(mockLog);
  mockGetFoodDetail.mockResolvedValue(mockFood);
  mockListUnits.mockResolvedValue(mockUnits);
});

describe("FoodLogDetail", () => {
  it("shows loading state", async () => {
    mockGetLog.mockImplementation(() => new Promise(() => {}));

    renderAtDetail();

    expect(screen.getByText("Edit Log")).toBeInTheDocument();
  });

  it("shows log details when loaded", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    expect(
      screen.getByRole("combobox", { name: "Meal slot" }),
    ).toHaveTextContent("Lunch");
    expect(screen.getByDisplayValue("150")).toBeInTheDocument();
    expect(screen.getByDisplayValue("Post-workout meal")).toBeInTheDocument();
    expect(screen.getByText("Macro Breakdown")).toBeInTheDocument();
    expect(screen.getByText("46.5g")).toBeInTheDocument();
  });

  it("renders the form in edit mode by default", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    expect(
      screen.getByRole("heading", { name: "Edit Log" }),
    ).toBeInTheDocument();
    expect(screen.getByDisplayValue("150")).toBeInTheDocument();
    expect(
      screen.getByRole("combobox", { name: "Meal slot" }),
    ).toHaveTextContent("Lunch");
    expect(screen.getByText("Macro Breakdown")).toBeInTheDocument();
    expect(screen.getByText("Nutrients")).toBeInTheDocument();
  });

  it("saves changes", async () => {
    mockUpdateLog.mockResolvedValue({
      ...mockLog,
      quantity: { amount: "200", unit: "g" },
      meal_slot: "dinner",
    });

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    const amountInput = screen.getByDisplayValue("150");
    await userEvent.clear(amountInput);
    await userEvent.type(amountInput, "200");

    await userEvent.selectOptions(
      screen.getByRole("combobox", { name: "Meal slot" }),
      "dinner",
    );

    await userEvent.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      expect(mockUpdateLog).toHaveBeenCalledWith(
        "log-1",
        expect.objectContaining({
          quantity: { amount: "200", unit: "g" },
          meal_slot: "dinner",
        }),
      );
    });
  });

  it("increments the amount with the stepper", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByRole("button", { name: "Increment" }));

    expect(screen.getByDisplayValue("151")).toBeInTheDocument();
  });

  it("deletes log and navigates to diary", async () => {
    mockDeleteLog.mockResolvedValue(undefined);
    vi.spyOn(window, "confirm").mockReturnValue(true);

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByRole("button", { name: "Delete" }));

    await waitFor(() => {
      expect(mockDeleteLog).toHaveBeenCalledWith("log-1");
      expect(screen.getByText("Diary Page")).toBeInTheDocument();
    });
  });

  it("cancels delete when confirm is false", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(false);

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByRole("button", { name: "Delete" }));

    expect(mockDeleteLog).not.toHaveBeenCalled();
  });

  it("shows error state", async () => {
    mockGetLog.mockRejectedValue(new Error("Log not found"));

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Log not found")).toBeInTheDocument();
    });
  });
});
