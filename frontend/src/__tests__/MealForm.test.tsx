import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { MealForm } from "../pages/MealForm";

const mockGetSession = vi.fn();
const mockCreateMeal = vi.fn();
const mockUpdateMeal = vi.fn();
const mockGetMeal = vi.fn();
const mockSearchFoods = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/meals", () => ({
  getMeal: (...args: unknown[]) => mockGetMeal(...args),
  createMeal: (...args: unknown[]) => mockCreateMeal(...args),
  updateMeal: (...args: unknown[]) => mockUpdateMeal(...args),
  listMeals: vi.fn(),
  deleteMeal: vi.fn(),
  getMealNutrients: vi.fn(),
}));

vi.mock("../api/foods", () => ({
  searchFoods: (...args: unknown[]) => mockSearchFoods(...args),
  getFoodDetail: vi.fn(),
}));

const mockProduct = {
  id: "p1",
  source: "USER",
  source_id: null,
  barcode: null,
  name: "Rolled Oats",
  brand: "Brand X",
  category: "Grains",
  serving_size_g: "40",
  default_quantity: null,
  default_unit: null,
  nutrients: [],
  servings: [],
};

function renderAtCreate() {
  return render(
    <MemoryRouter initialEntries={["/meals/new"]}>
      <AuthProvider>
        <Routes>
          <Route path="/meals/new" element={<MealForm />} />
          <Route path="/meals" element={<div>Meals List Page</div>} />
          <Route path="/meals/:id" element={<div>Meal Detail Page</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

function renderAtEdit() {
  return render(
    <MemoryRouter initialEntries={["/meals/meal-1/edit"]}>
      <AuthProvider>
        <Routes>
          <Route path="/meals/:id/edit" element={<MealForm />} />
          <Route path="/meals" element={<div>Meals List Page</div>} />
          <Route path="/meals/:id" element={<div>Meal Detail Page</div>} />
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
});

describe("MealForm (Create)", () => {
  it("renders create form", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    expect(screen.getByLabelText("Back to Meals")).toBeInTheDocument();
    expect(screen.getByText("Components")).toBeInTheDocument();
  });

  it("navigates back to meals list", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    await userEvent.click(screen.getByLabelText("Back to Meals"));

    await waitFor(() => {
      expect(screen.getByText("Meals List Page")).toBeInTheDocument();
    });
  });

  it("shows error when submitting with empty name", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    const submitBtn = screen.getByRole("button", { name: /Create Meal/i });
    await userEvent.click(submitBtn);

    await waitFor(() => {
      expect(screen.getByText("Name is required")).toBeInTheDocument();
    });
  });

  it("shows error when submitting without product selected", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    const nameInput = screen.getByRole("textbox", { name: /Name/i });
    await userEvent.type(nameInput, "My Meal");

    const submitBtn = screen.getByRole("button", { name: /Create Meal/i });
    await userEvent.click(submitBtn);

    await waitFor(() => {
      expect(
        screen.getByText(
          "At least one component with a selected product is required",
        ),
      ).toBeInTheDocument();
    });
  });

  it("creates meal after product search and selection", async () => {
    mockSearchFoods.mockResolvedValue({ items: [mockProduct] });
    mockCreateMeal.mockResolvedValue({
      id: "new-meal-1",
      name: "My Meal",
      notes: null,
      total_quantity: null,
      components: [],
      created_at: "",
      updated_at: "",
    });

    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    const nameInput = screen.getByRole("textbox", { name: /Name/i });
    await userEvent.type(nameInput, "My Meal");

    const searchInput = screen.getAllByPlaceholderText("Search product...")[0];
    fireEvent.change(searchInput, { target: { value: "Oats" } });

    await new Promise((r) => setTimeout(r, 400));

    await waitFor(() => {
      expect(screen.getByText("Rolled Oats")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Rolled Oats"));

    const submitBtn = screen.getByRole("button", { name: /Create Meal/i });
    await userEvent.click(submitBtn);

    await waitFor(() => {
      expect(mockCreateMeal).toHaveBeenCalled();
    });
  });

  it("shows error on create failure", async () => {
    mockSearchFoods.mockResolvedValue({ items: [mockProduct] });
    mockCreateMeal.mockRejectedValue(new Error("Creation failed"));

    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    const nameInput = screen.getByRole("textbox", { name: /Name/i });
    await userEvent.type(nameInput, "My Meal");

    const searchInput = screen.getAllByPlaceholderText("Search product...")[0];
    fireEvent.change(searchInput, { target: { value: "Oats" } });

    await new Promise((r) => setTimeout(r, 400));

    await waitFor(() => {
      expect(screen.getByText("Rolled Oats")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Rolled Oats"));

    const submitBtn = screen.getByRole("button", { name: /Create Meal/i });
    await userEvent.click(submitBtn);

    await waitFor(() => {
      expect(screen.getByText("Creation failed")).toBeInTheDocument();
    });
  });

  it("adds and removes component rows", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    const addBtn = screen.getByText("+ Add Component");
    fireEvent.click(addBtn);

    await waitFor(() => {
      const searchInputs = screen.getAllByPlaceholderText("Search product...");
      expect(searchInputs).toHaveLength(2);
    });

    const removeBtns = screen.getAllByRole("button", { name: "×" });
    expect(removeBtns).toHaveLength(2);

    fireEvent.click(removeBtns[1]);
    expect(
      screen.getAllByPlaceholderText("Search product..."),
    ).toHaveLength(1);
  });

  it("searches products when typing in component", async () => {
    mockSearchFoods.mockResolvedValue({ items: [mockProduct] });
    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    const searchInputs = screen.getAllByPlaceholderText("Search product...");
    fireEvent.change(searchInputs[0], { target: { value: "Oats" } });

    await new Promise((r) => setTimeout(r, 400));

    await waitFor(() => {
      expect(screen.getByText("Rolled Oats")).toBeInTheDocument();
    });
  });

  it("selects a product from search results", async () => {
    mockSearchFoods.mockResolvedValue({ items: [mockProduct] });
    renderAtCreate();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Create Meal/i }),
      ).toBeInTheDocument();
    });

    const searchInputs = screen.getAllByPlaceholderText("Search product...");
    fireEvent.change(searchInputs[0], { target: { value: "Oats" } });

    await new Promise((r) => setTimeout(r, 400));

    await waitFor(() => {
      expect(screen.getByText("Rolled Oats")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Rolled Oats"));

    await waitFor(() => {
      expect(
        (screen.getByPlaceholderText("Search product...") as HTMLInputElement)
          .value,
      ).toBe("Rolled Oats");
    });
  });
});

describe("MealForm (Edit)", () => {
  it("loads meal data on edit", async () => {
    mockGetMeal.mockResolvedValue({
      id: "meal-1",
      name: "Oatmeal Breakfast",
      notes: "My go-to",
      total_quantity: null,
      components: [
        {
          id: "c1",
          item: { type: "product", id: "p1" },
          quantity: { amount: "100", unit: "g" },
        },
      ],
      created_at: "",
      updated_at: "",
    });

    renderAtEdit();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Edit Meal/i }),
      ).toBeInTheDocument();
    });

    const nameInput = screen.getByRole("textbox", {
      name: /Name/i,
    }) as HTMLInputElement;
    expect(nameInput.value).toBe("Oatmeal Breakfast");
  });

  it("updates meal on submit", async () => {
    mockGetMeal.mockResolvedValue({
      id: "meal-1",
      name: "Oatmeal Breakfast",
      notes: "My go-to",
      total_quantity: null,
      components: [
        {
          id: "c1",
          item: { type: "product", id: "p1" },
          quantity: { amount: "100", unit: "g" },
        },
      ],
      created_at: "",
      updated_at: "",
    });
    mockUpdateMeal.mockResolvedValue({
      id: "meal-1",
      name: "Updated Meal",
      notes: null,
      total_quantity: null,
      components: [],
      created_at: "",
      updated_at: "",
    });

    renderAtEdit();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: /Edit Meal/i }),
      ).toBeInTheDocument();
    });

    const submitBtn = screen.getByRole("button", { name: /Update Meal/i });
    await userEvent.click(submitBtn);

    await waitFor(() => {
      expect(mockUpdateMeal).toHaveBeenCalled();
    });
  });

  it("shows error on load failure", async () => {
    mockGetMeal.mockRejectedValue(new Error("Load failed"));

    renderAtEdit();

    await waitFor(() => {
      expect(screen.getByText("Load failed")).toBeInTheDocument();
    });
  });
});
