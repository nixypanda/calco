import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { LoginPage } from "../pages/LoginPage";

const mockGetSession = vi.fn();
const mockLogin = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: (...args: unknown[]) => mockLogin(...args),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

function renderAtLogin() {
  return render(
    <MemoryRouter initialEntries={["/login"]}>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route path="/" element={<div>Root Page</div>} />
          <Route path="/home" element={<div>User Home</div>} />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockRejectedValue(new Error("no session"));
});

describe("LoginPage", () => {
  it("renders login form", async () => {
    renderAtLogin();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: "Log In" }),
      ).toBeInTheDocument();
    });
  });

  it("shows error for empty fields", async () => {
    renderAtLogin();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: "Log In" }),
      ).toBeInTheDocument();
    });

    await userEvent.click(screen.getByRole("button", { name: "Log In" }));

    expect(
      screen.getByText("Username and password are required"),
    ).toBeInTheDocument();
  });

  it("calls login on valid submit", async () => {
    mockLogin.mockResolvedValue({
      identity: { id: "1", username: "alice", role: "user" },
      profile: { id: "p1", display_name: "Alice" },
    });

    renderAtLogin();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: "Log In" }),
      ).toBeInTheDocument();
    });

    const usernameInput = screen.getAllByRole("textbox")[0];
    const passwordInput = screen.getByLabelText("Password");

    await userEvent.type(usernameInput, "alice");
    await userEvent.type(passwordInput, "password123");

    await userEvent.click(screen.getByRole("button", { name: "Log In" }));

    await waitFor(() => {
      expect(mockLogin).toHaveBeenCalledWith("alice", "password123");
    });
  });

  it("shows login error", async () => {
    mockLogin.mockRejectedValue(new Error("Invalid credentials"));

    renderAtLogin();

    await waitFor(() => {
      expect(
        screen.getByRole("heading", { name: "Log In" }),
      ).toBeInTheDocument();
    });

    const usernameInput = screen.getAllByRole("textbox")[0];
    const passwordInput = screen.getByLabelText("Password");

    await userEvent.type(usernameInput, "alice");
    await userEvent.type(passwordInput, "wrong");

    await userEvent.click(screen.getByRole("button", { name: "Log In" }));

    await waitFor(() => {
      expect(screen.getByText("Invalid credentials")).toBeInTheDocument();
    });
  });

  it("redirects if already authenticated", async () => {
    mockGetSession.mockResolvedValue({
      identity: { id: "1", username: "alice", role: "user" },
      profile: { id: "p1", display_name: "Alice" },
    });

    renderAtLogin();

    await waitFor(() => {
      expect(screen.getByText("Root Page")).toBeInTheDocument();
    });
  });
});
