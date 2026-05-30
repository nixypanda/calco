import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { History } from "../pages/History";

const mockGetSession = vi.fn();
const mockGetSummary = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/logs", () => ({
  getSummary: (...args: unknown[]) => mockGetSummary(...args),
}));

function renderAtHistory() {
  return render(
    <MemoryRouter initialEntries={["/history"]}>
      <AuthProvider>
        <Routes>
          <Route path="/history" element={<History />} />
          <Route path="/home" element={<div>Diary Page</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

const today = new Date().toISOString().slice(0, 10);

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockResolvedValue({
    identity: { id: "1", username: "alice", role: "user" },
    profile: { id: "p1", display_name: "Alice" },
  });
  mockGetSummary.mockResolvedValue({
    from: today,
    to: today,
    totals: [
      { code: "ENERGY_KCAL", amount: "0", unit: "kcal" },
      { code: "PROTEIN_G", amount: "0", unit: "g" },
      { code: "CARBS_G", amount: "0", unit: "g" },
      { code: "FAT_G", amount: "0", unit: "g" },
    ],
  });
});

describe("History", () => {
  it("renders header and date inputs", async () => {
    renderAtHistory();

    await waitFor(() => {
      expect(screen.getByText("History")).toBeInTheDocument();
    });

    expect(screen.getByText("From")).toBeInTheDocument();
    expect(screen.getByText("To")).toBeInTheDocument();
  });

  it("shows daily summary rows", async () => {
    mockGetSummary.mockResolvedValue({
      from: today,
      to: today,
      totals: [
        { code: "ENERGY_KCAL", amount: "2000", unit: "kcal" },
        { code: "PROTEIN_G", amount: "120", unit: "g" },
        { code: "CARBS_G", amount: "250", unit: "g" },
        { code: "FAT_G", amount: "65", unit: "g" },
      ],
    });

    renderAtHistory();

    await waitFor(() => {
      const cells = screen.getAllByText("2000");
      expect(cells.length).toBeGreaterThan(0);
    });

    expect(screen.getByText("Calories")).toBeInTheDocument();
    expect(screen.getByText("Protein")).toBeInTheDocument();
    expect(screen.getByText("Carbs")).toBeInTheDocument();
    expect(screen.getByText("Fat")).toBeInTheDocument();
  });

  it("shows loading state", async () => {
    mockGetSummary.mockImplementation(() => new Promise(() => {}));

    renderAtHistory();

    await waitFor(() => {
      expect(screen.getByText("History")).toBeInTheDocument();
    });
  });
});
