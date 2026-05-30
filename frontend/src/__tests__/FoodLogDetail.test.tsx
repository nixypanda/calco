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
  ],
  notes: "Post-workout meal",
};

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockResolvedValue({
    identity: { id: "1", username: "alice", role: "user" },
    profile: { id: "p1", display_name: "Alice" },
  });
  mockGetLog.mockResolvedValue(mockLog);
  mockGetFoodDetail.mockResolvedValue({ id: "food-1", name: "Chicken Breast" });
});

describe("FoodLogDetail", () => {
  it("shows loading state", async () => {
    mockGetLog.mockImplementation(() => new Promise(() => {}));

    renderAtDetail();

    expect(screen.getByText("Food Log")).toBeInTheDocument();
  });

  it("shows log details when loaded", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    expect(screen.getByText("Lunch")).toBeInTheDocument();
    expect(screen.getByText("150 g")).toBeInTheDocument();
    expect(screen.getByText("Post-workout meal")).toBeInTheDocument();
  });

  it("enters edit mode and saves changes", async () => {
    mockUpdateLog.mockResolvedValue({
      ...mockLog,
      quantity: { amount: "200", unit: "g" },
      meal_slot: "dinner",
    });

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Edit"));

    const amountInput = screen.getByDisplayValue("150");
    await userEvent.clear(amountInput);
    await userEvent.type(amountInput, "200");

    const slotSelect = screen.getByDisplayValue("Lunch");
    await userEvent.selectOptions(slotSelect, "dinner");

    await userEvent.click(screen.getByText("Save"));

    await waitFor(() => {
      expect(mockUpdateLog).toHaveBeenCalledWith("log-1", expect.objectContaining({
        quantity: { amount: "200", unit: "g" },
        meal_slot: "dinner",
      }));
    });
  });

  it("cancels edit mode", async () => {
    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Edit"));
    await userEvent.click(screen.getByText("Cancel"));

    expect(screen.getByText("Edit")).toBeInTheDocument();
  });

  it("deletes log and navigates to diary", async () => {
    mockDeleteLog.mockResolvedValue(undefined);
    vi.spyOn(window, "confirm").mockReturnValue(true);

    renderAtDetail();

    await waitFor(() => {
      expect(screen.getByText("Chicken Breast")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Delete"));

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

    await userEvent.click(screen.getByText("Delete"));

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
