import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { FoodSearch } from "../pages/FoodSearch";

const mockGetSession = vi.fn();
const mockSearchFoods = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/foods", () => ({
  searchFoods: (...args: unknown[]) => mockSearchFoods(...args),
}));

function renderAtSearch() {
  return render(
    <MemoryRouter initialEntries={["/search"]}>
      <AuthProvider>
        <Routes>
          <Route path="/search" element={<FoodSearch />} />
          <Route path="/foods/:id" element={<div>Food Detail Page</div>} />
          <Route path="/home" element={<div>User Home</div>} />
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
      expect(mockSearchFoods).toHaveBeenCalledWith("chicken");
    });
  });

  it("shows results after search", async () => {
    mockSearchFoods.mockResolvedValue({
      items: [
        {
          id: "1",
          source: "SYSTEM",
          source_id: null,
          barcode: null,
          name: "Chicken Breast",
          brand: null,
          category: "Meat",
          serving_size_g: "100",
        },
        {
          id: "2",
          source: "USER",
          source_id: null,
          barcode: null,
          name: "Protein Shake",
          brand: "MyBrand",
          category: "Supplements",
          serving_size_g: null,
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

    expect(screen.getByText("Meat")).toBeInTheDocument();
    expect(screen.getByText("Protein Shake")).toBeInTheDocument();
    expect(screen.getByText("MyBrand")).toBeInTheDocument();
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

  it("navigates to food detail on click", async () => {
    mockSearchFoods.mockResolvedValue({
      items: [
        {
          id: "abc-123",
          source: "SYSTEM",
          source_id: null,
          barcode: null,
          name: "Test Food",
          brand: null,
          category: null,
          serving_size_g: null,
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
});
