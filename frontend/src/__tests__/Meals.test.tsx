import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { Meals } from "../pages/Meals";

const mockGetSession = vi.fn();
const mockListMeals = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/meals", () => ({
  listMeals: (...args: unknown[]) => mockListMeals(...args),
  getMeal: vi.fn(),
  deleteMeal: vi.fn(),
  createMeal: vi.fn(),
  updateMeal: vi.fn(),
  getMealNutrients: vi.fn(),
}));

function renderAtMeals() {
  return render(
    <MemoryRouter initialEntries={["/meals"]}>
      <AuthProvider>
        <Routes>
          <Route path="/meals" element={<Meals />} />
          <Route path="/meals/new" element={<div>Create Meal Page</div>} />
          <Route
            path="/meals/:id"
            element={<div>Meal Detail Page</div>}
          />
          <Route path="/home" element={<div>User Home</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

const mockMeals = [
  {
    id: "meal-1",
    name: "Oatmeal Breakfast",
    notes: "My go-to breakfast",
    total_quantity: null,
    components: [{ id: "c1", item: { type: "product", id: "p1" }, quantity: { amount: "100", unit: "g" } }],
    created_at: "2026-05-30T00:00:00Z",
    updated_at: "2026-05-30T00:00:00Z",
  },
  {
    id: "meal-2",
    name: "Post-Workout Shake",
    notes: null,
    total_quantity: null,
    components: [
      { id: "c2", item: { type: "product", id: "p2" }, quantity: { amount: "200", unit: "ml" } },
      { id: "c3", item: { type: "product", id: "p3" }, quantity: { amount: "30", unit: "g" } },
    ],
    created_at: "2026-05-30T00:00:00Z",
    updated_at: "2026-05-30T00:00:00Z",
  },
];

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockResolvedValue({
    identity: { id: "1", username: "alice", role: "user" },
    profile: { id: "p1", display_name: "Alice" },
  });
});

describe("Meals", () => {
  it("renders header and create button", async () => {
    mockListMeals.mockResolvedValue({ items: [] });
    renderAtMeals();

    await waitFor(() => {
      expect(screen.getByText("Meals")).toBeInTheDocument();
    });

    expect(screen.getByText("Create Meal")).toBeInTheDocument();
    expect(screen.getByLabelText("Back to Diary")).toBeInTheDocument();
  });

  it("shows empty state when no meals", async () => {
    mockListMeals.mockResolvedValue({ items: [] });
    renderAtMeals();

    await waitFor(() => {
      expect(
        screen.getByText(
          /No meals yet/,
        ),
      ).toBeInTheDocument();
    });
  });

  it("shows meal list", async () => {
    mockListMeals.mockResolvedValue({ items: mockMeals });
    renderAtMeals();

    await waitFor(() => {
      expect(screen.getByText("Oatmeal Breakfast")).toBeInTheDocument();
    });

    expect(screen.getByText("Post-Workout Shake")).toBeInTheDocument();
  });

  it("shows component count", async () => {
    mockListMeals.mockResolvedValue({ items: mockMeals });
    renderAtMeals();

    await waitFor(() => {
      expect(
        screen.getByText((content) => content.startsWith("1 component")),
      ).toBeInTheDocument();
    });

    expect(
      screen.getByText((content) => content.startsWith("2 component")),
    ).toBeInTheDocument();
  });

  it("shows notes in list", async () => {
    mockListMeals.mockResolvedValue({ items: mockMeals });
    renderAtMeals();

    await waitFor(() => {
      expect(
        screen.getByText(/My go-to breakfast/),
      ).toBeInTheDocument();
    });
  });

  it("navigates to meal detail on click", async () => {
    mockListMeals.mockResolvedValue({ items: mockMeals });
    renderAtMeals();

    await waitFor(() => {
      expect(screen.getByText("Oatmeal Breakfast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Oatmeal Breakfast"));

    await waitFor(() => {
      expect(screen.getByText("Meal Detail Page")).toBeInTheDocument();
    });
  });

  it("navigates to create meal on button click", async () => {
    mockListMeals.mockResolvedValue({ items: [] });
    renderAtMeals();

    await waitFor(() => {
      expect(screen.getByText("Create Meal")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Create Meal"));

    await waitFor(() => {
      expect(screen.getByText("Create Meal Page")).toBeInTheDocument();
    });
  });

  it("navigates back to diary", async () => {
    mockListMeals.mockResolvedValue({ items: [] });
    renderAtMeals();

    await waitFor(() => {
      expect(screen.getByLabelText("Back to Diary")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByLabelText("Back to Diary"));

    await waitFor(() => {
      expect(screen.getByText("User Home")).toBeInTheDocument();
    });
  });

  it("shows error state", async () => {
    mockListMeals.mockRejectedValue(new Error("Failed to fetch"));
    renderAtMeals();

    await waitFor(() => {
      expect(screen.getByText("Failed to fetch")).toBeInTheDocument();
    });
  });
});
