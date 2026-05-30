import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { Diary } from "../pages/Diary";

const mockGetSession = vi.fn();
const mockListLogs = vi.fn();
const mockGetSummary = vi.fn();
const mockGetFoodDetail = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/logs", () => ({
  listLogs: (...args: unknown[]) => mockListLogs(...args),
  getSummary: (...args: unknown[]) => mockGetSummary(...args),
}));

vi.mock("../api/foods", () => ({
  getFoodDetail: (...args: unknown[]) => mockGetFoodDetail(...args),
}));

function renderAtHome() {
  return render(
    <MemoryRouter initialEntries={["/home"]}>
      <AuthProvider>
        <Routes>
          <Route path="/home" element={<Diary />} />
          <Route path="/search" element={<div>Search Page</div>} />
          <Route path="/history" element={<div>History Page</div>} />
          <Route path="/logs/:id" element={<div>Log Detail Page</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

const today = new Date().toISOString().slice(0, 10);

const mockLogItem = {
  id: "log-1",
  logged_at: "2026-05-30T12:00:00Z",
  meal_slot: "Lunch",
  item: { type: "product", id: "food-1" },
  quantity: { amount: "150", unit: "g" },
  nutrients: [
    { code: "ENERGY_KCAL", amount: "247.5", unit: "kcal" },
    { code: "PROTEIN_G", amount: "46.5", unit: "g" },
  ],
  notes: null,
};

const mockSummary = {
  from: today,
  to: today,
  totals: [
    { code: "ENERGY_KCAL", amount: "247.5", unit: "kcal" },
    { code: "PROTEIN_G", amount: "46.5", unit: "g" },
    { code: "CARBS_G", amount: "0", unit: "g" },
    { code: "FAT_G", amount: "3.5", unit: "g" },
  ],
};

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockResolvedValue({
    identity: { id: "1", username: "alice", role: "user" },
    profile: { id: "p1", display_name: "Alice" },
  });
  mockListLogs.mockResolvedValue({ from: today, to: today, items: [] });
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

describe("Diary", () => {
  it("renders header and nav", async () => {
    renderAtHome();

    await waitFor(() => {
      expect(screen.getByText("CalCo")).toBeInTheDocument();
    });

    expect(screen.getByText("Search Foods")).toBeInTheDocument();
    expect(screen.getByText("Create Food")).toBeInTheDocument();
    expect(screen.getByText("History")).toBeInTheDocument();
  });

  it("shows empty state when no logs", async () => {
    renderAtHome();

    await waitFor(() => {
      expect(
        screen.getByText("No food logged for this day."),
      ).toBeInTheDocument();
    });
  });

  it("shows summary rings", async () => {
    mockGetSummary.mockResolvedValue(mockSummary);

    renderAtHome();

    await waitFor(() => {
      expect(screen.getByText("Calories")).toBeInTheDocument();
    });

    expect(screen.getByText("Protein")).toBeInTheDocument();
    expect(screen.getByText("Carbs")).toBeInTheDocument();
    expect(screen.getByText("Fat")).toBeInTheDocument();
  });

  it("shows meal slot groups and log rows", async () => {
    mockGetSummary.mockResolvedValue(mockSummary);
    mockListLogs.mockResolvedValue({
      from: today,
      to: today,
      items: [mockLogItem],
    });
    mockGetFoodDetail.mockResolvedValue({
      id: "food-1",
      name: "Chicken Breast",
    });

    renderAtHome();

    await waitFor(() => {
      expect(screen.getByText("Lunch")).toBeInTheDocument();
    });

    expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
  });

  it("navigates to search on Search Foods click", async () => {
    renderAtHome();

    await waitFor(() => {
      expect(screen.getByText("Search Foods")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Search Foods"));

    await waitFor(() => {
      expect(screen.getByText("Search Page")).toBeInTheDocument();
    });
  });

  it("navigates to history on History click", async () => {
    renderAtHome();

    await waitFor(() => {
      expect(screen.getByText("History")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("History"));

    await waitFor(() => {
      expect(screen.getByText("History Page")).toBeInTheDocument();
    });
  });

  it("navigates to log detail on log row click", async () => {
    mockGetSummary.mockResolvedValue(mockSummary);
    mockListLogs.mockResolvedValue({
      from: today,
      to: today,
      items: [mockLogItem],
    });
    mockGetFoodDetail.mockResolvedValue({
      id: "food-1",
      name: "Chicken Breast",
    });

    renderAtHome();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Chicken Breast"));

    await waitFor(() => {
      expect(screen.getByText("Log Detail Page")).toBeInTheDocument();
    });
  });

  it("shows error state", async () => {
    mockListLogs.mockRejectedValue(new Error("Network error"));

    renderAtHome();

    await waitFor(() => {
      expect(screen.getByText("Network error")).toBeInTheDocument();
    });
  });
});
