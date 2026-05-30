import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { BootstrapAdminSetup } from "../pages/BootstrapAdminSetup";

const mockGetSession = vi.fn();
const mockCreateAdmin = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  createAdmin: (...args: unknown[]) => mockCreateAdmin(...args),
  login: vi.fn(),
  logout: vi.fn(),
}));

function renderAtSetup() {
  return render(
    <MemoryRouter initialEntries={["/setup"]}>
      <AuthProvider>
        <Routes>
          <Route path="/setup" element={<BootstrapAdminSetup />} />
          <Route path="/admin" element={<div>Admin Page</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockRejectedValue(new Error("no session"));
});

describe("BootstrapAdminSetup", () => {
  it("renders the setup form", async () => {
    renderAtSetup();

    await waitFor(() => {
      expect(screen.getByText("First-Time Setup")).toBeInTheDocument();
    });
    expect(screen.getByText("Create Admin")).toBeTruthy();
  });

  it("shows error for short password", async () => {
    renderAtSetup();

    await waitFor(() => {
      expect(screen.getByText("First-Time Setup")).toBeInTheDocument();
    });

    const usernameInput = screen.getAllByRole("textbox")[0];
    const passwordInput = screen.getByLabelText("Password");

    await userEvent.type(usernameInput, "admin");
    await userEvent.type(passwordInput, "short");

    await userEvent.click(screen.getByText("Create Admin"));

    expect(
      screen.getByText("Password must be at least 8 characters"),
    ).toBeInTheDocument();
  });

  it("calls createAdmin on valid submit", async () => {
    mockCreateAdmin.mockResolvedValue({
      identity: { id: "1", username: "admin", role: "admin" },
      profile: null,
    });

    renderAtSetup();

    await waitFor(() => {
      expect(screen.getByText("First-Time Setup")).toBeInTheDocument();
    });

    const usernameInput = screen.getAllByRole("textbox")[0];
    const passwordInput = screen.getByLabelText("Password");

    await userEvent.type(usernameInput, "admin");
    await userEvent.type(passwordInput, "correct-password");

    await userEvent.click(screen.getByText("Create Admin"));

    await waitFor(() => {
      expect(mockCreateAdmin).toHaveBeenCalledWith(
        "admin",
        "correct-password",
      );
    });
  });

  it("handles createAdmin error", async () => {
    mockCreateAdmin.mockRejectedValue(new Error("Admin already exists"));

    renderAtSetup();

    await waitFor(() => {
      expect(screen.getByText("First-Time Setup")).toBeInTheDocument();
    });

    const usernameInput = screen.getAllByRole("textbox")[0];
    const passwordInput = screen.getByLabelText("Password");

    await userEvent.type(usernameInput, "admin");
    await userEvent.type(passwordInput, "correct-password");

    await userEvent.click(screen.getByText("Create Admin"));

    await waitFor(() => {
      expect(screen.getByText("Admin already exists")).toBeInTheDocument();
    });
  });
});
