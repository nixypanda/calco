import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { AuthProvider } from "../hooks/AuthContext";
import { AdminDashboard } from "../pages/AdminDashboard";

const mockGetSession = vi.fn();
const mockListUsers = vi.fn();
const mockCreateUser = vi.fn();
const mockResetPassword = vi.fn();
const mockDisableUser = vi.fn();
const mockEnableUser = vi.fn();

vi.mock("../api/auth", () => ({
  getSession: (...args: unknown[]) => mockGetSession(...args),
  login: vi.fn(),
  logout: vi.fn(),
  createAdmin: vi.fn(),
}));

vi.mock("../api/admin", () => ({
  listUsers: (...args: unknown[]) => mockListUsers(...args),
  createUser: (...args: unknown[]) => mockCreateUser(...args),
  resetPassword: (...args: unknown[]) => mockResetPassword(...args),
  disableUser: (...args: unknown[]) => mockDisableUser(...args),
  enableUser: (...args: unknown[]) => mockEnableUser(...args),
}));

function renderDashboard() {
  return render(
    <MemoryRouter>
      <AuthProvider>
        <AdminDashboard />
      </AuthProvider>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  mockGetSession.mockResolvedValue({
    identity: { id: "admin-id", username: "admin", role: "admin" },
    profile: null,
  });
  mockListUsers.mockResolvedValue({ users: [] });
});

describe("AdminDashboard", () => {
  it("renders admin dashboard and shows user list", async () => {
    mockListUsers.mockResolvedValue({
      users: [
        {
          id: "u1",
          username: "alice",
          display_name: "Alice",
          status: "active",
          created_at: "2026-01-01T00:00:00Z",
        },
        {
          id: "u2",
          username: "bob",
          display_name: "Bob",
          status: "disabled",
          created_at: "2026-01-02T00:00:00Z",
        },
      ],
    });

    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText("Admin Dashboard")).toBeInTheDocument();
    });

    await waitFor(() => {
      expect(screen.getByText("alice")).toBeInTheDocument();
    });
    expect(screen.getByText("bob")).toBeInTheDocument();
  });

  it("shows create user form", async () => {
    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText("Admin Dashboard")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Create User"));

    expect(screen.getByPlaceholderText("Username")).toBeInTheDocument();
    expect(screen.getByPlaceholderText("Display Name")).toBeInTheDocument();
    expect(
      screen.getByPlaceholderText("Initial Password"),
    ).toBeInTheDocument();
  });

  it("creates a user", async () => {
    mockCreateUser.mockResolvedValue({
      identity: { id: "u3", username: "charlie", role: "user" },
      profile: { id: "p3", display_name: "Charlie" },
    });
    mockListUsers.mockResolvedValue({ users: [] });

    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText("Admin Dashboard")).toBeInTheDocument();
    });

    await userEvent.click(screen.getByText("Create User"));
    await userEvent.type(screen.getByPlaceholderText("Username"), "charlie");
    await userEvent.type(
      screen.getByPlaceholderText("Display Name"),
      "Charlie",
    );
    await userEvent.type(
      screen.getByPlaceholderText("Initial Password"),
      "pass12345",
    );

    await userEvent.click(screen.getAllByText("Save")[0]);

    await waitFor(() => {
      expect(mockCreateUser).toHaveBeenCalledWith({
        username: "charlie",
        display_name: "Charlie",
        initial_password: "pass12345",
      });
    });
  });

  it("resets password for a user", async () => {
    mockListUsers.mockResolvedValue({
      users: [
        {
          id: "u1",
          username: "alice",
          display_name: "Alice",
          status: "active",
          created_at: "2026-01-01T00:00:00Z",
        },
      ],
    });

    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText("alice")).toBeInTheDocument();
    });

    const resetBtns = screen.getAllByText("Reset Password");
    await userEvent.click(resetBtns[0]);

    const passwordInput = screen.getByPlaceholderText("New password");
    await userEvent.type(passwordInput, "newpass456");

    await userEvent.click(screen.getByText("Confirm Reset"));

    await waitFor(() => {
      expect(mockResetPassword).toHaveBeenCalledWith("u1", "newpass456");
    });
  });
});
