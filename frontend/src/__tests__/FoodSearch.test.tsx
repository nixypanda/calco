import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { FoodSearch } from "../pages/FoodSearch";

const mockGetSession = vi.fn();
const mockSearchFoods = vi.fn();
const mockListCategorySuggestions = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/foods", () => ({
  searchFoods: (...args: unknown[]) => mockSearchFoods(...args),
  listCategorySuggestions: (...args: unknown[]) =>
    mockListCategorySuggestions(...args),
}));

function renderAtSearch() {
  return render(
    <MemoryRouter initialEntries={["/search"]}>
      <AuthProvider>
        <Routes>
          <Route path="/search" element={<FoodSearch />} />
          <Route path="/foods/:id" element={<div>Food Detail Page</div>} />
          <Route path="/foods/custom/new" element={<div>Create Food Page</div>} />
          <Route path="/home" element={<div>User Home</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

function renderAtSearchWithMealSlot() {
  function FoodDetailProbe() {
    const location = useLocation();
    const mealSlot = (location.state as { mealSlot?: string } | null)?.mealSlot;
    return <div>Food Detail Slot: {mealSlot}</div>;
  }

  return render(
    <MemoryRouter
      initialEntries={[{ pathname: "/search", state: { mealSlot: "lunch" } }]}
    >
      <AuthProvider>
        <Routes>
          <Route path="/search" element={<FoodSearch />} />
          <Route path="/foods/:id" element={<FoodDetailProbe />} />
          <Route path="/foods/custom/new" element={<div>Create Food Page</div>} />
          <Route path="/home" element={<div>User Home</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  mockListCategorySuggestions.mockResolvedValue({ items: [] });
  mockGetSession.mockResolvedValue({
    identity: { id: "1", username: "alice", role: "user" },
    profile: { id: "p1", display_name: "Alice" },
  });
});

describe("FoodSearch", () => {
  it("renders search input", async () => {
    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });
  });

  it("shows empty state initially", async () => {
    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByText("Search for a food to get started."),
      ).toBeInTheDocument();
    });

    expect(
      screen.getAllByRole("button", { name: "Create Custom Food" }).length,
    ).toBeGreaterThan(0);
  });

  it("navigates to custom food creation", async () => {
    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    await userEvent.click(
      screen.getAllByRole("button", { name: "Create Custom Food" })[0],
    );

    await waitFor(() => {
      expect(screen.getByText("Create Food Page")).toBeInTheDocument();
    });
  });

  it("shows loading state while searching", async () => {
    mockSearchFoods.mockImplementation(
      () => new Promise(() => {}), // never resolves
    );

    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    const input = screen.getByPlaceholderText("Search for a food...");
    await userEvent.type(input, "chicken");

    await waitFor(() => {
      expect(mockSearchFoods).toHaveBeenCalledWith("chicken", expect.any(Object));
    });
  });

  it("shows results after search", async () => {
    mockSearchFoods.mockResolvedValue({
      items: [
        {
          id: "1",
          source: "USDA",
          source_id: null,
          barcode: null,
          name: "Chicken Breast",
          brand: null,
          categories: ["meat"],
          serving_size_g: "100",
          energy_kcal_per_100g: "165",
          energy_kcal_per_serving: "165",
        },
        {
          id: "2",
          source: "USER",
          source_id: null,
          barcode: null,
          name: "Protein Shake",
          brand: "MyBrand",
          categories: ["supplements"],
          serving_size_g: null,
          energy_kcal_per_100g: "120",
          energy_kcal_per_serving: null,
        },
      ],
    });

    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    const input = screen.getByPlaceholderText("Search for a food...");
    await userEvent.type(input, "chicken");

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    expect(screen.getByText("meat")).toBeInTheDocument();
    expect(screen.getByText("165 kcal · 1 serving")).toBeInTheDocument();
    expect(screen.getByText("Protein Shake")).toBeInTheDocument();
    expect(screen.getByText("MyBrand · 120 kcal · per 100 g")).toBeInTheDocument();
    expect(screen.getByText("Custom")).toBeInTheDocument();
  });

  it("shows empty results message", async () => {
    mockSearchFoods.mockResolvedValue({ items: [] });

    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    const input = screen.getByPlaceholderText("Search for a food...");
    await userEvent.type(input, "xxxxx");

    await waitFor(() => {
      expect(
        screen.getByText("No foods found. Try a different search."),
      ).toBeInTheDocument();
    });

    expect(
      screen.getAllByRole("button", { name: "Create Custom Food" }).length,
    ).toBeGreaterThan(0);
  });

  it("shows error on search failure", async () => {
    mockSearchFoods.mockRejectedValue(new Error("Search failed"));

    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    const input = screen.getByPlaceholderText("Search for a food...");
    await userEvent.type(input, "chicken");

    await waitFor(() => {
      expect(screen.getByText("Search failed")).toBeInTheDocument();
    });
  });

  it("autocompletes category operator with tab", async () => {
    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    const input = screen.getByPlaceholderText("Search for a food...");
    await userEvent.type(input, "c");
    await userEvent.tab();

    expect(input).toHaveValue("category:");
  });

  it("autocompletes category values with tab", async () => {
    mockListCategorySuggestions.mockResolvedValue({
      items: [{ value: "food and beverages", count: 4 }],
    });

    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    const input = screen.getByPlaceholderText("Search for a food...");
    await userEvent.type(input, "category:foo");

    await waitFor(() => {
      expect(mockListCategorySuggestions).toHaveBeenCalledWith("foo", 8, expect.any(Object));
    });

    await userEvent.tab();

    expect(input).toHaveValue('category:"food and beverages"');
  });

  it("navigates to food detail on click", async () => {
    mockSearchFoods.mockResolvedValue({
      items: [
        {
          id: "abc-123",
          source: "USDA",
          source_id: null,
          barcode: null,
          name: "Test Food",
          brand: null,
          categories: [],
          serving_size_g: null,
          energy_kcal_per_100g: null,
          energy_kcal_per_serving: null,
        },
      ],
    });

    renderAtSearch();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    const input = screen.getByPlaceholderText("Search for a food...");
    await userEvent.type(input, "test");

    await waitFor(() => {
      expect(screen.getByText("Test Food")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Test Food"));

    await waitFor(() => {
      expect(screen.getByText("Food Detail Page")).toBeInTheDocument();
    });
  });

  it("forwards meal slot state to food detail", async () => {
    mockSearchFoods.mockResolvedValue({
      items: [
        {
          id: "abc-123",
          source: "USDA",
          source_id: null,
          barcode: null,
          name: "Test Food",
          brand: null,
          categories: [],
          serving_size_g: null,
          energy_kcal_per_100g: null,
          energy_kcal_per_serving: null,
        },
      ],
    });

    renderAtSearchWithMealSlot();

    await waitFor(() => {
      expect(
        screen.getByPlaceholderText("Search for a food..."),
      ).toBeInTheDocument();
    });

    const input = screen.getByPlaceholderText("Search for a food...");
    await userEvent.type(input, "test");

    await waitFor(() => {
      expect(screen.getByText("Test Food")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Test Food"));

    await waitFor(() => {
      expect(screen.getByText("Food Detail Slot: lunch")).toBeInTheDocument();
    });
  });
});
