import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { CustomFoodCreate } from "../pages/CustomFoodCreate";

const mockGetSession = vi.fn();
const mockCreateCustomFood = vi.fn();
const mockListNutrients = vi.fn();
const mockListUnits = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/foods", () => ({
  createCustomFood: (...args: unknown[]) => mockCreateCustomFood(...args),
  listNutrients: (...args: unknown[]) => mockListNutrients(...args),
  listUnits: (...args: unknown[]) => mockListUnits(...args),
}));

function renderAtCreate() {
  return render(
    <MemoryRouter initialEntries={["/foods/custom/new"]}>
      <AuthProvider>
        <Routes>
          <Route path="/foods/custom/new" element={<CustomFoodCreate />} />
          <Route path="/foods/:id" element={<div>Food Detail Page</div>} />
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

describe("CustomFoodCreate", () => {
  it("renders the create form", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(screen.getByText("Create Custom Food")).toBeInTheDocument();
    });

    expect(screen.getByText("Basic Info")).toBeInTheDocument();
    expect(screen.getByText("Portion Info")).toBeInTheDocument();
    expect(screen.getByText("Nutrients (per 100g)")).toBeInTheDocument();
    expect(screen.getByText("Servings")).toBeInTheDocument();
  });

  it("shows error when submitting with empty name", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(screen.getByText("Create Custom Food")).toBeInTheDocument();
    });

    fireEvent.submit(screen.getByText("Create Food").closest("form")!);

    await waitFor(() => {
      expect(screen.getByText("Name is required")).toBeInTheDocument();
    });
  });

  it("creates custom food on valid submit", async () => {
    mockCreateCustomFood.mockResolvedValue({ id: "new-id-123" });

    renderAtCreate();

    await waitFor(() => {
      expect(screen.getByText("Create Custom Food")).toBeInTheDocument();
    });

    const nameInput = screen.getByRole("textbox", { name: /Name/i });
    await userEvent.type(nameInput, "My Custom Food");

    await userEvent.click(screen.getByText("Create Food"));

    await waitFor(() => {
      expect(mockCreateCustomFood).toHaveBeenCalled();
      expect(
        screen.getByText("Food Detail Page"),
      ).toBeInTheDocument();
    });
  });

  it("shows error on create failure", async () => {
    mockCreateCustomFood.mockRejectedValue(new Error("Creation failed"));

    renderAtCreate();

    await waitFor(() => {
      expect(screen.getByText("Create Custom Food")).toBeInTheDocument();
    });

    const nameInput = screen.getByRole("textbox", { name: /Name/i });
    await userEvent.type(nameInput, "Test Food");

    await userEvent.click(screen.getByText("Create Food"));

    await waitFor(() => {
      expect(screen.getByText("Creation failed")).toBeInTheDocument();
    });
  });

  it("adds and removes nutrient rows", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(screen.getByText("Create Custom Food")).toBeInTheDocument();
    });

    const addBtn = screen.getByText("+ Add Nutrient");
    await userEvent.click(addBtn);

    const removeBtns = screen.getAllByText("×");
    expect(removeBtns).toHaveLength(2);

    await userEvent.click(removeBtns[1]);
    expect(screen.getAllByText("×")).toHaveLength(1);
  });

  it("adds and removes serving rows", async () => {
    renderAtCreate();

    await waitFor(() => {
      expect(screen.getByText("Create Custom Food")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("+ Add Serving"));

    const labelInput = screen.getByPlaceholderText("Label (e.g. scoop)");
    expect(labelInput).toBeInTheDocument();

    const removeBtns = screen.getAllByText("×");
    const servingRemoveBtn = removeBtns[removeBtns.length - 1];
    await userEvent.click(servingRemoveBtn);

    expect(
      screen.queryByPlaceholderText("Label (e.g. scoop)"),
    ).not.toBeInTheDocument();
  });
});
